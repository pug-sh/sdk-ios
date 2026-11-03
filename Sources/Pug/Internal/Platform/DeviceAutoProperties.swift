import Foundation

/// What only the main thread can read, from `UIDevice` and the screen, in points.
struct DeviceSnapshot: Equatable, Sendable {
  var osVersion: String
  var isPhone: Bool
  var screenWidth: Double
  var screenHeight: Double
  var screenScale: Double
}

/// Where the values that change while the app runs come from, read for each event on the worker.
struct DeviceEnvironment: Sendable {
  var preferredLanguage: @Sendable () -> String?
  var regionCode: @Sendable () -> String?
  var timeZone: @Sendable () -> String?
  var networkType: @Sendable () -> String?
}

/// The auto-properties of an iOS device. The app and the model are read once; the OS and the screen as the main thread
/// last saw them; the locale, time zone and network for each event.
struct DeviceAutoProperties: AutoProperties {
  let appVersion: String?
  private let fixed: [String: String]
  private let runsOnMac: Bool
  private let snapshot: Locked<DeviceSnapshot?>
  private let environment: DeviceEnvironment

  /// `info` is the app's Info.plist, `model` the hardware identifier, such as `iPhone17,3`.
  init(
    info: [String: Any],
    bundleIdentifier: String?,
    model: String?,
    runsOnMac: Bool,
    snapshot: Locked<DeviceSnapshot?>,
    environment: DeviceEnvironment
  ) {
    func string(_ key: String) -> String? {
      (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    var fixed = ["$os": "iOS", "$deviceManufacturer": "Apple"]
    if let model, !model.isEmpty {
      let name = DeviceModels.name(model) ?? model
      fixed["$device"] = name
      fixed["$deviceModel"] = name
    }
    fixed["$appName"] = string("CFBundleDisplayName") ?? string("CFBundleName")
    fixed["$appPackage"] = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
    fixed["$appVersion"] = string("CFBundleShortVersionString")
    fixed["$appBuild"] = string("CFBundleVersion")
    appVersion = fixed["$appVersion"]
    self.fixed = fixed
    self.runsOnMac = runsOnMac
    self.snapshot = snapshot
    self.environment = environment
  }

  func current() -> [String: Any] {
    var properties: [String: Any] = fixed
    properties["$deviceType"] = runsOnMac ? "desktop" : "mobile"
    if let snapshot = snapshot.withLock({ $0 }) {
      if !snapshot.osVersion.isEmpty {
        properties["$osVersion"] = snapshot.osVersion
      }
      properties["$mobile"] = snapshot.isPhone && !runsOnMac
      if let width = Int(exactly: snapshot.screenWidth.rounded()),
        let height = Int(exactly: snapshot.screenHeight.rounded()),
        snapshot.screenScale > 0
      {
        properties["$screenWidth"] = width
        properties["$screenHeight"] = height
        properties["$screenScale"] = snapshot.screenScale
      }
    }
    properties["$locale"] = Self.languageTag(
      preferredLanguage: environment.preferredLanguage(),
      regionCode: environment.regionCode()
    )
    properties["$timezone"] = environment.timeZone()
    properties["$networkType"] = environment.networkType()
    return properties
  }

  /// A BCP 47 tag such as `en-US`: the language the user prefers, which the app's own locale reports only when the app
  /// is localized for it, and the region they chose. Never a raw identifier such as `en_US@rg=gbzzzz`.
  static func languageTag(preferredLanguage: String?, regionCode: String?) -> String? {
    guard
      let language = preferredLanguage?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first,
      (2...3).contains(language.utf8.count), language.utf8.allSatisfy(isASCIILetter)
    else { return nil }
    let tag = language.lowercased()
    guard let regionCode else { return tag }
    let region = regionCode.utf8
    let isAlpha2 = region.count == 2 && region.allSatisfy(isASCIILetter)
    let isNumeric = region.count == 3 && region.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    guard isAlpha2 || isNumeric else { return tag }
    return "\(tag)-\(regionCode.uppercased())"
  }

  private static func isASCIILetter(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20)
  }
}
