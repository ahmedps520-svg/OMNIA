import Charts
import SwiftUI

/// Live, measured hardware and inference statistics. Values iOS doesn't expose (such as GPU
/// utilization or temperatures) are labelled as unavailable rather than estimated.
struct PerformanceView: View {
    @Environment(PerformanceMonitor.self) private var monitor
    @Environment(InferenceEngine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(ChatService.self) private var chat

    private let device = AppServices.shared.device

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                liveTiles
                memoryChart
                cpuChart
                inferenceSection
                deviceSection
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .navigationTitle("Performance")
        .onAppear { monitor.setDetailedSampling(true) }
        .onDisappear { if !engine.isGenerating { monitor.setDetailedSampling(false) } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(device.name) · \(device.chip)").font(.headline)
                Text("Sampled every \(engine.isGenerating ? 1 : 2) s from public iOS APIs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Tiles

    private var liveTiles: some View {
        let latest = monitor.latest
        let budget = engine.currentBudget()
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            StatTile(title: "OMNIA memory", value: latest.map { ByteFormat.memory($0.footprint) } ?? "—",
                     detail: "Physical footprint (what iOS limits)", symbol: "memorychip")
            StatTile(title: "Headroom", value: latest?.available.map { ByteFormat.memory($0) } ?? "Unavailable",
                     detail: "Before reaching OMNIA's memory limit", symbol: "arrow.up.and.down")
            StatTile(title: "Memory pressure", value: monitor.pressure.title,
                     detail: monitor.lastPressureEvent.map { "Last event \($0.relativeDescription)" } ?? "No warnings this session",
                     symbol: "exclamationmark.triangle", tint: pressureColor)
            StatTile(title: "GPU memory", value: latest?.gpuAllocated.map { ByteFormat.memory($0) } ?? "—",
                     detail: device.gpuRecommendedWorkingSet.map { "Metal working set limit \(ByteFormat.memory($0))" }, symbol: "square.grid.3x3.fill")
            StatTile(title: "GPU utilization", value: "Not exposed",
                     detail: "iOS offers no public API for GPU load", symbol: "slash.circle")
            StatTile(title: "CPU (OMNIA)", value: latest?.processCPU.map { String(format: "%.0f%%", $0) } ?? "—",
                     detail: "Sum across \(device.cpuCores) cores", symbol: "cpu")
            StatTile(title: "CPU (system)", value: latest?.systemCPU.map { String(format: "%.0f%%", $0) } ?? "—",
                     detail: "All processes", symbol: "cpu.fill")
            StatTile(title: "Thermal state", value: monitor.thermalState.title, detail: monitor.thermalState.detail,
                     symbol: "thermometer.medium", tint: thermalColor)
            StatTile(title: "Power", value: monitor.isLowPowerMode ? "Low Power Mode" : "Normal",
                     detail: monitor.batteryLevel.map { "Battery \(Int($0 * 100))%\(monitor.batteryState == .charging ? ", charging" : "")" },
                     symbol: monitor.isLowPowerMode ? "battery.25" : "battery.100")
            StatTile(title: "Model storage", value: ByteFormat.file(store.storageUsed),
                     detail: SystemMetrics.storage().map { "\(ByteFormat.file($0.availableForImportantUsage)) free on device" }, symbol: "internaldrive")
            StatTile(title: "Model budget", value: ByteFormat.memory(budget.usable),
                     detail: "\(engine.profile.title) profile, safety margin applied", symbol: "square.stack.3d.up")
        }
    }

    private var pressureColor: Color {
        switch monitor.pressure {
        case .normal: Theme.positive
        case .warning: Theme.caution
        case .critical: Theme.critical
        }
    }

    private var thermalColor: Color {
        switch monitor.thermalState {
        case .nominal, .fair: Theme.positive
        case .serious: Theme.caution
        case .critical: Theme.critical
        @unknown default: .secondary
        }
    }

    // MARK: Charts

    private var memoryChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Memory", subtitle: "OMNIA's footprint and Metal allocations over the last few minutes.")
            Chart {
                ForEach(monitor.samples) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("GB", Double(sample.footprint) / 1_073_741_824))
                        .foregroundStyle(by: .value("Series", "Footprint"))
                        .interpolationMethod(.monotone)
                    if let gpu = sample.gpuAllocated {
                        LineMark(x: .value("Time", sample.date), y: .value("GB", Double(gpu) / 1_073_741_824))
                            .foregroundStyle(by: .value("Series", "GPU"))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYAxisLabel("GB")
            .chartForegroundStyleScale(["Footprint": Color.accentColor, "GPU": Color.secondary])
            .frame(height: 200)
            .surface()
        }
    }

    private var cpuChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("CPU", subtitle: "With full GPU offload, CPU load during generation stays low.")
            Chart {
                ForEach(monitor.samples) { sample in
                    if let cpu = sample.processCPU {
                        AreaMark(x: .value("Time", sample.date), y: .value("Percent", cpu))
                            .foregroundStyle(Color.accentColor.opacity(0.25))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", sample.date), y: .value("Percent", cpu))
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYAxisLabel("% of one core")
            .frame(height: 160)
            .surface()
        }
    }

    // MARK: Inference

    private var inferenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Inference")
            VStack(alignment: .leading, spacing: 12) {
                if let live = engine.live {
                    HStack {
                        StatusDot(color: .accentColor, pulsing: true)
                        Text("Generating with \(live.modelName)").font(.subheadline.weight(.semibold))
                        Spacer()
                        if let rate = liveRate {
                            Text(ByteFormat.rate(rate)).font(.subheadline.monospacedDigit())
                        }
                    }
                } else if let stats = engine.lastStats {
                    HStack(spacing: 22) {
                        LabeledMetric(title: "Last response", value: ByteFormat.rate(stats.tokensPerSecond))
                        LabeledMetric(title: "Prompt", value: stats.promptTokensPerSecond > 0 ? ByteFormat.rate(stats.promptTokensPerSecond) : "Cached")
                        LabeledMetric(title: "First token", value: ByteFormat.seconds(stats.timeToFirstToken))
                        LabeledMetric(title: "Model", value: stats.modelName)
                    }
                } else {
                    Text("No generation yet this session.").font(.subheadline).foregroundStyle(.secondary)
                }
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                if engine.loadedModels.isEmpty {
                    Text("No model is loaded.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(engine.loadedModels) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.info.displayName).font(.subheadline)
                            Text("\(ByteFormat.tokens(entry.info.configuration.contextLength)) context · \(entry.info.configuration.kvCacheType.label) KV · loaded in \(ByteFormat.seconds(entry.info.loadDuration))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(ByteFormat.memory(entry.info.measuredGPUBytes)).font(.subheadline.monospacedDigit())
                            Text("Metal, measured").font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Unload") { Task { await engine.unload(entry.id) } }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(engine.isGenerating)
                    }
                }
            }
            .surface()
        }
    }

    private var liveRate: Double? {
        guard let reply = chat.live, let first = reply.firstTokenAt, reply.chunks > 1 else { return nil }
        let elapsed = Date().timeIntervalSince(first)
        return elapsed > 0 ? Double(reply.chunks - 1) / elapsed : nil
    }

    // MARK: Device

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Device")
            VStack(spacing: 10) {
                LabeledValueRow(label: "Model", value: "\(device.name) (\(device.identifier))")
                LabeledValueRow(label: "Chip", value: device.chip)
                LabeledValueRow(label: "Unified memory", value: "\(device.memoryGB) GB (\(ByteFormat.memory(device.physicalMemory)) reported)")
                LabeledValueRow(label: "CPU", value: "\(device.cpuCores) cores (\(device.performanceCores) performance, \(device.efficiencyCores) efficiency)")
                LabeledValueRow(label: "GPU", value: device.gpuName)
                LabeledValueRow(label: "Memory bandwidth", value: "\(Int(device.memoryBandwidthGBs)) GB/s (used for speed estimates)")
                LabeledValueRow(label: "Optimization profile", value: engine.profile.title)
                LabeledValueRow(label: "System", value: device.systemVersion)
                LabeledValueRow(label: "Inference engine", value: "llama.cpp \(LlamaRuntime.engineVersion) · Metal")
            }
            .surface()
        }
    }
}
