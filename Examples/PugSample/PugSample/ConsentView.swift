import Pug
import SwiftUI

/// A SwiftUI screen, which names itself: Pug tracks view controllers, not SwiftUI views.
struct ConsentView: View {
  @StateObject private var consent = Consent()

  var body: some View {
    Form {
      Section {
        Text("Consent: \(consent.value.map { "\($0)" } ?? "not known yet")")
        Text(consent.isPending ? "The user has yet to choose" : "The user has chosen")
      }
      Section {
        Button("Opt in") { consent.optIn() }
        Button("Opt out", role: .destructive) { consent.optOut() }
      }
    }
    .pugScreen("Consent")
  }
}

/// Pug's consent getters, read again once they are known and after each choice.
@MainActor
private final class Consent: ObservableObject {
  @Published private(set) var value: Pug.TrackingConsent?
  @Published private(set) var isPending = true

  init() {
    Pug.whenConsentReady { [weak self] in self?.refresh() }
  }

  func optIn() {
    Pug.optInTracking()
    refresh()
  }

  func optOut() {
    Pug.optOutTracking()
    refresh()
  }

  private func refresh() {
    value = Pug.trackingConsent
    isPending = Pug.isConsentPending
  }
}
