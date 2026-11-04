import Foundation
import Testing

@testable import TurboFieldfare

/// The endpoint quality gate's arithmetic: where endpoints land, and NLL and
/// top-k from raw (pre-softcap) logits.
@Suite struct PrefillEndpointScoringTests {

    @Test func endpointsSpreadEvenlyAndEndAtTheWholeText() {
        #expect(PrefillEndpointScoring.endpoints(tokenCount: 3015, count: 4) == [754, 1508, 2261, 3015])
        #expect(PrefillEndpointScoring.endpoints(tokenCount: 3, count: 8) == [1, 2, 3])
        #expect(PrefillEndpointScoring.endpoints(tokenCount: 0, count: 8).isEmpty)
    }

    @Test func scoreAppliesTheSoftcapBeforeTheLogSoftmax() {
        // Raw logits 60, 0, 0, 0: the softcap maps 60 to 30·tanh(2).
        let logits: [Float16] = [60, 0, 0, 0]
        let capped = 30 * tanh(2.0)
        let logSum = log(exp(capped) + 3)
        let result = logits.withUnsafeBufferPointer {
            PrefillEndpointScoring.score(logits: $0, target: 1, topK: 2)
        }
        #expect(abs(result.nll! - logSum) < 1e-9)
        #expect(result.topIDs.first == 0)
        #expect(abs(result.topLogProbs[0] - (capped - logSum)) < 1e-9)
        #expect(result.topIDs.count == 2)
    }

    @Test func scoreWithoutATargetStillRanks() {
        let logits: [Float16] = [1, 3, 2]
        let result = logits.withUnsafeBufferPointer {
            PrefillEndpointScoring.score(logits: $0, target: nil, topK: 3)
        }
        #expect(result.nll == nil)
        #expect(result.topIDs == [1, 2, 0])
    }
}
