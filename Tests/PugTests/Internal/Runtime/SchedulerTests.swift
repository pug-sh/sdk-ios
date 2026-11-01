import Dispatch
import Testing

@testable import Pug

struct DispatchSchedulerTests {
    @Test("work runs on the worker, in the order it was scheduled")
    func runsInOrderOnTheWorker() async {
        let scheduler = DispatchScheduler(label: "sh.pug.test.order")
        let runs = Locked<[Int]>([])
        let onWorker = Locked<[Bool]>([])

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            for index in 0..<100 {
                scheduler.run {
                    runs.withLock { $0.append(index) }
                    onWorker.withLock { $0.append(scheduler.isOnWorker) }
                }
            }
            scheduler.run { continuation.resume() }
        }

        #expect(runs.withLock { $0 } == Array(0..<100))
        #expect(onWorker.withLock { $0 }.allSatisfy { $0 })
        #expect(!scheduler.isOnWorker)
    }

    @Test("isOnWorker is true on this scheduler's worker only")
    func isOnWorkerPerScheduler() async {
        let scheduler = DispatchScheduler(label: "sh.pug.test.mine")
        let other = DispatchScheduler(label: "sh.pug.test.other")

        let seen = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Bool), Never>) in
            other.run { continuation.resume(returning: (other.isOnWorker, scheduler.isOnWorker)) }
        }

        #expect(seen == (true, false))
    }

    @Test("delayed work runs once its delay has passed")
    func delayedWork() async {
        let scheduler = DispatchScheduler(label: "sh.pug.test.delay")
        let start = DispatchTime.now().uptimeNanoseconds

        let elapsed = await withCheckedContinuation { (continuation: CheckedContinuation<UInt64, Never>) in
            _ = scheduler.runAfter(milliseconds: 50) {
                continuation.resume(returning: DispatchTime.now().uptimeNanoseconds - start)
            }
        }

        #expect(elapsed >= 50_000_000)
    }

    @Test("cancelled work never runs")
    func cancelledWork() async {
        let scheduler = DispatchScheduler(label: "sh.pug.test.cancel")
        let ran = Locked(false)

        // Scheduled and cancelled on the worker, so the timer cannot fire in between.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scheduler.run {
                scheduler.runAfter(milliseconds: 0) { ran.withLock { $0 = true } }.cancel()
                _ = scheduler.runAfter(milliseconds: 20) { continuation.resume() }
            }
        }

        #expect(!ran.withLock { $0 })
    }

    @Test("a negative delay runs the work as soon as possible")
    func negativeDelay() async {
        let scheduler = DispatchScheduler(label: "sh.pug.test.negative")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            _ = scheduler.runAfter(milliseconds: -1_000) { continuation.resume() }
        }
    }

    @Test("cancelling releases the work at once, not when it falls due")
    func cancellingReleasesTheWork() {
        final class Payload: Sendable {}
        let scheduler = DispatchScheduler(label: "sh.pug.test.release")
        weak var released: Payload?
        let timer: any Cancellable
        do {
            let payload = Payload()
            released = payload
            timer = scheduler.runAfter(milliseconds: 600_000) { _ = payload }
        }
        #expect(released != nil)

        timer.cancel()

        #expect(released == nil)
    }
}

struct TestSchedulerTests {
    @Test("work waits for the test, then runs by due time and, at one time, in scheduling order")
    func ordering() {
        let scheduler = TestScheduler()
        let runs = Locked<[String]>([])

        _ = scheduler.runAfter(milliseconds: 10) { runs.withLock { $0.append("late") } }
        scheduler.run { runs.withLock { $0.append("first") } }
        _ = scheduler.runAfter(milliseconds: 0) { runs.withLock { $0.append("second") } }
        _ = scheduler.runAfter(milliseconds: 5) { runs.withLock { $0.append("early") } }
        #expect(runs.withLock { $0 }.isEmpty)

        scheduler.advanceUntilIdle()

        #expect(runs.withLock { $0 } == ["first", "second", "early", "late"])
        #expect(scheduler.currentTime == 10)
    }

    @Test("advanceTime(by:) runs what falls due before the new time; runCurrent() runs what falls due at it")
    func advanceTimeIsExclusive() {
        let scheduler = TestScheduler()
        let times = Locked<[Int64]>([])

        _ = scheduler.runAfter(milliseconds: 999) { times.withLock { $0.append(scheduler.currentTime) } }
        _ = scheduler.runAfter(milliseconds: 1_000) { times.withLock { $0.append(scheduler.currentTime) } }
        scheduler.advanceTime(by: 1_000)

        #expect(times.withLock { $0 } == [999])
        #expect(scheduler.currentTime == 1_000)

        scheduler.runCurrent()

        #expect(times.withLock { $0 } == [999, 1_000])
    }

    @Test("work scheduled by work runs in the same pass when it falls due within it")
    func nestedWork() {
        let scheduler = TestScheduler()
        let runs = Locked<[String]>([])

        scheduler.run {
            runs.withLock { $0.append("outer") }
            scheduler.run { runs.withLock { $0.append("inner") } }
            _ = scheduler.runAfter(milliseconds: 1) { runs.withLock { $0.append("later") } }
        }
        scheduler.runCurrent()

        #expect(runs.withLock { $0 } == ["outer", "inner"])

        scheduler.advanceTime(by: 1)
        scheduler.runCurrent()

        #expect(runs.withLock { $0 } == ["outer", "inner", "later"])
    }

    @Test("cancelled work never runs, and does not move time forward")
    func cancellation() {
        let scheduler = TestScheduler()
        let ran = Locked(false)

        let timer = scheduler.runAfter(milliseconds: 300_000) { ran.withLock { $0 = true } }
        _ = scheduler.runAfter(milliseconds: 5) {}
        timer.cancel()
        scheduler.advanceUntilIdle()

        #expect(!ran.withLock { $0 })
        #expect(scheduler.currentTime == 5)
    }

    @Test("the clock reads the start plus virtual time")
    func clock() {
        let scheduler = TestScheduler(startMillis: 1_000)

        scheduler.advanceTime(by: 250)

        #expect(scheduler.nowMillis == 1_250)
    }
}
