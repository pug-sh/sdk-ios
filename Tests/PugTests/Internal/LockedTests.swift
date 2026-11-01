import Dispatch
import Testing

@testable import Pug

struct LockedTests {
  @Test("concurrent updates are not lost")
  func concurrentUpdates() {
    let counter = Locked(0)

    DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
      counter.withLock { $0 += 1 }
    }

    #expect(counter.withLock { $0 } == 1_000)
  }

  @Test("withLock returns what its body returns, and rethrows what it throws")
  func returnsAndRethrows() {
    struct Failure: Error {}
    let value = Locked([1, 2])

    let count = value.withLock { values in
      values.append(3)
      return values.count
    }

    #expect(count == 3)
    #expect(throws: Failure.self) {
      try value.withLock { _ in throw Failure() }
    }
    #expect(value.withLock { $0 } == [1, 2, 3])
  }
}
