import Foundation
import SwiftProtobuf
import Testing

@testable import Pug

/// The whole pipeline on a real worker, over HTTP, with requests decoded by swift-protobuf.
final class EndToEndTests {
  private static let project = "proj_e2e"

  private let server: StubServer
  private let logger = RecordingLogger()

  init() throws {
    server = try StubServer()
  }

  deinit {
    server.close()
  }

  @Test("tracked events reach the server as one batch")
  func batch() async throws {
    try acknowledge(3)
    let client = try makeClient { $0.batchMaxSize = 3 }

    client.track("checkout_started", properties: ["cartId": "c1", "items": 2], options: nil)
    client.track("add_to_cart", properties: ["price": 9.99], options: nil)
    client.track("purchase", properties: nil, options: nil)

    let request = try await request(0)
    #expect(request.url?.path == "/sdk.events.v1.EventsService/BatchCreate")
    let events = try Sdk_Events_V1_BatchCreateRequest(serializedBytes: request.body).events
    try #require(events.count == 3)
    #expect(events.map(\.kind) == ["checkout_started", "add_to_cart", "purchase"])
    #expect(Set(events.map(\.sessionID)).count == 1)
    #expect(Set(events.map(\.distinctID)).count == 1)
    #expect(events[0].distinctID.hasPrefix("anon-"))
    #expect(
      events[0].customProperties == ["cartId": .with { $0.stringValue = "c1" }, "items": .with { $0.intValue = 2 }])
    #expect(events[1].customProperties == ["price": .with { $0.doubleValue = 9.99 }])
    #expect(events[2].autoProperties["$projectId"] == .with { $0.stringValue = Self.project })
    await destroy(client)
  }

  @Test("identify reaches the server with the anonymous id")
  func identify() async throws {
    server.enqueueProtobuf([])
    try acknowledge(1)
    let storage = Pug.MemoryStorage()
    let client = try makeClient(storage: storage) { $0.batchMaxSize = 1 }

    client.identify("user-42", traits: ["plan": "pro"])
    let identify = try await request(0)
    try await linked(storage)
    client.track("after", properties: nil, options: nil)
    let batch = try await request(1)

    #expect(identify.url?.path == "/sdk.profiles.v1.ProfilesSDKService/Identify")
    let message = try Sdk_Profiles_V1_IdentifyRequest(serializedBytes: identify.body)
    #expect(message.externalID == "user-42")
    #expect(message.anonymousID.hasPrefix("anon-"))
    #expect(try Sdk_Events_V1_BatchCreateRequest(serializedBytes: batch.body).events.map(\.distinctID) == ["user-42"])
    await destroy(client)
  }

  @Test("a batch the server could not take is sent again")
  func retry() async throws {
    server.enqueue(.response(status: 503, headers: [:], body: []))
    try acknowledge(1)
    let client = try makeClient {
      $0.batchMaxSize = 1
      $0.batchMaxWait = 0
    }

    client.track("app_open", properties: nil, options: nil)
    let failed = try await request(0)
    let retried = try await request(1)

    #expect(failed.body == retried.body)
    await destroy(client)
  }

  private func makeClient(
    storage: Pug.MemoryStorage = Pug.MemoryStorage(),
    _ configure: (inout Pug.Options) -> Void
  ) throws -> Client {
    var options = Pug.Options(apiKey: "pub_test")
    options.endpoint = server.endpoint
    options.storage = storage
    options.logger = logger
    configure(&options)
    let configuration = try Configuration(projectId: Self.project, options: options)
    let scheduler = DispatchScheduler()
    let transport = HTTPTransport(
      endpoint: configuration.endpoint,
      apiKey: configuration.apiKey,
      logger: configuration.logger,
      configuration: StubServer.configuration()
    )
    let client = Client(
      configuration: configuration,
      transport: transport,
      scheduler: scheduler,
      clock: scheduler,
      platform: FakePlatform(),
      random: { 0.5 }
    )
    client.start(after: nil)
    return client
  }

  private func acknowledge(_ accepted: UInt32) throws {
    let response = ReferenceMessages.batchResponse(accepted: accepted, dropped: 0, droppedByReason: [:])
    server.enqueueProtobuf(try response.serializedBytes())
  }

  /// The `index`th request the server saw, waiting up to ten seconds for it.
  private func request(_ index: Int) async throws -> StubServer.Request {
    try await poll { server.requests.dropFirst(index).first }
  }

  // The link lands on the worker after the answer, so it can trail the server seeing the request.
  private func linked(_ storage: Pug.MemoryStorage) async throws {
    _ = try await poll { storage.string(forKey: StorageKeys(projectId: Self.project).externalId) }
  }

  private func poll<Value>(_ value: () -> Value?) async throws -> Value {
    for _ in 0..<1_000 {
      if let value = value() {
        return value
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    return try #require(value(), "nothing within ten seconds")
  }

  private func destroy(_ client: Client) async {
    client.destroy()
    await withCheckedContinuation { continuation in
      client.teardown.whenFinished { continuation.resume() }
    }
  }
}
