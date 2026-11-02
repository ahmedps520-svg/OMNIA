import Foundation
import Observation
import UIKit

enum MemoryPressureLevel: String, Sendable {
    case normal, warning, critical

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    var detail: String {
        switch self {
        case .nominal: "Running cool. Full performance available."
        case .fair: "Slightly warm. Performance is unaffected."
        case .serious: "Hot. iOS may reduce performance; OMNIA paces generation on the efficiency profile."
        case .critical: "Very hot. OMNIA pauses generation to let the device cool."
        @unknown default: ""
        }
    }
}

/// Samples measured system state for the Performance center and reacts to memory pressure.
@MainActor
@Observable
final class PerformanceMonitor {
    struct Sample: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let footprint: UInt64
        let available: UInt64?
        let gpuAllocated: UInt64?
        let processCPU: Double?
        let systemCPU: Double?
        let systemMemoryUsed: UInt64?
    }

    static let historyLength = 180

    private(set) var samples: [Sample] = []
    private(set) var pressure: MemoryPressureLevel = .normal
    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var batteryLevel: Float?
    private(set) var batteryState: UIDevice.BatteryState = .unknown
    private(set) var lastPressureEvent: Date?

    var latest: Sample? { samples.last }

    /// Called on memory warnings and critical pressure (wired to the inference engine).
    var onMemoryPressure: ((MemoryPressureLevel) -> Void)?
    var onThermalChange: ((ProcessInfo.ThermalState) -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var previousTicks: SystemMetrics.CPUTicks?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var interval: TimeInterval = 2

    init() {}

    func start() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            MainActor.assumeIsolated {
                if event.contains(.critical) {
                    self.handlePressure(.critical)
                } else if event.contains(.warning) {
                    self.handlePressure(.warning)
                } else {
                    self.pressure = .normal
                }
            }
        }
        source.resume()
        pressureSource = source

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePressure(.warning) }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.thermalState = ProcessInfo.processInfo.thermalState
                self.onThermalChange?(self.thermalState)
            }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
        UIDevice.current.isBatteryMonitoringEnabled = true
        observers.append(center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBattery() }
        })
        observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBattery() }
        })
        readBattery()
        schedule(interval: interval)
        sample()
    }

    /// Faster sampling while the Performance center is visible or a model is generating.
    func setDetailedSampling(_ detailed: Bool) {
        let newInterval: TimeInterval = detailed ? 1 : 2
        guard newInterval != interval else { return }
        interval = newInterval
        schedule(interval: newInterval)
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func sample() {
        let ticks = SystemMetrics.systemCPUTicks()
        var systemCPU: Double?
        if let ticks, let previous = previousTicks, ticks.total > previous.total {
            systemCPU = Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total) * 100
        }
        previousTicks = ticks
        let sample = Sample(
            date: .now,
            footprint: SystemMetrics.processFootprint() ?? 0,
            available: SystemMetrics.availableMemory(),
            gpuAllocated: SystemMetrics.gpuAllocatedBytes(),
            processCPU: SystemMetrics.processCPUUsage(),
            systemCPU: systemCPU,
            systemMemoryUsed: SystemMetrics.systemMemory()?.used
        )
        samples.append(sample)
        if samples.count > Self.historyLength { samples.removeFirst(samples.count - Self.historyLength) }
        thermalState = ProcessInfo.processInfo.thermalState
    }

    private func handlePressure(_ level: MemoryPressureLevel) {
        pressure = level
        lastPressureEvent = .now
        onMemoryPressure?(level)
    }

    private func readBattery() {
        let level = UIDevice.current.batteryLevel
        batteryLevel = level >= 0 ? level : nil
        batteryState = UIDevice.current.batteryState
    }
}
