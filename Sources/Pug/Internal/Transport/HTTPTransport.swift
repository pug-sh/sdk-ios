import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Connect unary calls in the binary codec, over an ephemeral `URLSession` that keeps no cookies, cache or credentials.
/// Redirects are refused, so the API key never travels to another host.
final class HTTPTransport: Transport {
  // Acknowledgements and Connect errors are small: the rest of a larger body is never read.
  static let maxResponseBytes = 64 * 1_024

  private static let userAgent = "pug-ios/\(sdkVersion)"

  private let batchURL: URL?
  private let identifyURL: URL?
  private let apiKey: String
  private let batchTimeoutMillis: Int
  private let identifyTimeoutMillis: Int
  private let delegate: SessionDelegate
  private let session: URLSession

  /// Takes `configuration` over, with cookies, cache and credential storage turned off.
  init(
    endpoint: URL,
    apiKey: String,
    logger: SafeLogger,
    batchTimeoutMillis: Int = 10_000,
    identifyTimeoutMillis: Int = 15_000,
    configuration: URLSessionConfiguration = .ephemeral
  ) {
    var base = endpoint.absoluteString
    while base.hasSuffix("/") {
      base.removeLast()
    }
    let scheme = endpoint.scheme?.lowercased()
    let isHTTP = scheme == "http" || scheme == "https"
    batchURL = isHTTP ? URL(string: base + "/sdk.events.v1.EventsService/BatchCreate") : nil
    identifyURL = isHTTP ? URL(string: base + "/sdk.profiles.v1.ProfilesSDKService/Identify") : nil
    self.apiKey = apiKey
    self.batchTimeoutMillis = batchTimeoutMillis
    self.identifyTimeoutMillis = identifyTimeoutMillis
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    delegate = SessionDelegate(logger: logger)
    session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  // A session keeps its delegate until it is invalidated. Calls in flight still complete.
  deinit {
    session.finishTasksAndInvalidate()
  }

  func sendBatch(_ events: [Event], completion: @escaping @Sendable (BatchResult) -> Void) {
    post(Wire.encodeBatchCreateRequest(events), to: batchURL, timeoutMillis: batchTimeoutMillis) { result in
      completion(result.map { try? Wire.decodeBatchCreateResponse($0) })
    }
  }

  func identify(_ request: IdentifyRequest, completion: @escaping @Sendable (Result<Void, TransportError>) -> Void) {
    post(Wire.encodeIdentifyRequest(request), to: identifyURL, timeoutMillis: identifyTimeoutMillis) { result in
      completion(result.map { _ in })
    }
  }

  func cancelAll() {
    delegate.cancelAll()
  }

  private func post(
    _ body: [UInt8],
    to url: URL?,
    timeoutMillis: Int,
    completion: @escaping @Sendable (Result<[UInt8], TransportError>) -> Void
  ) {
    guard let url else {
      completion(.failure(TransportError(.invalidArgument, "endpoint is not an http(s) URL")))
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data(body)
    request.setValue("application/proto", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    delegate.start(session.dataTask(with: request), timeoutMillis: timeoutMillis) { result in
      completion(result.flatMap(Self.payload))
    }
  }

  private static func payload(of response: Response) -> Result<[UInt8], TransportError> {
    guard (200..<300).contains(response.status) else {
      return .failure(error(from: response))
    }
    // A 2xx that is not protobuf comes from something between the app and the server, such as a captive portal, which
    // goes away when the network changes: retried rather than dropped.
    if !response.contentType.isEmpty, response.contentType.range(of: "proto", options: .caseInsensitive) == nil {
      return .failure(
        TransportError(.unavailable, "expected a protobuf response but got content-type \"\(response.contentType)\"")
      )
    }
    return .success(response.body)
  }

  // Connect errors are JSON, {"code": "invalid_argument", "message": "..."}. Any other body, such as a proxy's page,
  // leaves the HTTP status to decide.
  private static func error(from response: Response) -> TransportError {
    let json = (try? JSONSerialization.jsonObject(with: Data(response.body))) as? [String: Any]
    let code = (json?["code"] as? String).flatMap(RPCCode.init(rawValue:))
    let message = json?["message"] as? String ?? ""
    return TransportError(
      code ?? RPCCode(httpStatus: response.status),
      message.isEmpty ? "HTTP \(response.status)" : message
    )
  }

  fileprivate struct Response: Sendable {
    let status: Int
    let contentType: String
    let body: [UInt8]
  }

  /// The session's delegate: it reads each response up to the cap, enforces each deadline and refuses redirects.
  final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Exchange: Sendable {
      let task: URLSessionTask
      let timeoutMillis: Int
      let deadline: PendingWork
      let completion: @Sendable (Result<Response, TransportError>) -> Void
      var body = Data()
      var isCut = false
      var isExpired = false
    }

    private let logger: SafeLogger
    private let exchanges = Locked<[Int: Exchange]>([:])
    private let reportedATS = Locked(false)

    init(logger: SafeLogger) {
      self.logger = logger
    }

    // URLSession's own timeout measures idleness, which a response that keeps trickling in never reaches.
    fileprivate func start(
      _ task: URLSessionDataTask,
      timeoutMillis: Int,
      completion: @escaping @Sendable (Result<Response, TransportError>) -> Void
    ) {
      let id = task.taskIdentifier
      let deadline = PendingWork { [weak self] in self?.expire(id) }
      exchanges.withLock {
        $0[id] = Exchange(task: task, timeoutMillis: timeoutMillis, deadline: deadline, completion: completion)
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(timeoutMillis)) {
        deadline.run()
      }
      task.resume()
    }

    // Task by task rather than by invalidating the session, which could not start another.
    fileprivate func cancelAll() {
      let tasks = exchanges.withLock { $0.values.map(\.task) }
      for task in tasks {
        task.cancel()
      }
    }

    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      let id = dataTask.taskIdentifier
      let isFull = exchanges.withLock { exchanges in
        guard let exchange = exchanges[id], !exchange.isCut else { return false }
        let room = HTTPTransport.maxResponseBytes - exchange.body.count
        let isFull = data.count > room
        exchanges[id]?.body.append(data.prefix(room))
        exchanges[id]?.isCut = isFull
        return isFull
      }
      if isFull {
        dataTask.cancel()
      }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
      guard let exchange = exchanges.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
      exchange.deadline.cancel()
      exchange.completion(outcome(of: exchange, response: task.response, error: error))
    }

    private func expire(_ id: Int) {
      let task = exchanges.withLock { exchanges in
        exchanges[id]?.isExpired = true
        return exchanges[id]?.task
      }
      task?.cancel()
    }

    // Reaching the cap cancels the task, which leaves what was read as the response.
    private func outcome(
      of exchange: Exchange,
      response: URLResponse?,
      error: (any Error)?
    ) -> Result<Response, TransportError> {
      if let error, !exchange.isCut {
        guard !exchange.isExpired else {
          return .failure(TransportError(.deadlineExceeded, "request timed out after \(exchange.timeoutMillis) ms"))
        }
        return .failure(failure(error))
      }
      guard let response = response as? HTTPURLResponse else {
        return .failure(TransportError(.unavailable, "the response was not HTTP"))
      }
      return .success(
        Response(
          status: response.statusCode,
          contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "",
          body: [UInt8](exchange.body)
        )
      )
    }

    // Read through NSError, since Linux does not bridge an NSError to URLError.
    private func failure(_ error: any Error) -> TransportError {
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain {
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut:
          return TransportError(.deadlineExceeded, "request timed out", underlying: error)
        case .appTransportSecurityRequiresSecureConnection:
          reportATSBlock()
          return TransportError(.unavailable, "blocked by App Transport Security", underlying: error)
        default:
          break
        }
      }
      return TransportError(
        .unavailable,
        "network request failed (\(nsError.domain) \(nsError.code))",
        underlying: error
      )
    }

    private func reportATSBlock() {
      let isFirst = reportedATS.withLock { reported in
        defer { reported = true }
        return !reported
      }
      guard isFirst else { return }
      logger.error(
        "App Transport Security blocked a request to the http endpoint: use https, or allow the host under "
          + "NSAppTransportSecurity in the app's Info.plist (NSAllowsLocalNetworking for a local server)"
      )
    }
  }
}
