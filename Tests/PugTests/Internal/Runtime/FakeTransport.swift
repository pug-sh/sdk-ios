import Testing

@testable import Pug

/// Records every call and answers from a script, accepting everything by default. After `hold()`, calls wait until
/// released, which opens the window between a request and its answer; the answer is decided on release.
final class FakeTransport: Transport {
  private struct State: Sendable {
    var batches: [[Event]] = []
    var batchTimes: [Int64] = []
    var identifies: [IdentifyRequest] = []
    var batchFailure: RPCCode?
    var batchAnswers: [BatchResult] = []
    var identifyAnswers: [Result<Void, TransportError>] = []
    var holding = false
    var held: [PendingWork] = []
    var cancels = 0
  }

  private let state = Locked(State())
  private let now: @Sendable () -> Int64

  init(now: @escaping @Sendable () -> Int64 = { 0 }) {
    self.now = now
  }

  var batches: [[Event]] {
    state.withLock { $0.batches }
  }

  /// When each batch was sent, by `now`.
  var batchTimes: [Int64] {
    state.withLock { $0.batchTimes }
  }

  var identifies: [IdentifyRequest] {
    state.withLock { $0.identifies }
  }

  var kinds: [[String]] {
    batches.map { $0.map(\.kind) }
  }

  /// How many times the calls in flight were cancelled.
  var cancels: Int {
    state.withLock { $0.cancels }
  }

  /// While set, every batch fails with this code.
  var batchFailure: RPCCode? {
    get { state.withLock { $0.batchFailure } }
    set { state.withLock { $0.batchFailure = newValue } }
  }

  func failNextBatch(_ code: RPCCode) {
    failNextBatch(with: Self.failure(code))
  }

  func failNextBatch(with failure: TransportError) {
    state.withLock { $0.batchAnswers.append(.failure(failure)) }
  }

  func answerNextBatch(_ response: BatchCreateResponse?) {
    state.withLock { $0.batchAnswers.append(.success(response)) }
  }

  func failNextIdentify(_ code: RPCCode) {
    state.withLock { $0.identifyAnswers.append(.failure(Self.failure(code))) }
  }

  func hold() {
    state.withLock { $0.holding = true }
  }

  /// Lets the `index`th held call, in call order, finish.
  func release(_ index: Int, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let call = state.withLock({ $0.held.indices.contains(index) ? $0.held[index] : nil }) else {
      Issue.record("no call \(index) is held", sourceLocation: sourceLocation)
      return
    }
    call.run()
  }

  func releaseAll() {
    let held = state.withLock { state in
      state.holding = false
      return state.held
    }
    for call in held {
      call.run()
    }
  }

  func sendBatch(_ events: [Event], completion: @escaping @Sendable (BatchResult) -> Void) {
    let time = now()
    state.withLock { state in
      state.batches.append(events)
      state.batchTimes.append(time)
    }
    answer { [self] in completion(nextBatchAnswer(for: events)) }
  }

  func identify(_ request: IdentifyRequest, completion: @escaping @Sendable (Result<Void, TransportError>) -> Void) {
    state.withLock { $0.identifies.append(request) }
    answer { [self] in
      completion(state.withLock { $0.identifyAnswers.isEmpty ? .success(()) : $0.identifyAnswers.removeFirst() })
    }
  }

  func cancelAll() {
    state.withLock { $0.cancels += 1 }
  }

  // At once, or on release while holding.
  private func answer(_ reply: @escaping @Sendable () -> Void) {
    let call = PendingWork(reply)
    let holding = state.withLock { state in
      if state.holding {
        state.held.append(call)
      }
      return state.holding
    }
    if !holding {
      call.run()
    }
  }

  private func nextBatchAnswer(for events: [Event]) -> BatchResult {
    state.withLock { state in
      if let code = state.batchFailure {
        return .failure(Self.failure(code))
      }
      guard !state.batchAnswers.isEmpty else {
        return .success(BatchCreateResponse(accepted: Int64(events.count), droppedByReason: [:]))
      }
      return state.batchAnswers.removeFirst()
    }
  }

  private static func failure(_ code: RPCCode) -> TransportError {
    TransportError(code, "scripted")
  }
}
