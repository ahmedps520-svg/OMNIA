import SwiftUI

/// The Cluster section: host a cluster on this device, or lend this device to one.
struct ClusterView: View {
    /// On a device OMNIA isn't tuned for, only lending is offered.
    var lendingOnly = false

    @Environment(ClusterHost.self) private var host
    @Environment(ClusterWorker.self) private var worker
    @State private var scanning = false
    @State private var enteringCode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if !RPCBridge.isAvailable {
                    Label("This build of OMNIA was made without cluster support.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .surface()
                } else if !lendingOnly && (host.isRunning || host.isStarting) {
                    ClusterHostPanel()
                } else if worker.phase != .idle {
                    ClusterWorkerPanel(scan: { scanning = true }, enterCode: { enteringCode = true })
                } else {
                    introduction
                    if !lendingOnly { hostChoice }
                    lendChoice
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .navigationTitle("Cluster")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scanning) {
            ClusterScanSheet(enterCode: {
                scanning = false
                enteringCode = true
            }) { invitation in
                scanning = false
                worker.join(invitation)
            }
        }
        .sheet(isPresented: $enteringCode) {
            ClusterCodeSheet { invitation in
                enteringCode = false
                worker.join(invitation)
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cluster").font(.omniaLargeTitle)
            Text("Run models too big for one device. The chat stays on the device that hosts, and the model's layers spread over your other iPhones, iPads and PCs on the same Wi-Fi. OMNIA puts layers on the fastest devices first: every extra device adds a network round trip to each token, so slower ones are used only when the model needs their memory.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var hostChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Host a Cluster on This Device", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text("Other devices join by scanning a QR code; a Windows PC joins from a page this device serves. Chats then load any model this device can't hold alone across the cluster.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let problem = host.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.critical)
            }
            Button {
                Task { await host.start() }
            } label: {
                Label("Start Hosting", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .disabled(host.isStarting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(padding: 20)
    }

    private var lendChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Lend This Device", systemImage: "cpu")
                .font(.headline)
            Text("Give this device's GPU to a cluster another device hosts. Scan the QR code on the host's Cluster screen; keep OMNIA open here while you use the cluster.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    scanning = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.glassProminent)
                Button("Enter Code") { enteringCode = true }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(padding: 20)
    }
}

// MARK: - Hosting

struct ClusterHostPanel: View {
    @Environment(ClusterHost.self) private var host
    @Environment(InferenceEngine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var planModelID: String?
    @State private var confirmingNewCode = false
    @State private var copied = false

    private let device = AppServices.shared.device

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 26) {
            status
            if !host.requests.isEmpty { requests }
            invite
            devices
            plan
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Options")
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Spread a model", selection: $settings.clusterSpread) {
                        ForEach(ClusterSpread.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Use the cluster for", selection: $settings.clusterUse) {
                        ForEach(ClusterUse.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Fastest uses as few devices as the model needs, fastest first. Every Device spreads it in proportion to each device's memory, which leaves more room on each but makes every token cross more of the network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("New Code", role: .destructive) { confirmingNewCode = true }
                        .buttonStyle(.glass)
                }
                .surface()
            }
        }
        .confirmationDialog("Make a new code?", isPresented: $confirmingNewCode, titleVisibility: .visible) {
            Button("New Code", role: .destructive) { host.resetCode() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every device leaves the cluster and has to join again, and PCs need approval again.")
        }
    }

    private var status: some View {
        HStack(alignment: .center, spacing: 14) {
            StatusDot(color: host.isRunning ? Theme.positive : Theme.caution, pulsing: host.isRunning)
            VStack(alignment: .leading, spacing: 3) {
                Text(host.isRunning ? "Hosting on \(host.name)" : "Starting…").font(.omniaTitle)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Stop", role: .destructive) { host.stop() }
                .buttonStyle(.glass)
        }
    }

    private var summary: String {
        let count = host.workers.count
        if count == 0 { return "No devices yet. Add them below." }
        let memory = host.readyDevices().reduce(UInt64(0)) { $0 + $1.memoryBudget }
        return "\(count) \(count == 1 ? "device" : "devices") joined, offering \(ByteFormat.memory(memory)) more for models."
    }

    private var requests: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Asking to Join")
            ForEach(host.requests) { request in
                HStack(spacing: 12) {
                    Image(systemName: request.info.kind == "pc" ? "desktopcomputer" : "iphone")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.info.name).font(.subheadline.weight(.semibold))
                        Text(ClusterDeviceText.offer(request.info) + " · \(request.address)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Decline") { host.decline(request.id) }
                        .buttonStyle(.glass)
                    Button("Allow") { host.approve(request.id) }
                        .buttonStyle(.glassProminent)
                }
                .surface(padding: 14)
            }
        }
    }

    private var invite: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Add Devices", subtitle: "Every device must be on the same Wi-Fi network as this one.")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    qrBlock
                    pcBlock
                }
                VStack(alignment: .leading, spacing: 20) {
                    qrBlock
                    pcBlock
                }
            }
            .surface(padding: 20)
        }
    }

    @ViewBuilder
    private var qrBlock: some View {
        if let invitation = host.invitation {
            VStack(alignment: .leading, spacing: 10) {
                Label("iPhone and iPad", systemImage: "iphone").font(.subheadline.weight(.semibold))
                QRCodeView(text: invitation.url.absoluteString)
                    .frame(width: 190, height: 190)
                Text("Scan with the Camera, or in OMNIA › Cluster › Scan QR Code. OMNIA has to be installed there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 240, alignment: .leading)
                Text("Or enter \(invitation.host) and code \(ClusterDeviceText.grouped(invitation.code))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var pcBlock: some View {
        if let page = host.joinPage, let command = host.pcCommand {
            VStack(alignment: .leading, spacing: 10) {
                Label("Windows PC", systemImage: "desktopcomputer").font(.subheadline.weight(.semibold))
                Text("On the PC, open this address in a browser and follow the page:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(page)
                    .font(.title3.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                Text("Or run this in PowerShell:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
                Button(copied ? "Copied" : "Copy Command") {
                    UIPasteboard.general.string = command
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .buttonStyle(.glass)
                Text("New PCs ask to join here first. OMNIA Node downloads llama.cpp \(ClusterProtocol.llamaBuild) the first time (about 670 MB with an NVIDIA card).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Devices

    private var devices: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Devices", subtitle: "Memory each can give a model, and its memory bandwidth, which sets how fast its layers run.")
            VStack(spacing: 0) {
                deviceRow(symbol: device.isPad ? "ipad" : "iphone", name: "\(device.name) (this device)",
                          detail: "Hosts the chat · \(ByteFormat.memory(engine.currentBudget().usable)) · \(Int(device.memoryBandwidthGBs)) GB/s",
                          status: Text("Host").foregroundStyle(.secondary), actions: nil)
                ForEach(host.workers) { worker in
                    Divider().padding(.leading, 48)
                    ForEach(worker.info.devices, id: \.index) { part in
                        deviceRow(symbol: ClusterDeviceText.symbol(worker.info),
                                  name: host.displayName(of: worker, device: part),
                                  detail: detail(worker, part),
                                  status: statusText(worker),
                                  actions: worker)
                    }
                }
            }
            .surface(padding: 6)
        }
    }

    private func detail(_ worker: ClusterHost.Worker, _ part: ClusterProtocol.DeviceInfo) -> String {
        let ready = host.readyDevices().first { $0.id == "\(worker.id)/\(part.index)" }
        var pieces: [String] = []
        if let ready {
            pieces.append(ByteFormat.memory(ready.memoryBudget))
            pieces.append("\(Int(ready.bandwidthGBs)) GB/s")
        } else {
            pieces.append(ByteFormat.memory(part.memoryFree))
        }
        if let rtt = worker.rttMs { pieces.append(String(format: "%.0f ms", rtt)) }
        if let backend = worker.info.backend, worker.isPC { pieces.append(backend) }
        return pieces.joined(separator: " · ")
    }

    private func statusText(_ worker: ClusterHost.Worker) -> Text {
        if worker.lostAt != nil { return Text("Dropped out").foregroundStyle(Theme.critical) }
        if worker.busy { return Text("Holding layers").foregroundStyle(Theme.positive) }
        return Text("Ready").foregroundStyle(.secondary)
    }

    private func deviceRow(symbol: String, name: String, detail: String, status: Text, actions worker: ClusterHost.Worker?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            status.font(.caption.weight(.medium))
            if let worker {
                Menu {
                    if worker.lostAt != nil {
                        Button("Use Again") { host.retry(worker.id) }
                    }
                    Button("Remove from Cluster", role: .destructive) { host.remove(worker.id) }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    // MARK: Plan

    private var candidates: [InstalledModel] {
        store.models.filter { !$0.isSystem && !$0.isMLX }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private var planModel: InstalledModel? {
        let loadedOnCluster = engine.loadedModels.first { $0.cluster != nil }?.id
        let id = planModelID ?? loadedOnCluster ?? settings.defaultModelID
        return candidates.first { $0.id == id } ?? candidates.first
    }

    @ViewBuilder
    private var plan: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Plan", subtitle: "Where a model's layers would go now. Estimates come from memory bandwidth and network round trips.") {
                if !candidates.isEmpty {
                    Menu {
                        ForEach(candidates) { model in
                            Button("\(model.displayName) · \(ByteFormat.file(model.sizeBytes))") { planModelID = model.id }
                        }
                    } label: {
                        Label(planModel?.displayName ?? "Model", systemImage: "cube.transparent")
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
            }
            Group {
                if let model = planModel {
                    planBody(for: model)
                } else {
                    Text("Download a GGUF model first (MLX models run on one device only).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .surface()
        }
    }

    @ViewBuilder
    private func planBody(for model: InstalledModel) -> some View {
        let local = engine.plan(for: model)
        let loaded = engine.loaded[model.id]
        if host.workers.isEmpty {
            Text(local.fits
                 ? "\(model.displayName) fits on this device alone. Add devices to run larger ones."
                 : "\(model.displayName) needs more memory than this device has. Add devices to run it across the cluster.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let plan = engine.clusterPlan(for: model) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    LabeledMetric(title: "Speed (estimate)", value: "\(Int(plan.estimatedTokensPerSecond.rounded())) tok/s")
                    LabeledMetric(title: "Context", value: ByteFormat.tokens(plan.contextLength))
                    LabeledMetric(title: "Devices", value: "\(plan.shares.count)")
                }
                ForEach(plan.shares, id: \.device.id) { share in
                    ClusterShareRow(share: share, totalLayers: plan.shares.reduce(0) { $0 + $1.layers })
                }
                if !plan.idle.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not used").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(plan.idle, id: \.device.id) { idle in
                            Text("\(idle.device.name): \(idle.reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(usageNote(model: model, local: local, loaded: loaded))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let loaded, loaded.cluster != nil, loaded.cluster?.shares.map(\.device.id) != plan.shares.map(\.device.id) {
                    Button("Reload on This Plan") { Task { await engine.unload(model.id) } }
                        .buttonStyle(.glass)
                }
            }
        } else {
            let offered = host.readyDevices().reduce(engine.currentBudget().usable) { $0 + $1.memoryBudget }
            Text("\(model.displayName) doesn't fit even across the cluster: it needs about \(ByteFormat.memory(model.sizeBytes)) for its weights alone, and the devices together offer \(ByteFormat.memory(offered)). Add devices, or choose a smaller quantization.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func usageNote(model: InstalledModel, local: LoadPlan, loaded: InferenceEngine.LoadedModel?) -> String {
        if let loaded, loaded.cluster != nil { return "Loaded across the cluster now." }
        if loaded != nil { return "Loaded on this device alone now; it moves to the cluster when it next loads, if that's the better place." }
        if !local.fits { return "It doesn't fit on this device alone, so chats load it across the cluster." }
        return settings.clusterUse == .whenFaster
            ? "Chats load it across the cluster when that's clearly faster than this device alone."
            : "It fits on this device alone, so chats run it here. Choose “Whenever It's Faster” below to use the cluster for it too."
    }
}

/// One device's part of a plan: its layers as a bar, and the memory it gives.
struct ClusterShareRow: View {
    let share: ClusterPlan.Share
    let totalLayers: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(share.device.isHost ? "\(share.device.name) (this device)" : share.device.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(share.layers) \(share.layers == 1 ? "layer" : "layers")\(share.device.isHost ? " + output" : "") · \(ByteFormat.memory(share.bytes)) of \(ByteFormat.memory(share.device.memoryBudget))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.faint)
                    Capsule()
                        .fill(share.device.isHost ? Color.accentColor : Theme.positive)
                        .frame(width: max(6, proxy.size.width * fraction))
                }
            }
            .frame(height: 8)
        }
    }

    private var fraction: CGFloat {
        guard share.device.memoryBudget > 0 else { return 0 }
        return CGFloat(min(1, Double(share.bytes) / Double(share.device.memoryBudget)))
    }
}

// MARK: - Lending

struct ClusterWorkerPanel: View {
    @Environment(ClusterWorker.self) private var worker
    var scan: () -> Void
    var enterCode: () -> Void

    /// Measured off the main thread: the cache holds a file per tensor, and an initial value here
    /// would walk them all every time the panel is rebuilt.
    @State private var cacheSize: UInt64 = 0
    private let device = AppServices.shared.device

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(tint)
                    .frame(width: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.omniaTitle)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if worker.phase == .lending {
                HStack(spacing: 18) {
                    LabeledMetric(title: "Offered", value: ByteFormat.memory(worker.offeredMemory))
                    LabeledMetric(title: "Network", value: worker.isHolding ? "\(ByteFormat.memory(UInt64(worker.throughput)))/s" : "Idle")
                    LabeledMetric(title: "Bandwidth", value: "\(Int(device.memoryBandwidthGBs)) GB/s")
                }
                .surface()
            }
            Label("Keep OMNIA open with the screen on; iOS gives apps no GPU in the background, so lending pauses when you leave. Plug in for long sessions.", systemImage: "lightbulb")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if worker.isActive {
                    Button("Stop Lending", role: .destructive) { worker.stop() }
                        .buttonStyle(.glass)
                } else {
                    Button {
                        scan()
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.glassProminent)
                    Button("Enter Code", action: enterCode).buttonStyle(.glass)
                    Button("Done") { worker.stop() }.buttonStyle(.glass)
                }
            }
            if cacheSize > 0 {
                HStack {
                    Text("Weights kept for faster reloads: \(ByteFormat.memory(cacheSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        cacheSize = 0
                        Task.detached(priority: .utility) { ClusterRPCServer.shared.clearCache() }
                    }
                    .font(.caption)
                    .disabled(worker.isHolding)
                }
            }
        }
        .surface(padding: 20)
        // Weights arrive while it holds a model; measure again when that starts or ends.
        .task(id: worker.isHolding) {
            cacheSize = await Task.detached(priority: .utility) { ClusterRPCServer.shared.cacheSize }.value
        }
    }

    private var name: String { worker.clusterName ?? worker.invitation?.name ?? "the cluster" }
    private var kind: String { device.isPadIdiom ? "iPad" : "iPhone" }

    private var title: String {
        switch worker.phase {
        case .idle: "Not lending"
        case .connecting: "Joining \(name)…"
        case .waitingForApproval: "Waiting for \(name)"
        case .lending: worker.isHolding ? "Holding part of a model" : "Lending this \(kind) to \(name)"
        case .paused: "Paused"
        case .failed: "Couldn't join"
        }
    }

    private var detail: String {
        switch worker.phase {
        case .idle:
            "Scan a host's QR code to lend this device."
        case .connecting:
            worker.hostUnreachable
                ? "Can't reach \(worker.invitation?.host ?? "the host"). Make sure both devices are on the same Wi-Fi and the host is still hosting."
                : "Connecting over Wi-Fi."
        case .waitingForApproval:
            "Allow this \(kind) on \(name) to add it."
        case .lending:
            worker.isHolding
                ? "\(name) runs part of its model on this \(kind)'s GPU."
                : (worker.hostUnreachable ? "Can't reach \(name) right now; trying again." : "Ready. \(name) uses this \(kind) when a model needs it.")
        case .paused:
            "OMNIA was in the background. Lending resumes now that it's open."
        case .failed(let message):
            message
        }
    }

    private var symbol: String {
        switch worker.phase {
        case .lending: worker.isHolding ? "bolt.horizontal.circle.fill" : "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        default: "point.3.connected.trianglepath.dotted"
        }
    }

    private var tint: Color {
        switch worker.phase {
        case .lending: Theme.positive
        case .failed: Theme.critical
        case .paused, .waitingForApproval: Theme.caution
        default: .accentColor
        }
    }
}

/// Short descriptions of what a worker offers.
enum ClusterDeviceText {
    static func offer(_ info: ClusterProtocol.WorkerInfo) -> String {
        info.devices.map { "\($0.detail.replacingOccurrences(of: "NVIDIA GeForce ", with: "")), \(ByteFormat.memory($0.memoryFree))" }
            .joined(separator: " + ")
    }

    static func symbol(_ info: ClusterProtocol.WorkerInfo) -> String {
        if info.kind == "pc" { return "desktopcomputer" }
        return info.name.lowercased().contains("ipad") ? "ipad" : "iphone"
    }

    /// "K7Q2X M4P9T": two halves read more easily.
    static func grouped(_ code: String) -> String {
        guard code.count > 5 else { return code }
        return "\(code.prefix(5)) \(code.dropFirst(5))"
    }
}

// MARK: - Prompts

extension View {
    /// Asks, wherever OMNIA is, whether to let a PC into the cluster this device hosts, and
    /// whether to lend this device to a cluster whose QR code was scanned with the Camera.
    func clusterPrompts(navigate: @escaping () -> Void) -> some View {
        modifier(ClusterPrompts(navigate: navigate))
    }
}

private struct ClusterPrompts: ViewModifier {
    @Environment(ClusterHost.self) private var host
    @Environment(ClusterWorker.self) private var worker
    var navigate: () -> Void

    private enum Prompt {
        case approval(ClusterHost.JoinRequest)
        case invitation(ClusterInvitation)
    }

    private var prompt: Prompt? {
        if let request = host.requests.first { return .approval(request) }
        if let invitation = worker.proposedInvitation { return .invitation(invitation) }
        return nil
    }

    private let kind = AppServices.shared.device.isPadIdiom ? "iPad" : "iPhone"

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(get: { prompt != nil }, set: { _ in }), presenting: prompt) { prompt in
            switch prompt {
            case .approval(let request):
                Button("Allow") { host.approve(request.id) }
                Button("Don't Allow", role: .cancel) { host.decline(request.id) }
            case .invitation(let invitation):
                Button("Lend") {
                    worker.proposedInvitation = nil
                    if host.isRunning { host.stop() }
                    worker.join(invitation)
                    navigate()
                }
                Button("Cancel", role: .cancel) { worker.proposedInvitation = nil }
            }
        } message: { prompt in
            switch prompt {
            case .approval(let request):
                Text("\(ClusterDeviceText.offer(request.info)), from \(request.address). It will hold part of the models this device runs. Allow only devices you own.")
            case .invitation(let invitation):
                Text("Its GPU will hold part of the models \(invitation.name) runs, while OMNIA stays open here."
                     + (host.isRunning ? " This \(kind) stops hosting its own cluster." : ""))
            }
        }
    }

    private var title: String {
        switch prompt {
        case .approval(let request): "\(request.info.name) wants to join your cluster"
        case .invitation(let invitation): "Lend this \(kind) to \(invitation.name)?"
        case nil: ""
        }
    }
}
