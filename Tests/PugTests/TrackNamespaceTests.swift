import Foundation
import Testing

@testable import Pug

struct TrackNamespaceTests {
  /// Maps each call as the client will, and keeps the result.
  private final class RecordingFacade: TypedTracking {
    struct Call: Equatable {
      let kind: String
      let properties: [String: PropertyValue]
      let options: Pug.TrackOptions?
    }

    private let mapper: PropertyMapper
    private let recorded = Locked<[Call]>([])

    init(mapper: PropertyMapper) {
      self.mapper = mapper
    }

    var calls: [Call] {
      recorded.withLock { $0 }
    }

    func trackTyped(_ event: EventSchema, _ values: [Any?], extras: [String: Any]?, options: Pug.TrackOptions?) {
      let properties = mapper.mapTyped(event, values: values, extras: extras)
      recorded.withLock { $0.append(Call(kind: event.kind, properties: properties, options: options)) }
    }
  }

  private let logger = RecordingLogger()
  private let facade: RecordingFacade
  private let track: Pug.TrackNamespace

  init() {
    facade = RecordingFacade(mapper: PropertyMapper(logger: logger.safe()))
    track = Pug.TrackNamespace(facade: facade)
  }

  @Test("each method tracks its event, with the arguments that are set as properties of their types")
  func arguments() {
    track.addToCart(productId: "p1", price: 9.99, quantity: 2)
    track.fileUploaded(fileId: "f1", sizeBytes: 5_000_000_000)
    track.errorOccurred(errorCode: "E1", unhandled: false)
    track.share()

    #expect(facade.calls.map(\.kind) == ["add_to_cart", "file_uploaded", "error_occurred", "share"])
    #expect(
      facade.calls.map(\.properties) == [
        ["productId": .string("p1"), "price": .double(9.99), "quantity": .int(2)],
        ["fileId": .string("f1"), "sizeBytes": .int(5_000_000_000)],
        ["errorCode": .string("E1"), "unhandled": .bool(false)],
        [:],
      ]
    )
    #expect(logger.entries.isEmpty)
  }

  @Test("a duration is sent in seconds, rounded to the millisecond")
  func durations() {
    track.videoSeeked(videoId: "v1", fromPosition: 1.5, toPosition: 61)
    track.audioPause(audioId: "a1", position: 1.2346)

    #expect(
      facade.calls.map(\.properties) == [
        ["videoId": .string("v1"), "fromPosition": .string("1.5s"), "toPosition": .string("61s")],
        ["audioId": .string("a1"), "position": .string("1.235s")],
      ]
    )
  }

  @Test("a duration that is not finite or does not fit is dropped with a warning")
  func unusableDurations() {
    track.videoPlay(videoId: "v1", position: .nan)
    track.videoPause(videoId: "v1", position: 1e300)

    #expect(facade.calls.map(\.properties) == [["videoId": .string("v1")], ["videoId": .string("v1")]])
    #expect(
      logger.warnings == [
        "Property \"position\" on event \"video_play\" was dropped: nan is not a finite number",
        "Property \"position\" on event \"video_pause\" was dropped: it is out of range",
      ]
    )
  }

  @Test("extras are sent too, but an argument that is set wins over an extra of its name")
  func extras() {
    track.addToCart(
      productId: "p1",
      price: 9.99,
      extras: ["price": 1.5, "currency": "EUR", "coupon": "SPRING"]
    )

    let expected: [String: PropertyValue] = [
      "productId": .string("p1"),
      "price": .double(9.99),
      "currency": .string("EUR"),
      "coupon": .string("SPRING"),
    ]
    #expect(facade.calls.map(\.properties) == [expected])
    #expect(
      logger.warnings == ["Extra \"price\" of Pug.track.addToCart() was dropped: the event's own price is set"]
    )
  }

  @Test("a whole number in the extras for a double property is sent as a double")
  func extrasCoercion() {
    track.addToCart(productId: "p1", extras: ["price": 10])

    #expect(facade.calls.first?.properties["price"] == .double(10))
  }

  @Test("arguments and extras get the checks of untyped properties")
  func checks() {
    track.addToCart(productId: String(repeating: "x", count: 2_000), extras: ["$sku": "s1"])
    track.chatAttachmentDownloaded(conversationId: "c1", attachmentId: "a1", extras: ["attachmentId": "a2"])

    #expect(facade.calls.first?.properties["productId"] == .string(String(repeating: "x", count: 1_024)))
    #expect(facade.calls.last?.properties == ["conversationId": .string("c1"), "attachmentId": .string("a1")])
    #expect(
      logger.warnings == [
        "Property \"$sku\" on event \"add_to_cart\" was dropped: keys starting with '$' are reserved",
        "Property \"productId\" on event \"add_to_cart\" was truncated to 1024 bytes",
        "Extra \"attachmentId\" of Pug.track.chatAttachmentDownloaded() was dropped: the event's own "
          + "attachmentId is set",
      ]
    )
  }

  @Test("options are passed on as they are")
  func options() {
    let options = Pug.TrackOptions(immediate: true, timestamp: Date(timeIntervalSince1970: 42))

    track.scroll()
    track.share(options: options)

    #expect(facade.calls.map(\.options) == [nil, options])
  }
}
