#if canImport(SwiftUI)
import SwiftUI

extension View {
  /// Tracks this view as the screen `name`, as Pug tracks a view controller, with `autoScreenViews` off too. Put it on
  /// the view a screen shows, inside its `NavigationStack`; a new name is a new screen.
  public func pugScreen(_ name: String) -> some View {
    #if os(iOS)
    // A new name makes a new controller, which UIKit tells of the appearance again.
    background { NamedScreen(name: name).id(name) }
    #else
    onAppear { Pug.screen(name) }
    #endif
  }
}

#if os(iOS)
private struct NamedScreen: UIViewControllerRepresentable {
  let name: String

  func makeUIViewController(context: Context) -> NamedScreenController {
    NamedScreenController(name: name)
  }

  func updateUIViewController(_ controller: NamedScreenController, context: Context) {}
}
#endif
#endif
