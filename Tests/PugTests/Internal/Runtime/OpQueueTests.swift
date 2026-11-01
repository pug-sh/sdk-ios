import Dispatch
import Testing

@testable import Pug

struct OpQueueTests {
  private let scheduler = TestScheduler()
  private let ran = Locked<[String]>([])

  @Test("ops wait for their context, then run in the order queued")
  func waitForStart() {
    let ops = OpQueue<String>(scheduler: scheduler)

    #expect(ops.submit(record("a")))
    #expect(ops.submit(record("b")))
    scheduler.advanceUntilIdle()
    #expect(ran.withLock { $0 }.isEmpty)
    ops.start(with: "c1")

    #expect(ran.withLock { $0 } == ["c1: a", "c1: b"])
  }

  @Test("ops queued after start run on the worker, after the ones before")
  func afterStart() {
    let ops = OpQueue<String>(scheduler: scheduler)

    _ = ops.submit(record("a"))
    ops.start(with: "c1")
    _ = ops.submit(record("b"))
    #expect(ran.withLock { $0 } == ["c1: a"])
    scheduler.runCurrent()

    #expect(ran.withLock { $0 } == ["c1: a", "c1: b"])
  }

  @Test("closing queues the last op and refuses later ones")
  func close() {
    let ops = OpQueue<String>(scheduler: scheduler)

    _ = ops.submit(record("a"))
    #expect(ops.close(with: record("last")))
    #expect(!ops.submit(record("b")))
    #expect(!ops.close(with: record("again")))
    ops.start(with: "c1")
    scheduler.runCurrent()

    #expect(ran.withLock { $0 } == ["c1: a", "c1: last"])
  }

  @Test("ops from many threads all run, each thread's in its order")
  func concurrentSubmitters() async {
    let scheduler = DispatchScheduler()
    let ops = OpQueue<Int>(scheduler: scheduler)
    let ran = Locked<[[Int]]>(Array(repeating: [], count: 4))
    scheduler.run { ops.start(with: 0) }

    DispatchQueue.concurrentPerform(iterations: 4) { thread in
      for index in 0..<250 {
        _ = ops.submit { _ in ran.withLock { $0[thread].append(index) } }
      }
    }
    await withCheckedContinuation { continuation in
      ops.close { _ in continuation.resume() }
    }

    #expect(ran.withLock { $0 } == Array(repeating: Array(0..<250), count: 4))
  }

  private func record(_ name: String) -> OpQueue<String>.Op {
    { [ran] context in ran.withLock { $0.append("\(context): \(name)") } }
  }
}
