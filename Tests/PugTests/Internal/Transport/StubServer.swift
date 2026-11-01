import Foundation
import Testing

@testable import Pug

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A scripted server behind `StubProtocol`: requests to `endpoint` are recorded and answered with the replies queued by
/// `enqueue`, in order. Each server has a host of its own, so tests run in parallel.
final class StubServer: Sendable {
  enum Reply: Sendable {
    case response(status: Int, headers: [String: String], body: [UInt8])
    /// Headers and the start of the body, then nothing more.
    case stall(status: Int, headers: [String: String], body: [UInt8])
    /// Nothing at all, until the request is cancelled.
    case silence
    case failure(URLError)
  }

  struct Request: Sendable {
    let method: String?
    let url: URL?
    let headers: [String: String]
    let body: [UInt8]
  }

  private struct State: Sendable {
    var replies: [Reply] = []
    var requests: [Request] = []
  }

  fileprivate static let servers = Locked<[String: StubServer]>([:])

  let endpoint: URL
  private let host: String
  private let state = Locked(State())

  init() throws {
    host = UUID().uuidString.lowercased() + ".stub"
    endpoint = try #require(URL(string: "http://\(host)"))
    Self.servers.withLock { $0[host] = self }
  }

  var requests: [Request] {
    state.withLock { $0.requests }
  }

  /// A session configuration that sends every request to a stub server.
  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return configuration
  }

  func enqueue(_ reply: Reply) {
    state.withLock { $0.replies.append(reply) }
  }

  /// A Connect error, as the Pug API sends it.
  func enqueueConnectError(status: Int, code: String, message: String) {
    enqueue(
      .response(
        status: status,
        headers: ["Content-Type": "application/json"],
        body: Array(#"{"code":"\#(code)","message":"\#(message)"}"#.utf8)
      )
    )
  }

  func enqueueProtobuf(_ body: [UInt8]) {
    enqueue(.response(status: 200, headers: ["Content-Type": "application/proto"], body: body))
  }

  func close() {
    _ = Self.servers.withLock { $0.removeValue(forKey: host) }
  }

  fileprivate func reply(to request: Request) -> Reply {
    state.withLock { state in
      state.requests.append(request)
      return state.replies.isEmpty ? Reply.failure(URLError(.resourceUnavailable)) : state.replies.removeFirst()
    }
  }
}

/// Answers each request from the `StubServer` that owns its host, or as an unknown host.
final class StubProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let client else { return }
    let host = request.url?.host ?? ""
    guard let server = StubServer.servers.withLock({ $0[host] }) else {
      client.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    let recorded = StubServer.Request(
      method: request.httpMethod,
      url: request.url,
      headers: request.allHTTPHeaderFields ?? [:],
      body: Self.body(of: request)
    )
    switch server.reply(to: recorded) {
    case .response(let status, let headers, let body):
      respond(status: status, headers: headers, body: body, client: client)
      client.urlProtocolDidFinishLoading(self)
    case .stall(let status, let headers, let body):
      respond(status: status, headers: headers, body: body, client: client)
    case .silence:
      break
    case .failure(let error):
      client.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}

  private func respond(status: Int, headers: [String: String], body: [UInt8], client: any URLProtocolClient) {
    guard let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
    else { return }
    client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !body.isEmpty {
      client.urlProtocol(self, didLoad: Data(body))
    }
  }

  // Darwin hands a URLProtocol the body as a stream.
  private static func body(of request: URLRequest) -> [UInt8] {
    if let body = request.httpBody {
      return Array(body)
    }
    guard let stream = request.httpBodyStream else { return [] }
    stream.open()
    defer { stream.close() }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      bytes += buffer[..<count]
    }
    return bytes
  }
}
