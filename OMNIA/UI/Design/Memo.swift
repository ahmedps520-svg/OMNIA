import Foundation

/// One remembered result of a costly computation, worked out again only when its inputs change.
/// A view keeps it in `@State`, so it lasts as long as the view; it isn't observable, so filling
/// it never asks SwiftUI to draw again.
@MainActor
final class Memo<Key: Hashable, Value> {
    private var stored: (key: Key, value: Value)?

    func value(for key: Key, compute: () -> Value) -> Value {
        if let stored, stored.key == key { return stored.value }
        let value = compute()
        stored = (key, value)
        return value
    }
}

/// What planning a model's memory depends on: this device's limits, the cluster's devices and the
/// settings that shape a plan. Memory is compared in 128 MiB steps, because iOS's measured headroom
/// moves by a few megabytes all the time and that shouldn't redo every plan on screen.
struct PlanningInputs: Hashable {
    /// The budget as measured now. Equality uses its rounded figures instead.
    let budget: MemoryBudget
    private let key: Key

    private struct Key: Hashable {
        var resident: UInt64
        var footprint: UInt64
        var devices: [Device]
        var settings: [String]
    }

    private struct Device: Hashable {
        var id: String
        var memory: UInt64
        var bandwidth: Int
        var latency: Int
    }

    /// `settings`: whatever else the plans read (the profile, cache and context choices…).
    init(budget: MemoryBudget, devices: [ClusterDevice], settings: [String]) {
        self.budget = budget
        key = Key(resident: budget.allowance.resident >> 27, footprint: budget.allowance.footprint >> 27,
                  devices: devices.map { device in
                      Device(id: device.id, memory: device.memoryBudget >> 27, bandwidth: Int(device.bandwidthGBs.rounded()),
                             latency: Int(device.latencyMs.rounded()))
                  },
                  settings: settings)
    }

    @MainActor
    init(engine: InferenceEngine, settings: AppSettings) {
        self.init(budget: engine.currentBudget(), devices: engine.clusterDevices?() ?? [],
                  settings: [engine.profile.kind.rawValue, String(describing: settings.memorySafety),
                             String(settings.contextLength), String(describing: settings.kvCache),
                             String(settings.flashAttention), settings.clusterSpread.rawValue])
    }

    static func == (lhs: PlanningInputs, rhs: PlanningInputs) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Free space on the device, read off the main thread: iOS can take a while to work out what's
/// available "for important usage", so views show this instead of asking while they draw.
@MainActor
@Observable
final class FreeStorage {
    static let shared = FreeStorage()

    private(set) var status: SystemMetrics.StorageStatus?
    @ObservationIgnored private var readAt: Date?
    @ObservationIgnored private var reading = false

    /// Reads it again, unless it was read less than `maxAge` seconds ago.
    func refresh(maxAge: TimeInterval = 10) async {
        if let readAt, Date().timeIntervalSince(readAt) < maxAge { return }
        guard !reading else { return }
        reading = true
        let status = await Task.detached(priority: .utility) { SystemMetrics.storage() }.value
        self.status = status
        readAt = .now
        reading = false
    }
}
