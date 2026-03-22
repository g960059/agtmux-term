import XCTest
import AppKit
@testable import AgtmuxTerm

final class TrackpadScrollPhaseProfileTests: XCTestCase {
    func testTrackpadBurstModePreservesLegacyDirectTouchPhases() {
        let events = (0..<4).map {
            TrackpadScrollPhaseProfile.event(
                forIteration: $0,
                repeatCount: 4,
                mode: .trackpadBurst
            )
        }

        XCTAssertEqual(
            events,
            [
                TrackpadScrollPhaseEvent(phase: .began, momentumPhase: []),
                TrackpadScrollPhaseEvent(phase: .changed, momentumPhase: []),
                TrackpadScrollPhaseEvent(phase: .changed, momentumPhase: []),
                TrackpadScrollPhaseEvent(phase: .ended, momentumPhase: []),
            ]
        )
    }

    func testTrackpadBurstModeUsesCombinedBeganEndedForSingleEvent() {
        let event = TrackpadScrollPhaseProfile.event(
            forIteration: 0,
            repeatCount: 1,
            mode: .trackpadBurst
        )

        XCTAssertEqual(event, TrackpadScrollPhaseEvent(phase: [.began, .ended], momentumPhase: []))
    }

    func testTrackpadBurstMomentumSplitsDirectAndMomentumPhases() {
        let directTouchCount = TrackpadScrollPhaseProfile.directTouchEventCount(forRepeatCount: 24)
        XCTAssertEqual(directTouchCount, 10)

        let firstDirect = TrackpadScrollPhaseProfile.event(
            forIteration: 0,
            repeatCount: 24,
            mode: .trackpadBurstMomentum
        )
        let lastDirect = TrackpadScrollPhaseProfile.event(
            forIteration: directTouchCount - 1,
            repeatCount: 24,
            mode: .trackpadBurstMomentum
        )
        let firstMomentum = TrackpadScrollPhaseProfile.event(
            forIteration: directTouchCount,
            repeatCount: 24,
            mode: .trackpadBurstMomentum
        )
        let lastMomentum = TrackpadScrollPhaseProfile.event(
            forIteration: 23,
            repeatCount: 24,
            mode: .trackpadBurstMomentum
        )

        XCTAssertEqual(firstDirect, TrackpadScrollPhaseEvent(phase: .began, momentumPhase: []))
        XCTAssertEqual(lastDirect, TrackpadScrollPhaseEvent(phase: .ended, momentumPhase: []))
        XCTAssertEqual(firstMomentum, TrackpadScrollPhaseEvent(phase: [], momentumPhase: .began))
        XCTAssertEqual(lastMomentum, TrackpadScrollPhaseEvent(phase: [], momentumPhase: .ended))
    }

    func testTrackpadBurstMomentumFallsBackToDirectTouchForShortBursts() {
        let events = (0..<3).map {
            TrackpadScrollPhaseProfile.event(
                forIteration: $0,
                repeatCount: 3,
                mode: .trackpadBurstMomentum
            )
        }

        XCTAssertEqual(
            events,
            [
                TrackpadScrollPhaseEvent(phase: .began, momentumPhase: []),
                TrackpadScrollPhaseEvent(phase: .changed, momentumPhase: []),
                TrackpadScrollPhaseEvent(phase: .ended, momentumPhase: []),
            ]
        )
    }

    func testSyntheticSequenceSeparatesDirectEndedIntoZeroDeltaTailEvent() {
        let events = TrackpadScrollPhaseProfile.syntheticSequence(
            repeatCount: 4,
            mode: .trackpadBurst
        )

        XCTAssertEqual(
            events,
            [
                SyntheticTrackpadScrollEvent(deliversDelta: true, phase: .began, momentumPhase: []),
                SyntheticTrackpadScrollEvent(deliversDelta: true, phase: .changed, momentumPhase: []),
                SyntheticTrackpadScrollEvent(deliversDelta: true, phase: .changed, momentumPhase: []),
                SyntheticTrackpadScrollEvent(deliversDelta: true, phase: .changed, momentumPhase: []),
                SyntheticTrackpadScrollEvent(deliversDelta: false, phase: .ended, momentumPhase: []),
            ]
        )
    }

    func testSyntheticSequenceSeparatesMomentumEndedIntoZeroDeltaTailEvent() {
        let events = TrackpadScrollPhaseProfile.syntheticSequence(
            repeatCount: 24,
            mode: .trackpadBurstMomentum
        )

        XCTAssertEqual(events.count, 26)
        XCTAssertEqual(events.first, SyntheticTrackpadScrollEvent(deliversDelta: true, phase: .began, momentumPhase: []))
        XCTAssertEqual(events[9], SyntheticTrackpadScrollEvent(deliversDelta: true, phase: .changed, momentumPhase: []))
        XCTAssertEqual(events[10], SyntheticTrackpadScrollEvent(deliversDelta: false, phase: .ended, momentumPhase: []))
        XCTAssertEqual(events[11], SyntheticTrackpadScrollEvent(deliversDelta: true, phase: [], momentumPhase: .began))
        XCTAssertEqual(events[24], SyntheticTrackpadScrollEvent(deliversDelta: true, phase: [], momentumPhase: .changed))
        XCTAssertEqual(events[25], SyntheticTrackpadScrollEvent(deliversDelta: false, phase: [], momentumPhase: .ended))
    }

    func testSyntheticSequenceUsesZeroDeltaEndForSingleDirectEvent() {
        let events = TrackpadScrollPhaseProfile.syntheticSequence(
            repeatCount: 1,
            mode: .trackpadBurst
        )

        XCTAssertEqual(
            events,
            [
                SyntheticTrackpadScrollEvent(deliversDelta: true, phase: .began, momentumPhase: []),
                SyntheticTrackpadScrollEvent(deliversDelta: false, phase: .ended, momentumPhase: []),
            ]
        )
    }

    func testTrackpadBurstMomentumModeParsesFromRawValue() {
        XCTAssertEqual(
            TrackpadScrollPhaseMode(rawValue: "trackpad-burst-momentum"),
            .trackpadBurstMomentum
        )
    }

    func testNoneModeReturnsNoDirectOrMomentumPhases() {
        let event = TrackpadScrollPhaseProfile.event(
            forIteration: 7,
            repeatCount: 24,
            mode: .none
        )

        XCTAssertEqual(event, .none)
    }
}
