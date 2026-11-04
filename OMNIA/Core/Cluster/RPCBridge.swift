import Foundation
import llama

/// llama.cpp's RPC backend, which cluster mode runs on. It's reached through ggml's backend
/// registry rather than its header, so OMNIA still builds against a llama.cpp without it; cluster
/// mode is then unavailable (`isAvailable` is false).
///
/// OMNIA's own build of llama.cpp (scripts/build-llama-xcframework.sh) includes the backend and
/// adds three functions to it (scripts/llama/cluster.patch) so that a worker dropping out ends a
/// request, not the app: the failed connections, clearing them, and dropping one on purpose.
enum RPCBridge {
    private typealias AddServer = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
    private typealias StartServer = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int, Int,
                                                    UnsafeMutablePointer<OpaquePointer?>?) -> Void
    private typealias FailedEndpoints = @convention(c) (UnsafeMutablePointer<CChar>?, Int) -> Int
    private typealias ClearFailures = @convention(c) () -> Void
    private typealias Disconnect = @convention(c) (UnsafePointer<CChar>?) -> Void

    private struct Functions {
        let addServer: AddServer
        let startServer: StartServer
        let failedEndpoints: FailedEndpoints
        let clearFailures: ClearFailures
        let disconnect: Disconnect
    }

    private static let functions: Functions? = {
        LlamaRuntime.prepareBackend()
        // Never ask two workers to connect to each other directly (llama.cpp's tensor-parallel
        // "COMM_INIT"): the worker would listen on every interface itself, bypassing its relay.
        setenv("GGML_RPC_NO_COMM", "1", 1)
        guard let registry = ggml_backend_reg_by_name("RPC") else { return nil }
        func function<T>(_ name: String, as type: T.Type) -> T? {
            guard let address = ggml_backend_reg_get_proc_address(registry, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        guard let addServer = function("ggml_backend_rpc_add_server", as: AddServer.self),
              let startServer = function("ggml_backend_rpc_start_server", as: StartServer.self),
              let failedEndpoints = function("ggml_backend_rpc_failed_endpoints", as: FailedEndpoints.self),
              let clearFailures = function("ggml_backend_rpc_clear_failures", as: ClearFailures.self),
              let disconnect = function("ggml_backend_rpc_disconnect", as: Disconnect.self) else { return nil }
        return Functions(addServer: addServer, startServer: startServer, failedEndpoints: failedEndpoints,
                         clearFailures: clearFailures, disconnect: disconnect)
    }()

    /// This build of llama.cpp can join a cluster and run models across one.
    static var isAvailable: Bool { functions != nil }

    /// The devices a worker serves (its GPUs), connecting to it if needed. Empty when it can't be
    /// reached within a few seconds, or speaks another protocol version.
    static func devices(at endpoint: String) -> [OpaquePointer] {
        guard let functions, let registry = functions.addServer(endpoint) else { return [] }
        return (0..<ggml_backend_reg_dev_count(registry)).compactMap { ggml_backend_reg_dev_get(registry, $0) }
    }

    /// The device this one computes on for a cluster: its GPU, or the CPU in the Simulator.
    static var localDevice: OpaquePointer? {
        #if targetEnvironment(simulator)
        return ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU)
        #else
        return ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU) ?? ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU)
        #endif
    }

    /// Serves `device` to a cluster host on `endpoint` ("127.0.0.1:port"). Never returns while the
    /// server runs, so it gets a thread of its own. Large weights the host sends are kept in
    /// `cacheDirectory`, so loading the same model again reads them from flash instead.
    static func runServer(endpoint: String, cacheDirectory: String?, threads: Int, device: OpaquePointer) {
        guard let functions else { return }
        let cache = cacheDirectory.flatMap { strdup($0) }
        defer { free(cache) }
        var devices: [OpaquePointer?] = [device]
        devices.withUnsafeMutableBufferPointer { buffer in
            functions.startServer(endpoint, cache, threads, 1, buffer.baseAddress)
        }
    }

    /// Endpoints whose connection failed since the last `clearFailures()`.
    static func failedEndpoints() -> [String] {
        guard let functions else { return [] }
        var buffer = [CChar](repeating: 0, count: 2048)
        let count = buffer.withUnsafeMutableBufferPointer { functions.failedEndpoints($0.baseAddress, $0.count) }
        guard count > 0 else { return [] }
        let joined = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return joined.split(separator: ",").map(String.init)
    }

    static func clearFailures() {
        functions?.clearFailures()
    }

    /// Drops the connection to a worker that has gone, so work waiting on it fails at once
    /// instead of after llama.cpp's timeout.
    static func disconnect(_ endpoint: String) {
        functions?.disconnect(endpoint)
    }
}
