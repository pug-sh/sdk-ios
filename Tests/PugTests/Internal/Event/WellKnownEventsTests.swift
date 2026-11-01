import Testing

@testable import Pug

struct WellKnownEventsTests {
  @Test("the protos are read with their options")
  func protosAreRead() throws {
    let events = try EventProtos.ios()

    let kinds = events.map(\.kind)
    #expect(kinds.contains("screen_view") && kinds.contains("add_to_cart"))
    #expect(!kinds.contains("page_view"), "page_view is for the web only")
    let screenView = try #require(events.first { $0.kind == "screen_view" })
    #expect(screenView.properties.map(\.required) == [true, false])
  }

  @Test("the registry has every iOS event with its properties, in schema order")
  func registryMatchesProtos() throws {
    let events = try EventProtos.ios()

    #expect(WellKnownEvents.all.map(\.kind) == events.map(\.kind))
    #expect(WellKnownEvents.byKind.count == events.count)
    for event in events {
      let schema = try #require(WellKnownEvents.byKind[event.kind], "\(event.kind)")
      #expect(schema.kind == event.kind)
      #expect(schema.label == "track.\(event.method)")
      #expect(
        schema.fields.map { EventProtos.Property(name: $0.name, type: $0.type, required: $0.required) }
          == event.properties,
        "\(event.kind)"
      )
    }
  }

  @Test("Pug.Events names each kind in lower camel case")
  func eventKinds() {
    #expect(Pug.Events.addToCart == "add_to_cart")
    #expect(Pug.Events.screenView == "screen_view")
    #expect(Pug.Events.chatAttachmentDownloaded == "chat_attachment_downloaded")
    #expect(Pug.Events.workspaceSettingsUpdated == "workspace_settings_updated")
  }

  @Test("a field is found by its name")
  func fieldByName() {
    #expect(WellKnownEvents.addToCart.field("price")?.type == .double)
    #expect(WellKnownEvents.addToCart.field("productId")?.required == true)
    #expect(WellKnownEvents.addToCart.field("missing") == nil)
  }
}
