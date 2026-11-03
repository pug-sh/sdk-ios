import Foundation

enum InstallSource {
  /// Where an iOS app came from, told by the path of its App Store receipt as Pug's Flutter SDK tells it: the
  /// simulator, TestFlight for a sandbox receipt (which builds Xcode installs have too), else the App Store.
  static func of(receiptURL: URL?, isSimulator: Bool) -> String? {
    if isSimulator {
      return "com.apple.simulator"
    }
    guard let receiptURL else { return nil }
    return receiptURL.lastPathComponent == "sandboxReceipt" ? "com.apple.testflight" : "com.apple"
  }
}
