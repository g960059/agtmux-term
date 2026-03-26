import CoreFoundation
import Foundation

final class GhosttyTickScheduler {
    typealias MainRunLoopScheduler = (@escaping @MainActor () -> Void) -> Void
    typealias TickHandler = @MainActor () -> Void

    private let lock = NSLock()
    private let scheduleOnMainRunLoop: MainRunLoopScheduler
    private let runTick: TickHandler
    private var pendingTickCredits = 0
    private var tickDrainScheduled = false

    init(
        scheduleOnMainRunLoop: @escaping MainRunLoopScheduler,
        runTick: @escaping TickHandler
    ) {
        self.scheduleOnMainRunLoop = scheduleOnMainRunLoop
        self.runTick = runTick
    }

    func enqueueTick() {
        lock.lock()
        if pendingTickCredits < Int.max {
            pendingTickCredits += 1
        }
        let shouldSchedule = !tickDrainScheduled
        if shouldSchedule {
            tickDrainScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        scheduleOnMainRunLoop { [weak self] in
            self?.drainTickQueue()
        }
    }

    @MainActor
    private func drainTickQueue() {
        while consumePendingTickCredit() {
            runTick()
        }

        lock.lock()
        tickDrainScheduled = false
        let shouldReschedule = pendingTickCredits > 0
        if shouldReschedule {
            tickDrainScheduled = true
        }
        lock.unlock()

        guard shouldReschedule else { return }
        scheduleOnMainRunLoop { [weak self] in
            self?.drainTickQueue()
        }
    }

    private func consumePendingTickCredit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingTickCredits > 0 else { return false }
        pendingTickCredits -= 1
        return true
    }

    func pendingTickCreditsForTesting() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingTickCredits
    }

    func tickDrainScheduledForTesting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tickDrainScheduled
    }
}
