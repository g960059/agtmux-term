import AppKit

enum TrackpadScrollPhaseMode: String {
    case none
    case trackpadBurst = "trackpad-burst"
    case trackpadBurstMomentum = "trackpad-burst-momentum"
}

struct TrackpadScrollPhaseEvent: Equatable {
    var phase: NSEvent.Phase
    var momentumPhase: NSEvent.Phase

    static let none = TrackpadScrollPhaseEvent(phase: [], momentumPhase: [])
}

enum TrackpadScrollPhaseProfile {
    static func event(
        forIteration iteration: Int,
        repeatCount: Int,
        mode: TrackpadScrollPhaseMode
    ) -> TrackpadScrollPhaseEvent {
        let effectiveRepeatCount = max(1, repeatCount)
        let clampedIteration = max(0, min(iteration, effectiveRepeatCount - 1))

        switch mode {
        case .none:
            return .none
        case .trackpadBurst:
            return TrackpadScrollPhaseEvent(
                phase: phase(forIteration: clampedIteration, count: effectiveRepeatCount),
                momentumPhase: []
            )
        case .trackpadBurstMomentum:
            guard effectiveRepeatCount >= 4 else {
                return TrackpadScrollPhaseEvent(
                    phase: phase(forIteration: clampedIteration, count: effectiveRepeatCount),
                    momentumPhase: []
                )
            }

            let directTouchCount = directTouchEventCount(forRepeatCount: effectiveRepeatCount)
            if clampedIteration < directTouchCount {
                return TrackpadScrollPhaseEvent(
                    phase: phase(forIteration: clampedIteration, count: directTouchCount),
                    momentumPhase: []
                )
            }

            let momentumIteration = clampedIteration - directTouchCount
            let momentumCount = effectiveRepeatCount - directTouchCount
            return TrackpadScrollPhaseEvent(
                phase: [],
                momentumPhase: phase(forIteration: momentumIteration, count: momentumCount)
            )
        }
    }

    static func directTouchEventCount(forRepeatCount repeatCount: Int) -> Int {
        guard repeatCount >= 4 else { return repeatCount }
        let directTouchRatio = 0.4
        let scaled = Int((Double(repeatCount) * directTouchRatio).rounded())
        return min(max(3, scaled), repeatCount - 1)
    }

    static func phase(forIteration iteration: Int, count: Int) -> NSEvent.Phase {
        guard count > 1 else {
            return [.began, .ended]
        }
        if iteration == 0 {
            return .began
        }
        if iteration == count - 1 {
            return .ended
        }
        return .changed
    }
}
