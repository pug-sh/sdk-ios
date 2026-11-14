import Pug
import UIKit

private let productId = "sku-1"
private let price = 89.0

/// A screen with typed events, tracked as `ProductViewController` each time it appears.
final class ProductViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Trail runner"
    view.backgroundColor = .systemBackground
    Pug.track.productViewed(productId: productId, productName: "Trail runner", price: price, currency: "USD")
    let details = UILabel()
    details.text = "Trail runner, $89.00"
    showColumn([
      details,
      button("Add to cart") { _ in
        Pug.track.addToCart(productId: productId, price: price, currency: "USD", quantity: 1)
      },
      button("Buy now (sent immediately)") { _ in
        Pug.track.purchase(
          productId: productId,
          amount: price,
          currency: "USD",
          orderId: "order-\(UUID().uuidString.prefix(8))",
          extras: ["giftWrap": false],
          options: Pug.TrackOptions(immediate: true)
        )
      },
    ])
  }
}
