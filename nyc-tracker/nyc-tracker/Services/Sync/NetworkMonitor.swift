import Foundation
import Network
import Observation

/// Reachability, as an observable flag plus an edge signal.
///
/// Two consumers with different needs: the sync status UI wants the current
/// value (`isReachable`), and the sync engine wants the *transition* into
/// reachable so it can drain the queue the instant airplane mode is switched
/// off. Publishing only the flag would make the engine poll it.
///
/// `NWPathMonitor` reports the OS's view of the interface, which is optimistic —
/// "reachable" on a captive-portal wifi is still reachable here. That is fine:
/// it is a scheduling hint, not a guarantee, and every request is written to
/// fail and back off on its own.
@Observable
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    private(set) var isReachable: Bool = true
    /// True when the connection is metered, so the pull can skip prefetching
    /// full-size images it doesn't strictly need.
    private(set) var isExpensive: Bool = false

    /// Fires on every false -> true transition.
    var onBecameReachable: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "nyclog.network-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            let expensive = path.isExpensive

            // NWPathMonitor calls back on its own queue; everything downstream is
            // main-actor state and a callback into the sync engine.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasReachable = self.isReachable
                self.isReachable = reachable
                self.isExpensive = expensive

                if reachable && !wasReachable {
                    self.onBecameReachable?()
                }
            }
        }
        monitor.start(queue: queue)
    }
}
