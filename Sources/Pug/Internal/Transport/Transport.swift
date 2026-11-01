/// How events and identify calls reach the Pug API. Each call completes once, on any thread.
protocol Transport: Sendable {
  func sendBatch(_ events: [Event], completion: @escaping @Sendable (BatchResult) -> Void)

  func identify(_ request: IdentifyRequest, completion: @escaping @Sendable (Result<Void, TransportError>) -> Void)
}

/// A batch's outcome: the server's acknowledgement, nil for a 2xx body that could not be read, or the failure.
typealias BatchResult = Result<BatchCreateResponse?, TransportError>

/// A failed call and its Connect code. A permanent failure is dropped, since a retry would fail the same way.
struct TransportError: Error, CustomStringConvertible {
  let code: RPCCode
  let message: String
  /// The system error behind a network failure.
  let underlying: (any Error)?

  init(_ code: RPCCode, _ message: String, underlying: (any Error)? = nil) {
    self.code = code
    self.message = message
    self.underlying = underlying
  }

  var isPermanent: Bool {
    code.isPermanent
  }

  var description: String {
    "\(code.rawValue): \(message)"
  }
}
