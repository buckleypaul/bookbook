import Foundation
import Network

/// Reports whether the network is usable (A §7.9 "Offline"). `AppModel` forwards each change
/// to `GenerationQueue.setOnline` and `isOnline`. Tests pass a fake.
public protocol NetworkStatusSource: Sendable {
    /// A new stream per call: the current status first, then every change. True = online.
    func statusUpdates() -> AsyncStream<Bool>
}

/// `NWPathMonitor`: online while the path is `.satisfied`.
public struct NetworkMonitor: NetworkStatusSource {
    public init() {}

    public func statusUpdates() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "app.bookbook.network-monitor"))
        }
    }
}
