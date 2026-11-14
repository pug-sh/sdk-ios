import Pug
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before the first scene connects, so that the launch's app_open and first screen are tracked.
    do {
      try Pug.initialize(projectId: Sample.projectId, options: Sample.options)
    } catch {
      assertionFailure("Pug was not started: \(error)")
    }
    return true
  }
}

/// The project that Local.xcconfig names, as Info.plist carries it. Without an API key the sample runs in dry run,
/// logging events without sending them.
enum Sample {
  static let projectId = setting("PugProjectID") ?? "sample-project"

  static let options: Pug.Options = {
    let apiKey = setting("PugAPIKey")
    var options = Pug.Options(apiKey: apiKey ?? "pub_dry_run")
    if let endpoint = setting("PugEndpoint").flatMap(URL.init(string:)) {
      options.endpoint = endpoint
    }
    options.dryRun = apiKey == nil
    // Every event in the log: Xcode's console, or Console.app's for the subsystem sh.pug.
    options.debug = true
    return options
  }()

  private static func setting(_ key: String) -> String? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
    return value
  }
}
