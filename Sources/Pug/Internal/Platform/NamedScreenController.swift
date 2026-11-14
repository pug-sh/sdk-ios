#if os(iOS)
import UIKit

/// What `pugScreen(_:)` puts behind a SwiftUI view: an invisible child of the view's hosting controller, which UIKit
/// tells of the view's appearance as it tells a view controller of its own. It reports itself, so that it is tracked
/// with the view controller hooks off too.
final class NamedScreenController: UIViewController {
  let name: String

  init(name: String) {
    self.name = name
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func loadView() {
    let view = UIView()
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    self.view = view
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    ScreenTracker.shared.namedScreenDidAppear(self)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    ScreenTracker.shared.namedScreenDidDisappear(self)
  }
}
#endif
