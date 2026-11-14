import Pug
import SwiftUI
import UIKit

/// The first screen. Pug tracks the app's own view controllers as screens by itself, this one as
/// `HomeViewController`.
final class HomeViewController: UIViewController {
  private let status = UILabel()
  private var taps = 0

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Pug sample"
    view.backgroundColor = .systemBackground
    status.numberOfLines = 0
    showColumn([
      status,
      button("Track a custom event") { [weak self] _ in self?.trackTap() },
      button("Track a search (typed)") { _ in Pug.track.search(query: "trail shoes") },
      button("Open a product") { [weak self] _ in self?.show(ProductViewController(), sender: nil) },
      button("Identify sample-user-42") { _ in Pug.identify("sample-user-42", traits: ["plan": "pro", "beta": true]) },
      button("Reset (log out)") { _ in Pug.reset() },
      button("Flush") { _ in Pug.flush() },
      button("Tracking consent (SwiftUI)") { [weak self] _ in self?.showConsent() },
    ])
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    Pug.whenConsentReady { [weak self] in self?.showStatus() }
  }

  private func trackTap() {
    taps += 1
    Pug.track("sample_button_tapped", properties: ["button": "track_event", "taps": taps])
  }

  private func showConsent() {
    let consent = UIHostingController(rootView: ConsentView())
    consent.title = "Tracking consent"
    show(consent, sender: nil)
  }

  private func showStatus() {
    let mode =
      Sample.options.dryRun
      ? "Dry run: events are logged, not sent. Set PUG_API_KEY in Local.xcconfig to send them."
      : "Sending to \(Sample.options.endpoint.absoluteString)"
    status.text = "\(mode)\n\nTracking consent: \(Pug.trackingConsent.map { "\($0)" } ?? "not known yet")"
  }
}
