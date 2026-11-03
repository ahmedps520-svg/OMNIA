import Foundation
import SwiftData

/// Measured facts about this device and how models run on it, for tuning how models are fitted
/// to it: memory limits, loads and speeds. Model names and numbers only: no conversations,
/// prompts, documents or file paths.
struct DeviceReport: Codable, Sendable {
    struct Device: Codable, Sendable {
        var identifier: String
        var name: String
        var chip: String
        var deviceClass: String
        var system: String
        var simulator: Bool
        var physicalMemoryBytes: UInt64
        var cpuCores: Int
        var performanceCores: Int
        var efficiencyCores: Int
        var gpu: String
        var gpuRecommendedWorkingSetBytes: UInt64?
        var memoryBandwidthGBs: Double
    }

    struct Memory: Codable, Sendable {
        var footprintBytes: UInt64?
        var availableBytes: UInt64?
        /// Footprint plus what's still available: the limit iOS applies to OMNIA, measured now.
        var limitBytes: UInt64?
        var gpuAllocatedBytes: UInt64?
        var pressure: String
        var lastPressureEvent: Date?
        var thermalState: String
        var lowPowerMode: Bool
    }

    struct Settings: Codable, Sendable {
        var profile: String
        var profilePreference: String
        var memorySafety: String
        /// 0 means automatic.
        var contextLength: Int
        var automaticContext: Int
        var kvCache: String
        var flashAttention: Bool
        var gpuAcceleration: Bool
        var keepModelsLoadedInBackground: Bool
    }

    /// A model loaded when the report was made, with what its load measured.
    struct Loaded: Codable, Sendable {
        var model: String
        var contextLength: Int
        var kvCache: String
        var flashAttention: Bool
        var gpuOffload: Bool
        var measuredFootprintBytes: UInt64
        var measuredGPUBytes: UInt64
        var loadSeconds: Double
    }

    struct Model: Codable, Sendable {
        var id: String
        var name: String
        var architecture: String
        var parameterBillions: Double
        var activeParameterBillions: Double
        var quantization: String?
        var fileBytes: UInt64
        var imageEncoderBytes: UInt64?
        var layers: Int
        var trainContext: Int
        /// What its last load measured, at that load's context.
        var measuredFootprintBytes: UInt64?
        var measuredGPUBytes: UInt64?
        var measuredAtContext: Int?
        var benchmark: Benchmark?
        var speeds: Speeds?
    }

    struct Benchmark: Codable, Sendable {
        var date: Date?
        var context: Int?
        var promptTokens: Int
        var generatedTokens: Int
        var promptTokensPerSecond: Double
        var tokensPerSecond: Double
        var timeToFirstToken: Double
        var peakFootprintBytes: UInt64
        var repetitions: Int
    }

    /// Medians over the replies recorded on this device (chats and comparisons).
    struct Speeds: Codable, Sendable, Equatable {
        struct Sample: Sendable {
            var tokensPerSecond: Double
            var promptTokensPerSecond: Double
            var timeToFirstToken: Double
            var promptTokens: Int
            var contextSize: Int
        }

        var replies: Int
        var medianTokensPerSecond: Double
        var medianPromptTokensPerSecond: Double
        var medianTimeToFirstToken: Double
        var medianPromptTokens: Int
        var largestContext: Int

        init?(_ samples: [Sample]) {
            guard !samples.isEmpty else { return nil }
            replies = samples.count
            medianTokensPerSecond = Self.median(samples.map(\.tokensPerSecond))
            medianPromptTokensPerSecond = Self.median(samples.map(\.promptTokensPerSecond))
            medianTimeToFirstToken = Self.median(samples.map(\.timeToFirstToken))
            medianPromptTokens = Int(Self.median(samples.map { Double($0.promptTokens) }).rounded())
            largestContext = samples.map(\.contextSize).max() ?? 0
        }

        /// The median of the finite values (JSON has no NaN or infinity), 0 when there are none.
        static func median(_ values: [Double]) -> Double {
            let sorted = values.filter(\.isFinite).sorted()
            guard !sorted.isEmpty else { return 0 }
            let middle = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        }
    }

    var created: Date
    var app: String
    var device: Device
    var memory: Memory
    var settings: Settings
    var loaded: [Loaded]
    var models: [Model]

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

extension DeviceReport {
    @MainActor
    static func make(_ services: AppServices = .shared) -> DeviceReport {
        let device = services.device
        let engine = services.engine
        let settings = services.settings
        let footprint = SystemMetrics.processFootprint()
        let available = SystemMetrics.availableMemory()

        var recent = FetchDescriptor<InferenceRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        recent.fetchLimit = 2000
        let records = (try? services.container.mainContext.fetch(recent)) ?? []
        let replies = Dictionary(grouping: records.filter { $0.kindRaw != InferenceRecord.Kind.benchmark.rawValue }, by: \.modelID)
            .mapValues { records in
                Speeds(records.map {
                    Speeds.Sample(tokensPerSecond: $0.tokensPerSecond, promptTokensPerSecond: $0.promptTokensPerSecond,
                                  timeToFirstToken: $0.timeToFirstToken, promptTokens: $0.promptTokens, contextSize: $0.contextSize)
                })
            }

        return DeviceReport(
            created: .now,
            app: Bundle.main.versionDescription,
            device: Device(
                identifier: device.identifier, name: device.name, chip: device.chip, deviceClass: device.deviceClass.rawValue,
                system: device.systemVersion, simulator: device.isSimulator, physicalMemoryBytes: device.physicalMemory,
                cpuCores: device.cpuCores, performanceCores: device.performanceCores, efficiencyCores: device.efficiencyCores,
                gpu: device.gpuName, gpuRecommendedWorkingSetBytes: device.gpuRecommendedWorkingSet,
                memoryBandwidthGBs: device.memoryBandwidthGBs),
            memory: Memory(
                footprintBytes: footprint, availableBytes: available,
                limitBytes: footprint.flatMap { used in available.map { used + $0 } },
                gpuAllocatedBytes: SystemMetrics.gpuAllocatedBytes(),
                pressure: services.monitor.pressure.rawValue, lastPressureEvent: services.monitor.lastPressureEvent,
                thermalState: ProcessInfo.processInfo.thermalState.title,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled),
            settings: Settings(
                profile: engine.profile.kind.rawValue, profilePreference: settings.profilePreference.rawValue,
                memorySafety: settings.memorySafety.rawValue, contextLength: settings.contextLength,
                automaticContext: engine.profile.defaultContext, kvCache: settings.kvCache.rawValue,
                flashAttention: settings.flashAttention, gpuAcceleration: settings.gpuAcceleration,
                keepModelsLoadedInBackground: settings.keepModelsLoadedInBackground),
            loaded: engine.loadedModels.map { entry in
                let info = entry.info
                return Loaded(model: info.displayName, contextLength: info.configuration.contextLength,
                              kvCache: String(describing: info.configuration.kvCacheType),
                              flashAttention: info.configuration.flashAttention, gpuOffload: info.configuration.gpuOffload,
                              measuredFootprintBytes: info.measuredFootprintBytes, measuredGPUBytes: info.measuredGPUBytes,
                              loadSeconds: info.loadDuration)
            },
            models: services.store.models.filter { !$0.isSystem }.map { model in
                Model(id: model.id, name: model.displayName, architecture: model.facts.architecture,
                      parameterBillions: model.facts.parameters, activeParameterBillions: model.facts.activeParameters,
                      quantization: model.quantization, fileBytes: model.sizeBytes, imageEncoderBytes: model.projector?.sizeBytes,
                      layers: model.facts.layers, trainContext: model.facts.trainContext,
                      measuredFootprintBytes: model.measuredFootprint, measuredGPUBytes: model.measuredGPUBytes,
                      measuredAtContext: model.measuredContext,
                      benchmark: model.benchmark.map { benchmark in
                          Benchmark(date: model.benchmarkDate, context: model.benchmarkContext,
                                    promptTokens: benchmark.promptTokens, generatedTokens: benchmark.generatedTokens,
                                    promptTokensPerSecond: finite(benchmark.promptTokensPerSecond),
                                    tokensPerSecond: finite(benchmark.tokensPerSecond),
                                    timeToFirstToken: finite(benchmark.timeToFirstToken),
                                    peakFootprintBytes: benchmark.peakFootprintBytes, repetitions: benchmark.repetitions)
                      },
                      speeds: replies[model.id] ?? nil)
            })
    }

    /// JSON has no NaN or infinity.
    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
