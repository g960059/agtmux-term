import CoreFoundation
import XCTest
@testable import AgtmuxTerm

@MainActor
final class GhosttyTickSchedulerTests: XCTestCase {
    func testBackToBackWakeupsDrainAsSeparateTicks() {
        var tickCount = 0
        let scheduler = makeScheduler {
            tickCount += 1
        }

        scheduler.enqueueTick()
        scheduler.enqueueTick()
        waitForDrain(of: scheduler)

        XCTAssertEqual(tickCount, 2)
        XCTAssertEqual(scheduler.pendingTickCreditsForTesting(), 0)
        XCTAssertFalse(scheduler.tickDrainScheduledForTesting())
    }

    func testWakeupQueuedDuringTickSchedulesFollowupTick() {
        var tickCount = 0
        var scheduler: GhosttyTickScheduler!
        scheduler = makeScheduler {
            tickCount += 1
            if tickCount == 1 {
                scheduler.enqueueTick()
            }
        }

        scheduler.enqueueTick()
        waitForDrain(of: scheduler)

        XCTAssertEqual(tickCount, 2)
        XCTAssertEqual(scheduler.pendingTickCreditsForTesting(), 0)
        XCTAssertFalse(scheduler.tickDrainScheduledForTesting())
    }

    func testEnqueueTickIfNeededCoalescesPendingWakeup() {
        var tickCount = 0
        let scheduler = makeScheduler {
            tickCount += 1
        }

        XCTAssertTrue(scheduler.enqueueTickIfNeeded())
        XCTAssertFalse(scheduler.enqueueTickIfNeeded())
        waitForDrain(of: scheduler)

        XCTAssertEqual(tickCount, 1)
        XCTAssertEqual(scheduler.pendingTickCreditsForTesting(), 0)
        XCTAssertFalse(scheduler.tickDrainScheduledForTesting())
    }

    private func makeScheduler(
        runTick: @escaping @MainActor () -> Void
    ) -> GhosttyTickScheduler {
        GhosttyTickScheduler(
            scheduleOnMainRunLoop: { action in
                let mainRunLoop = CFRunLoopGetMain()
                CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
                    MainActor.assumeIsolated {
                        action()
                    }
                }
                CFRunLoopWakeUp(mainRunLoop)
            },
            runTick: runTick
        )
    }

    private func waitForDrain(
        of scheduler: GhosttyTickScheduler,
        timeout: TimeInterval = 1.0
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if scheduler.pendingTickCreditsForTesting() == 0,
               scheduler.tickDrainScheduledForTesting() == false {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for Ghostty tick queue to drain")
    }
}
