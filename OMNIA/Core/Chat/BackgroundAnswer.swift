import BackgroundTasks
import Foundation
import os

private let backgroundLog = Logger(subsystem: "app.omnia", category: "background")

/// On iPads with background GPU access (M3 and later), a reply keeps generating after you switch
/// apps: a continued processing task holds the GPU while iOS shows the reply's progress, with a
/// button to stop it. Elsewhere (every iPhone) a reply pauses in the background and offers
/// Continue, as before.
@MainActor
final class BackgroundAnswer {
    /// Info.plist allows "$(PRODUCT_BUNDLE_IDENTIFIER).generation.*"; each reply adds its own suffix.
    nonisolated static let identifierContext = "generation"
    /// Units of progress for reading the prompt, before the reply's tokens.
    private static let promptUnits: Int64 = 100

    /// This device can generate in the background (iOS doesn't say which devices; Apple says iPads
    /// with M3 or later, no iPhone).
    static var isSupported: Bool { BGTaskScheduler.supportedResources.contains(.gpu) }

    private let title: String
    private let modelName: String
    private let totalUnits: Int64
    private let onExpiration: () -> Void
    private var task: BGContinuedProcessingTask?
    /// How the reply ended, when it ended before iOS started the task.
    private var outcome: Bool?
    private var completed = false
    private var doneUnits: Int64 = 0
    private var subtitleUpdated = Date.distantPast
    private var firstTokenAt: Date?

    private init(title: String, modelName: String, maxTokens: Int, onExpiration: @escaping () -> Void) {
        self.title = title
        self.modelName = modelName
        totalUnits = Self.promptUnits + Int64(max(1, maxTokens))
        self.onExpiration = onExpiration
    }

    /// Asks iOS to let the reply go on in the background. Call it synchronously in the action that
    /// sends the message, while OMNIA is in front: iOS ignores requests made otherwise. Returns nil
    /// when the device or iOS won't; the reply generates anyway, and never waits for the task.
    static func begin(title: String, modelName: String, maxTokens: Int,
                      onExpiration: @escaping () -> Void) -> BackgroundAnswer? {
        guard isSupported, let bundleID = Bundle.main.bundleIdentifier else { return nil }
        // A fresh identifier each time: registering one twice terminates the app.
        let identifier = "\(bundleID).\(identifierContext).\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let answer = BackgroundAnswer(title: title, modelName: modelName, maxTokens: maxTokens, onExpiration: onExpiration)
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak answer] task in
            guard let task = task as? BGContinuedProcessingTask, let answer else {
                task.setTaskCompleted(success: false)
                return
            }
            answer.attach(task)
        }
        guard registered else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: modelName)
        // Start now or not at all: a reply can't wait.
        request.strategy = .fail
        request.requiredResources = .gpu
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            backgroundLog.info("Background generation unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return answer
    }

    /// iOS started the task, so the GPU stays available in the background until it completes.
    var holdsGPU: Bool { task != nil && !completed }

    /// Reading the prompt: `fraction` of it so far.
    func readPrompt(_ fraction: Double) {
        setProgress(Int64(Double(Self.promptUnits) * min(max(fraction, 0), 1)), subtitle: "Reading the conversation · \(modelName)")
    }

    /// Writing the reply: `tokens` so far, and how fast they come.
    func wrote(_ tokens: Int) {
        let now = Date()
        let first = firstTokenAt ?? now
        firstTokenAt = first
        let elapsed = now.timeIntervalSince(first)
        let speed = tokens > 1 && elapsed >= 1 ? " · \(ByteFormat.rate(Double(tokens - 1) / elapsed))" : ""
        setProgress(Self.promptUnits + Int64(tokens), subtitle: "\(tokens) tokens\(speed) · \(modelName)")
    }

    /// The reply ended (done, stopped or failed); the task completes and iOS takes back the GPU.
    func finish(success: Bool) {
        outcome = success
        task?.progress.completedUnitCount = totalUnits
        complete(success: success)
    }

    private func setProgress(_ units: Int64, subtitle: String) {
        doneUnits = min(max(units, doneUnits), totalUnits)
        guard let task, !completed else { return }
        task.progress.completedUnitCount = doneUnits
        // The subtitle changes at most once a second.
        if Date().timeIntervalSince(subtitleUpdated) >= 1 {
            subtitleUpdated = .now
            task.updateTitle(title, subtitle: subtitle)
        }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        if let outcome {
            // The reply finished before iOS started the task.
            completed = true
            task.progress.totalUnitCount = 1
            task.progress.completedUnitCount = 1
            task.setTaskCompleted(success: outcome)
            return
        }
        self.task = task
        task.progress.totalUnitCount = totalUnits
        task.progress.completedUnitCount = doneUnits
        // Stopped from iOS's progress view, or expired by the system. iOS doesn't say which queue.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expired() }
        }
    }

    private func expired() {
        onExpiration()
        // The task completes when the reply has stopped (`finish`): until then the GPU must stay,
        // since a command buffer cut off mid-flight leaves the model unusable until it reloads.
        // A reply that doesn't stop promptly gets two seconds.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.complete(success: false)
        }
    }

    private func complete(success: Bool) {
        guard let task, !completed else { return }
        completed = true
        task.setTaskCompleted(success: success)
    }
}
