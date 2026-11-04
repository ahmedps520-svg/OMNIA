import Foundation
import Metal
import UIKit

/// Hardware OMNIA is built for. Anything else is reported as unsupported.
enum DeviceClass: String, Codable, Sendable {
    case iPadProM5
    case iPhone18Pro
    case simulator
    case unsupported
}

/// Static facts for a known model identifier.
struct KnownDevice: Sendable {
    let identifier: String
    let name: String
    let chip: String
    let deviceClass: DeviceClass
    /// Peak unified-memory bandwidth in GB/s (used for speed estimates, labelled as estimates).
    let memoryBandwidthGBs: Double
}

/// Everything OMNIA detects about the device it is running on.
struct DeviceProfile: Sendable {
    let identifier: String
    let name: String
    let chip: String
    let deviceClass: DeviceClass
    let isSimulator: Bool
    let physicalMemory: UInt64
    /// Marketed unified-memory size, rounded from the physical memory reported by iOS.
    let memoryGB: Int
    let cpuCores: Int
    let performanceCores: Int
    let efficiencyCores: Int
    let gpuName: String
    let gpuRecommendedWorkingSet: UInt64?
    let storageCapacity: Int64?
    let memoryBandwidthGBs: Double
    let systemVersion: String
    let isPadIdiom: Bool

    var isSupported: Bool { deviceClass != .unsupported }
    var isPad: Bool {
        switch deviceClass {
        case .iPadProM5: true
        case .iPhone18Pro: false
        case .simulator, .unsupported: isPadIdiom
        }
    }

    /// e.g. "1 TB" — the storage tier, which on M5 iPad Pro also determines RAM and CPU cores.
    var storageTier: String? {
        guard let capacity = storageCapacity else { return nil }
        let gigabytes = Double(capacity) / 1_000_000_000
        let tiers: [(limit: Double, label: String)] = [(128, "128 GB"), (256, "256 GB"), (512, "512 GB"), (1024, "1 TB"), (2048, "2 TB")]
        return tiers.first { gigabytes <= $0.limit }?.label ?? "2 TB"
    }

    var configurationSummary: String {
        var parts = ["\(memoryGB) GB unified memory", "\(cpuCores)-core CPU"]
        if let tier = storageTier { parts.append(tier) }
        return parts.joined(separator: " · ")
    }

    @MainActor
    static func detect() -> DeviceProfile {
        let identifier = SystemMetrics.machineIdentifier()
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif

        let known = DeviceCatalog.lookup(identifier)
        let physical = ProcessInfo.processInfo.physicalMemory
        // iOS reports slightly less than the installed RAM; round up to the marketed size.
        let memoryGB = Int((Double(physical) / 1_073_741_824).rounded(.up))
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let performance = SystemMetrics.sysctlInt("hw.perflevel0.physicalcpu") ?? max(2, cores / 3)
        let efficiency = SystemMetrics.sysctlInt("hw.perflevel1.physicalcpu") ?? max(0, cores - performance)
        let gpu = SystemMetrics.metalDevice

        var deviceClass = known?.deviceClass ?? .unsupported
        if isSimulator { deviceClass = .simulator }

        return DeviceProfile(
            identifier: identifier,
            name: known?.name ?? (isSimulator ? "Simulator (\(identifier))" : UIDevice.current.model),
            chip: known?.chip ?? (gpu?.name.replacingOccurrences(of: " GPU", with: "") ?? "Apple silicon"),
            deviceClass: deviceClass,
            isSimulator: isSimulator,
            physicalMemory: physical,
            memoryGB: memoryGB,
            cpuCores: cores,
            performanceCores: performance,
            efficiencyCores: efficiency,
            gpuName: gpu?.name ?? "Unavailable",
            gpuRecommendedWorkingSet: SystemMetrics.gpuRecommendedWorkingSet(),
            storageCapacity: SystemMetrics.storage()?.total,
            memoryBandwidthGBs: known?.memoryBandwidthGBs ?? 100,
            systemVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            isPadIdiom: UIDevice.current.userInterfaceIdiom == .pad
        )
    }
}

enum DeviceCatalog {
    static func lookup(_ identifier: String) -> KnownDevice? {
        devices.first { $0.identifier == identifier }
    }

    /// Supported hardware. Apple doesn't publish model identifiers; these match AppleDB,
    /// EveryMac and The Apple Wiki (checked November 2026).
    static let devices: [KnownDevice] = [
        // iPad Pro (M5), October 2025: 12 GB + 9-core CPU (256/512 GB) or 16 GB + 10-core CPU (1/2 TB),
        // 10-core GPU with a Neural Accelerator per core, 153 GB/s.
        KnownDevice(identifier: "iPad17,1", name: "iPad Pro 11-inch (M5)", chip: "Apple M5", deviceClass: .iPadProM5, memoryBandwidthGBs: 153),
        KnownDevice(identifier: "iPad17,2", name: "iPad Pro 11-inch (M5)", chip: "Apple M5", deviceClass: .iPadProM5, memoryBandwidthGBs: 153),
        KnownDevice(identifier: "iPad17,3", name: "iPad Pro 13-inch (M5)", chip: "Apple M5", deviceClass: .iPadProM5, memoryBandwidthGBs: 153),
        KnownDevice(identifier: "iPad17,4", name: "iPad Pro 13-inch (M5)", chip: "Apple M5", deviceClass: .iPadProM5, memoryBandwidthGBs: 153),
        // iPhone 18 Pro family, September 2026: A20 Pro (2 + 4 CPU cores, 7-core GPU), 12 GB.
        // Apple quotes +50% bandwidth over A19 Pro (76.8 GB/s); 115 GB/s is derived, not published.
        KnownDevice(identifier: "iPhone19,2", name: "iPhone 18 Pro", chip: "Apple A20 Pro", deviceClass: .iPhone18Pro, memoryBandwidthGBs: 115),
        KnownDevice(identifier: "iPhone19,3", name: "iPhone 18 Pro Max", chip: "Apple A20 Pro", deviceClass: .iPhone18Pro, memoryBandwidthGBs: 115),
        KnownDevice(identifier: "iPhone19,7", name: "iPhone 18 Pro Max", chip: "Apple A20 Pro", deviceClass: .iPhone18Pro, memoryBandwidthGBs: 115),

        // Not targets, but they lend their GPUs to a cluster, where their names and bandwidth
        // (LPDDR type × 64-bit bus, or the M-series figure) decide what they're given.
        KnownDevice(identifier: "iPhone13,3", name: "iPhone 12 Pro", chip: "Apple A14 Bionic", deviceClass: .unsupported, memoryBandwidthGBs: 34),
        KnownDevice(identifier: "iPhone13,4", name: "iPhone 12 Pro Max", chip: "Apple A14 Bionic", deviceClass: .unsupported, memoryBandwidthGBs: 34),
        KnownDevice(identifier: "iPhone14,2", name: "iPhone 13 Pro", chip: "Apple A15 Bionic", deviceClass: .unsupported, memoryBandwidthGBs: 34),
        KnownDevice(identifier: "iPhone14,3", name: "iPhone 13 Pro Max", chip: "Apple A15 Bionic", deviceClass: .unsupported, memoryBandwidthGBs: 34),
        KnownDevice(identifier: "iPhone15,2", name: "iPhone 14 Pro", chip: "Apple A16 Bionic", deviceClass: .unsupported, memoryBandwidthGBs: 51),
        KnownDevice(identifier: "iPhone15,3", name: "iPhone 14 Pro Max", chip: "Apple A16 Bionic", deviceClass: .unsupported, memoryBandwidthGBs: 51),
        KnownDevice(identifier: "iPhone16,1", name: "iPhone 15 Pro", chip: "Apple A17 Pro", deviceClass: .unsupported, memoryBandwidthGBs: 51),
        KnownDevice(identifier: "iPhone16,2", name: "iPhone 15 Pro Max", chip: "Apple A17 Pro", deviceClass: .unsupported, memoryBandwidthGBs: 51),
        KnownDevice(identifier: "iPhone17,1", name: "iPhone 16 Pro", chip: "Apple A18 Pro", deviceClass: .unsupported, memoryBandwidthGBs: 60),
        KnownDevice(identifier: "iPhone17,2", name: "iPhone 16 Pro Max", chip: "Apple A18 Pro", deviceClass: .unsupported, memoryBandwidthGBs: 60),
        KnownDevice(identifier: "iPhone18,1", name: "iPhone 17 Pro", chip: "Apple A19 Pro", deviceClass: .unsupported, memoryBandwidthGBs: 77),
        KnownDevice(identifier: "iPhone18,2", name: "iPhone 17 Pro Max", chip: "Apple A19 Pro", deviceClass: .unsupported, memoryBandwidthGBs: 77),
        KnownDevice(identifier: "iPad15,3", name: "iPad Air 11-inch (M3)", chip: "Apple M3", deviceClass: .unsupported, memoryBandwidthGBs: 100),
        KnownDevice(identifier: "iPad15,4", name: "iPad Air 11-inch (M3)", chip: "Apple M3", deviceClass: .unsupported, memoryBandwidthGBs: 100),
        KnownDevice(identifier: "iPad15,5", name: "iPad Air 13-inch (M3)", chip: "Apple M3", deviceClass: .unsupported, memoryBandwidthGBs: 100),
        KnownDevice(identifier: "iPad15,6", name: "iPad Air 13-inch (M3)", chip: "Apple M3", deviceClass: .unsupported, memoryBandwidthGBs: 100),
        KnownDevice(identifier: "iPad16,3", name: "iPad Pro 11-inch (M4)", chip: "Apple M4", deviceClass: .unsupported, memoryBandwidthGBs: 120),
        KnownDevice(identifier: "iPad16,4", name: "iPad Pro 11-inch (M4)", chip: "Apple M4", deviceClass: .unsupported, memoryBandwidthGBs: 120),
        KnownDevice(identifier: "iPad16,5", name: "iPad Pro 13-inch (M4)", chip: "Apple M4", deviceClass: .unsupported, memoryBandwidthGBs: 120),
        KnownDevice(identifier: "iPad16,6", name: "iPad Pro 13-inch (M4)", chip: "Apple M4", deviceClass: .unsupported, memoryBandwidthGBs: 120)
    ]
}
