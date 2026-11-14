import UIKit

extension UIViewController {
  /// Lays `views` out in a column, which scrolls when it does not fit.
  func showColumn(_ views: [UIView]) {
    let column = UIStackView(arrangedSubviews: views)
    column.axis = .vertical
    column.spacing = 12
    let scroll = UIScrollView()
    scroll.addSubview(column)
    view.addSubview(scroll)
    for subview in [column, scroll] {
      subview.translatesAutoresizingMaskIntoConstraints = false
    }
    let content = scroll.contentLayoutGuide
    let margins = view.layoutMarginsGuide
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      column.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
      column.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
      column.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
    ])
  }

  func button(_ title: String, handler: @escaping UIActionHandler) -> UIButton {
    UIButton(configuration: .filled(), primaryAction: UIAction(title: title, handler: handler))
  }
}
