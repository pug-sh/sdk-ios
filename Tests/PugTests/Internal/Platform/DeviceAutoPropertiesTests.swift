import Foundation
import Testing

@testable import Pug

struct DeviceAutoPropertiesTests {
  private static var info: [String: Any] {
    [
      "CFBundleDisplayName": "Shop",
      "CFBundleName": "ShopApp",
      "CFBundleShortVersionString": "2.1",
      "CFBundleVersion": "210",
    ]
  }

  private let snapshot = Locked<DeviceSnapshot?>(nil)
  private let logger = RecordingLogger()

  @Test("the app, the device, the OS and the screen, with the locale, time zone and network of the moment")
  func properties() {
    snapshot.withLock {
      $0 = DeviceSnapshot(osVersion: "26.1", isPhone: true, screenWidth: 402, screenHeight: 874, screenScale: 3)
    }
    let properties = make(model: "iPhone17,1")

    #expect(properties.appVersion == "2.1")
    #expect(
      mapped(properties) == [
        "$os": .string("iOS"),
        "$osVersion": .string("26.1"),
        "$device": .string("iPhone 16 Pro"),
        "$deviceModel": .string("iPhone 16 Pro"),
        "$deviceManufacturer": .string("Apple"),
        "$deviceType": .string("mobile"),
        "$mobile": .bool(true),
        "$screenWidth": .int(402),
        "$screenHeight": .int(874),
        "$screenScale": .double(3),
        "$locale": .string("de-AT"),
        "$timezone": .string("Europe/Vienna"),
        "$networkType": .string("wifi"),
        "$appName": .string("Shop"),
        "$appPackage": .string("sh.pug.shop"),
        "$appVersion": .string("2.1"),
        "$appBuild": .string("210"),
      ]
    )
    #expect(logger.entries.isEmpty)
  }

  @Test("the screen follows the main thread's latest reading")
  func screenChanges() {
    let properties = make()
    snapshot.withLock {
      $0 = DeviceSnapshot(osVersion: "26.1", isPhone: true, screenWidth: 402, screenHeight: 874, screenScale: 3)
    }
    #expect(mapped(properties)["$screenWidth"] == .int(402))

    snapshot.withLock {
      $0 = DeviceSnapshot(osVersion: "26.1", isPhone: true, screenWidth: 874, screenHeight: 402, screenScale: 3)
    }

    #expect(mapped(properties)["$screenWidth"] == .int(874))
    #expect(mapped(properties)["$screenHeight"] == .int(402))
  }

  @Test("before the main thread has read them, the OS and the screen are left out")
  func noSnapshot() {
    let properties = mapped(make())

    for key in ["$osVersion", "$mobile", "$screenWidth", "$screenHeight", "$screenScale"] {
      #expect(properties[key] == nil, "\(key)")
    }
    #expect(properties["$os"] == .string("iOS"))
  }

  @Test("an iPad is not mobile, and an app running on a Mac is a desktop")
  func deviceTypes() {
    snapshot.withLock {
      $0 = DeviceSnapshot(osVersion: "26.1", isPhone: false, screenWidth: 820, screenHeight: 1180, screenScale: 2)
    }
    let iPad = mapped(make(model: "iPad13,18"))
    let mac = mapped(make(model: "Mac14,2", runsOnMac: true))

    #expect(iPad["$device"] == .string("iPad (10th generation)"))
    #expect(iPad["$deviceType"] == .string("mobile"))
    #expect(iPad["$mobile"] == .bool(false))
    #expect(mac["$device"] == .string("Mac14,2"))
    #expect(mac["$deviceType"] == .string("desktop"))
    #expect(mac["$mobile"] == .bool(false))
  }

  @Test("a model missing from the table is reported by its identifier")
  func unknownModel() {
    let properties = mapped(make(model: "iPhone99,1"))

    #expect(properties["$device"] == .string("iPhone99,1"))
    #expect(properties["$deviceModel"] == .string("iPhone99,1"))
  }

  @Test("the app's name falls back to its bundle name, and what is missing or empty is left out")
  func sparseInfo() {
    let properties = make(info: ["CFBundleName": "ShopApp", "CFBundleVersion": ""], bundleIdentifier: "", model: "")
    let mapped = mapped(properties)

    #expect(properties.appVersion == nil)
    #expect(mapped["$appName"] == .string("ShopApp"))
    for key in ["$appPackage", "$appVersion", "$appBuild", "$device", "$deviceModel"] {
      #expect(mapped[key] == nil, "\(key)")
    }
  }

  @Test(
    "the locale is the preferred language with the chosen region",
    arguments: [
      ("en-US", "US", "en-US"),
      ("en", "GB", "en-GB"),
      ("zh-Hans-CN", "TW", "zh-TW"),
      ("es-419", "419", "es-419"),
      ("pt_BR", "br", "pt-BR"),
      ("EN-us", nil, "en"),
      ("fil-PH", "PH", "fil-PH"),
      ("en", "gbzzzz", "en"),
      ("en", "", "en"),
    ] as [(String, String?, String)]
  )
  func languageTag(language: String, region: String?, tag: String) {
    #expect(DeviceAutoProperties.languageTag(preferredLanguage: language, regionCode: region) == tag)
  }

  @Test("no usable preferred language, no locale", arguments: [nil, "", "e", "english", "1a-US", "é-FR"])
  func noLanguageTag(language: String?) {
    #expect(DeviceAutoProperties.languageTag(preferredLanguage: language, regionCode: "US") == nil)
  }

  @Test("the install source follows the receipt: simulator, TestFlight or the App Store")
  func installSource() throws {
    let sandbox = try #require(
      URL(string: "file:///var/containers/Bundle/Application/A/Shop.app/StoreKit/sandboxReceipt"))
    let store = try #require(URL(string: "file:///var/containers/Bundle/Application/A/Shop.app/StoreKit/receipt"))

    #expect(InstallSource.of(receiptURL: store, isSimulator: true) == "com.apple.simulator")
    #expect(InstallSource.of(receiptURL: sandbox, isSimulator: false) == "com.apple.testflight")
    #expect(InstallSource.of(receiptURL: store, isSimulator: false) == "com.apple")
    #expect(InstallSource.of(receiptURL: nil, isSimulator: false) == nil)
  }

  @Test("the table names current and older models")
  func models() {
    #expect(DeviceModels.name("iPhone8,1") == "iPhone 6s")
    #expect(DeviceModels.name("iPhone17,3") == "iPhone 16")
    #expect(DeviceModels.name("iPhone18,4") == "iPhone Air")
    #expect(DeviceModels.name("iPad16,6") == "iPad Pro 13-inch (M4)")
    #expect(DeviceModels.name("iPod9,1") == "iPod touch (7th generation)")
    #expect(DeviceModels.name("x86_64") == nil)
  }

  private func make(
    info: [String: Any] = info,
    bundleIdentifier: String? = "sh.pug.shop",
    model: String? = "iPhone17,1",
    runsOnMac: Bool = false
  ) -> DeviceAutoProperties {
    DeviceAutoProperties(
      info: info,
      bundleIdentifier: bundleIdentifier,
      model: model,
      runsOnMac: runsOnMac,
      snapshot: snapshot,
      environment: DeviceEnvironment(
        preferredLanguage: { "de-DE" },
        regionCode: { "AT" },
        timeZone: { "Europe/Vienna" },
        networkType: { "wifi" }
      )
    )
  }

  private func mapped(_ properties: DeviceAutoProperties) -> [String: PropertyValue] {
    PropertyMapper(logger: logger.safe()).mapAuto(kind: "a", properties.current())
  }
}
