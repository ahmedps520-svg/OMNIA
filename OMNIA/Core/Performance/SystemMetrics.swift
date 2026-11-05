import Foundation
import Darwin
import Metal
import os

/// Direct, public-API readings of process and system state. Every value here is measured;
/// anything iOS does not expose (e.g. GPU utilization) is simply not reported.
enum SystemMetrics {

    // MARK: Memory

    /// Physical footprint of this process — the figure iOS uses for its memory limit.
    static func processFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// Bytes this process can still allocate before reaching its memory limit.
    /// Reflects the increased-memory-limit entitlement. Returns nil on the Simulator, where it is 0.
    static func availableMemory() -> UInt64? {
        let value = os_proc_available_memory()
        return value > 0 ? UInt64(value) : nil
    }

    struct SystemMemory {
        var total: UInt64
        var free: UInt64
        var active: UInt64
        var inactive: UInt64
        var wired: UInt64
        var compressed: UInt64
        var used: UInt64 { active + wired + compressed }
    }

    /// System-wide VM statistics (an estimate: iOS manages file cache and compression dynamically).
    static func systemMemory() -> SystemMemory? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        return SystemMemory(
            total: ProcessInfo.processInfo.physicalMemory,
            free: UInt64(stats.free_count) * page,
            active: UInt64(stats.active_count) * page,
            inactive: UInt64(stats.inactive_count) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page
        )
    }

    // MARK: GPU

    static let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Bytes currently allocated by this process on the GPU (all Metal buffers, including models).
    static func gpuAllocatedBytes() -> UInt64? {
        guard let device = metalDevice else { return nil }
        return UInt64(device.currentAllocatedSize)
    }

    /// Metal's recommended working-set ceiling for this process.
    static func gpuRecommendedWorkingSet() -> UInt64? {
        guard let device = metalDevice else { return nil }
        let value = device.recommendedMaxWorkingSetSize
        return value > 0 ? value : nil
    }

    // MARK: CPU

    /// CPU time consumed by this process across all cores, as a percentage of one core (0…N×100).
    static func processCPUUsage() -> Double? {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return nil }
        defer {
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), size)
        }
        var total = 0.0
        let infoCount = MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info_data_t()
            var count = mach_msg_type_number_t(infoCount)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: infoCount) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
            mach_port_deallocate(mach_task_self_, threads[index])
        }
        return total
    }

    /// Cumulative per-core tick counters; diff two samples to get system-wide utilization.
    struct CPUTicks {
        var busy: UInt64
        var total: UInt64
    }

    static func systemCPUTicks() -> CPUTicks? {
        var cpuCount = natural_t(0)
        var infoArray: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount) == KERN_SUCCESS,
              let info = infoArray else { return nil }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * states
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return CPUTicks(busy: busy, total: total)
    }

    // MARK: Hardware

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            var value32: Int32 = 0
            var size32 = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value32, &size32, nil, 0) == 0 else { return nil }
            return Int(value32)
        }
        return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func machineIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = systemInfo.machine
        return withUnsafeBytes(of: machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Storage

    struct StorageStatus: Sendable {
        var total: Int64
        var availableForImportantUsage: Int64
    }

    static func storage() -> StorageStatus? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return StorageStatus(total: Int64(total), availableForImportantUsage: available)
    }

    /// Recursively sums allocated sizes of files below a directory.
    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
