import Foundation
import Network
import Observation

/// Tracks network reachability so OMNIA can show offline readiness honestly.
/// Inference never touches the network; only model discovery and downloads do.
@MainActor
@Observable
final class ConnectivityMonitor {
    private(set) var isOnline = true
    private(set) var isExpensive = false
    private(set) var isConstrained = false
    private(set) var interface: String = "—"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.omnia.network")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let name: String
            if path.usesInterfaceType(.wifi) { name = "Wi-Fi" }
            else if path.usesInterfaceType(.cellular) { name = "Cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { name = "Ethernet" }
            else { name = online ? "Network" : "Offline" }
            Task { @MainActor in
                self?.isOnline = online
                self?.isExpensive = expensive
                self?.isConstrained = constrained
                self?.interface = name
            }
        }
        monitor.start(queue: queue)
    }
}
