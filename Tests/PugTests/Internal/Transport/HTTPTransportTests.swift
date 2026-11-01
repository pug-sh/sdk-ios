import Foundation
import SwiftProtobuf
import Testing

@testable import Pug

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HTTPTransportTests {
  private let server: StubServer
  private let logger = RecordingLogger()

  init() throws {
    server = try StubServer()
  }

  deinit {
    server.close()
  }

  @Test("sendBatch posts a Connect unary request and returns the acknowledgement")
  func sendBatch() async throws {
    let reply = ReferenceMessages.batchResponse(accepted: 1, dropped: 1, droppedByReason: ["salt_unavailable": 1])
    server.enqueueProtobuf(try reply.serializedBytes())
    let events = [event("first"), event("second")]

    let response = try await send(events).get()

    #expect(response == BatchCreateResponse(accepted: 1, droppedByReason: ["salt_unavailable": 1]))
    let request = try #require(server.requests.first)
    #expect(request.method == "POST")
    #expect(request.url?.path == "/sdk.events.v1.EventsService/BatchCreate")
    #expect(request.headers["Content-Type"] == "application/proto")
    #expect(request.headers["Connect-Protocol-Version"] == "1")
    #expect(request.headers["X-Api-Key"] == "pub_test")
    #expect(request.headers["User-Agent"] == "pug-ios/\(sdkVersion)")
    #expect(request.body == Wire.encodeBatchCreateRequest(events))
  }

  @Test("identify posts to the profiles service")
  func identify() async throws {
    server.enqueueProtobuf([])
    let request = IdentifyRequest(externalId: "user-42", traits: ["plan": .string("pro")], anonymousId: "anon-1")

    let result = await withCheckedContinuation { continuation in
      transport().identify(request) { continuation.resume(returning: $0) }
    }

    try result.get()
    let recorded = try #require(server.requests.first)
    #expect(recorded.url?.path == "/sdk.profiles.v1.ProfilesSDKService/Identify")
    #expect(recorded.body == Wire.encodeIdentifyRequest(request))
  }

  @Test("the endpoint's path prefix is kept and its trailing slashes are dropped")
  func endpointPath() async throws {
    server.enqueueProtobuf([])
    let endpoint = try #require(URL(string: "/ingest//", relativeTo: server.endpoint)?.absoluteURL)

    _ = await send(transport: transport(endpoint: endpoint))

    #expect(server.requests.first?.url?.path == "/ingest/sdk.events.v1.EventsService/BatchCreate")
  }

  @Test("Connect error bodies map to their code")
  func connectErrors() async throws {
    for code in RPCCode.allCases {
      server.enqueueConnectError(status: 400, code: code.rawValue, message: "rejected: \(code.rawValue)")

      let error = try await failure()

      #expect(error.code == code)
      #expect(error.message == "rejected: \(code.rawValue)")
      #expect(error.isPermanent == code.isPermanent, "permanence of \(code.rawValue)")
    }
  }

  @Test("permanent codes are the ones a retry cannot fix")
  func permanentCodes() {
    #expect(
      Set(RPCCode.allCases.filter(\.isPermanent)) == [
        .invalidArgument, .notFound, .alreadyExists, .permissionDenied, .failedPrecondition, .unimplemented,
        .unauthenticated,
      ]
    )
  }

  @Test("an error body that is not Connect JSON falls back to the HTTP status")
  func statusFallback() async throws {
    let expectations: [(Int, RPCCode)] = [
      (307, .unavailable), (400, .invalidArgument), (401, .unauthenticated), (403, .permissionDenied),
      (404, .unimplemented), (408, .unavailable), (413, .invalidArgument), (429, .unavailable), (500, .unavailable),
      (502, .unavailable), (503, .unavailable), (504, .unavailable),
    ]
    for (status, code) in expectations {
      server.enqueue(
        .response(status: status, headers: ["Content-Type": "text/html"], body: Array("<html>proxy page</html>".utf8))
      )

      let error = try await failure()

      #expect(error.code == code, "HTTP \(status)")
      #expect(error.message == "HTTP \(status)")
    }
  }

  @Test("an unknown Connect code falls back to the HTTP status but keeps the message")
  func unknownConnectCode() async throws {
    server.enqueueConnectError(status: 503, code: "brand_new_code", message: "try later")
    server.enqueueConnectError(status: 422, code: "brand_new_code", message: "")

    let transient = try await failure()
    let permanent = try await failure()

    #expect(transient.code == .unavailable)
    #expect(transient.message == "try later")
    #expect(permanent.code == .invalidArgument)
    #expect(permanent.message == "HTTP 422")
  }

  @Test("an error without a body maps from the HTTP status")
  func bodylessError() async throws {
    server.enqueue(.response(status: 401, headers: [:], body: []))

    let error = try await failure()

    #expect(error.code == .unauthenticated)
    #expect(error.isPermanent)
  }

  @Test("a 2xx that is not protobuf is retried rather than dropped")
  func captivePortal() async throws {
    server.enqueue(
      .response(
        status: 200,
        headers: ["Content-Type": "text/html; charset=utf-8"],
        body: Array("<html>Sign in to the hotel wifi</html>".utf8)
      )
    )

    let error = try await failure()

    #expect(error.code == .unavailable)
    #expect(error.message == "expected a protobuf response but got content-type \"text/html; charset=utf-8\"")
    #expect(!error.isPermanent)
  }

  @Test("a 2xx without a content type is accepted")
  func noContentType() async throws {
    server.enqueue(.response(status: 200, headers: [:], body: []))

    #expect(try await send().get() == BatchCreateResponse(accepted: 0, droppedByReason: [:]))
  }

  @Test("a 2xx body that cannot be decoded is still a success")
  func undecodableBody() async throws {
    server.enqueueProtobuf([0x0A, 0x7F])

    #expect(try await send().get() == nil)
  }

  @Test("a response is read up to 64 KiB")
  func responseCap() async throws {
    server.enqueueProtobuf(acknowledgement(padding: HTTPTransport.maxResponseBytes - 100))
    server.enqueueProtobuf(acknowledgement(padding: HTTPTransport.maxResponseBytes))
    let message = String(repeating: "x", count: HTTPTransport.maxResponseBytes)
    server.enqueueConnectError(status: 503, code: "resource_exhausted", message: message)

    let whole = try await send().get()
    let cut = try await send().get()
    let error = try await failure()

    #expect(whole == BatchCreateResponse(accepted: 3, droppedByReason: [:]))
    #expect(cut == nil)
    #expect(error.code == .unavailable)
    #expect(error.message == "HTTP 503")
  }

  @Test("a server that never answers times out as a transient deadline, at the deadline")
  func silentServer() async throws {
    server.enqueue(.silence)
    let started = DispatchTime.now()

    let error = try await failure(transport(timeoutMillis: 300))

    #expect(error.code == .deadlineExceeded)
    #expect(error.message == "request timed out after 300 ms")
    #expect(!error.isPermanent)
    #expect(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds < 3_000_000_000)
  }

  @Test("a response that stalls times out")
  func stalledResponse() async throws {
    server.enqueue(.stall(status: 200, headers: ["Content-Type": "application/proto"], body: [0x08]))

    let error = try await failure(transport(timeoutMillis: 300))

    #expect(error.code == .deadlineExceeded)
  }

  @Test("network failures are transient, and keep the system error")
  func networkFailures() async throws {
    let expectations: [(URLError.Code, RPCCode)] = [
      (.notConnectedToInternet, .unavailable), (.cannotConnectToHost, .unavailable),
      (.networkConnectionLost, .unavailable), (.timedOut, .deadlineExceeded),
    ]
    for (urlError, code) in expectations {
      server.enqueue(.failure(URLError(urlError)))

      let error = try await failure()

      #expect(error.code == code, "URLError \(urlError.rawValue)")
      #expect(!error.isPermanent)
      #expect(error.underlying.map { $0 as NSError }?.code == urlError.rawValue)
    }
    #expect(logger.entries.isEmpty)
  }

  @Test("an http endpoint blocked by App Transport Security logs the fix once")
  func appTransportSecurity() async throws {
    server.enqueue(.failure(URLError(.appTransportSecurityRequiresSecureConnection)))
    server.enqueue(.failure(URLError(.appTransportSecurityRequiresSecureConnection)))
    let transport = transport()

    let first = try await failure(transport)
    let second = try await failure(transport)

    #expect(first.code == .unavailable)
    #expect(second.message == "blocked by App Transport Security")
    #expect(logger.errors.count == 1)
    #expect(logger.errors.first?.contains("NSAllowsLocalNetworking") == true)
  }

  @Test("an endpoint that is not an http URL fails permanently, without a request")
  func nonHTTPEndpoint() async throws {
    for endpoint in ["pug://ingest", "file:///tmp/pug"] {
      let url = try #require(URL(string: endpoint))

      let error = try await failure(transport(endpoint: url))

      #expect(error.code == .invalidArgument, "\(endpoint)")
      #expect(error.isPermanent, "\(endpoint)")
    }
    #expect(server.requests.isEmpty)
  }

  @Test("redirects are refused, so the API key never travels to another host")
  func redirectsRefused() async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: server.endpoint)
    let response = try #require(
      HTTPURLResponse(url: server.endpoint, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: nil)
    )
    let elsewhere = URLRequest(url: try #require(URL(string: "https://elsewhere.example/steal")))
    let delegate: any URLSessionTaskDelegate = HTTPTransport.SessionDelegate(logger: logger.safe())

    // Called through the protocol, so this is the method URLSession calls.
    let next = await withCheckedContinuation { continuation in
      #if canImport(Darwin)
      delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response, newRequest: elsewhere) {
        continuation.resume(returning: $0)
      }
      #else
      delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: elsewhere) {
        continuation.resume(returning: $0)
      }
      #endif
    }

    #expect(next == nil)
  }

  private func transport(endpoint: URL? = nil, timeoutMillis: Int = 5_000) -> HTTPTransport {
    HTTPTransport(
      endpoint: endpoint ?? server.endpoint,
      apiKey: "pub_test",
      logger: logger.safe(),
      batchTimeoutMillis: timeoutMillis,
      identifyTimeoutMillis: timeoutMillis,
      configuration: StubServer.configuration()
    )
  }

  private func send(_ events: [Event]? = nil, transport: HTTPTransport? = nil) async -> BatchResult {
    let transport = transport ?? self.transport()
    let events = events ?? [event("first")]
    return await withCheckedContinuation { continuation in
      transport.sendBatch(events) { continuation.resume(returning: $0) }
    }
  }

  private func failure(_ transport: HTTPTransport? = nil) async throws -> TransportError {
    guard case .failure(let error) = await send(transport: transport) else {
      throw ExpectedFailure()
    }
    return error
  }

  // BatchCreateResponse{accepted: 3}, then an unknown field of `padding` bytes, which a decoder skips when it is whole.
  private func acknowledgement(padding: Int) -> [UInt8] {
    var message = ProtoWriter()
    message.writeInt32(field: 1, 3)
    message.writeString(field: 15, String(repeating: "x", count: padding))
    return message.bytes
  }

  private func event(_ id: String) -> Event {
    Event(
      eventId: String("0192f3a4-1b2c-7d3e-8f40-\(id)".prefix(36)),
      kind: "app_open",
      distinctId: "anon-1",
      sessionId: "0192f3a4-0000-7000-8000-000000000002",
      occurTimeMillis: 1_760_000_000_000,
      autoProperties: ["$platform": .string("ios")],
      customProperties: [:]
    )
  }

  private struct ExpectedFailure: Error {}
}
