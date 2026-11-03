#if canImport(Network)
import Foundation
import Network

/// The kind of network the device is on, from `NWPathMonitor`, which needs no permission: `unknown` until it first
/// reports. One per process, started on first use and never stopped.
final class NetworkMonitor: @unchecked Sendable {
  static let shared = NetworkMonitor()

  // Unchecked because not every SDK marks NWPathMonitor Sendable; it is only touched here, as it starts.
  private let monitor = NWPathMonitor()
  private let latest = Locked<String?>(nil)

  private init() {
    let latest = self.latest
    monitor.pathUpdateHandler = { path in
      let kind = Self.kind(of: path)
      latest.withLock { $0 = kind }
    }
    monitor.start(queue: DispatchQueue(label: "sh.pug.network", qos: .utility))
  }

  var networkType: String {
    latest.withLock { $0 } ?? "unknown"
  }

  private static func kind(of path: NWPath) -> String {
    guard path.status == .satisfied else { return "none" }
    if path.usesInterfaceType(.wifi) {
      return "wifi"
    }
    if path.usesInterfaceType(.cellular) {
      return "mobile"
    }
    if path.usesInterfaceType(.wiredEthernet) {
      return "ethernet"
    }
    return "other"
  }
}
#endif
