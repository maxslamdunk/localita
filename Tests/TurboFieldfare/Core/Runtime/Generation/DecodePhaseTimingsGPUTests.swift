import Testing
import Foundation

@testable import TurboFieldfare

/// The GPU half of the phase breakdown. `busy` is the figure `idle` is derived
/// from, so its union arithmetic is pinned here: overlapping command buffers
/// count once, and a buffer that never executed counts zero.
@Suite struct DecodePhaseTimingsGPUTests {

    @Test func disjointIntervalsAdd() {
        let nanos = DecodePhaseTimings.unionNanoseconds(of: [
            (start: 1.000, end: 1.002),
            (start: 1.005, end: 1.006),
        ])
        #expect(nanos == 3_000_000)
    }

    @Test func overlappingAndNestedIntervalsCountOnce() {
        // 1.000–1.004 and 1.003–1.006 overlap; 1.0045–1.005 sits inside the
        // second; 1.010–1.011 stands alone. Union: 6 ms + 1 ms.
        let nanos = DecodePhaseTimings.unionNanoseconds(of: [
            (start: 1.003, end: 1.006),
            (start: 1.000, end: 1.004),
            (start: 1.0045, end: 1.005),
            (start: 1.010, end: 1.011),
        ])
        #expect(abs(Int64(nanos) - 7_000_000) <= 1)
    }

    @Test func emptyAndInvertedIntervalsCountZero() {
        // A command buffer that never executed reports 0 for both timestamps.
        #expect(DecodePhaseTimings.unionNanoseconds(of: []) == 0)
        #expect(DecodePhaseTimings.unionNanoseconds(of: [(start: 0, end: 0)]) == 0)
        #expect(DecodePhaseTimings.unionNanoseconds(of: [(start: 2.0, end: 1.0)]) == 0)
    }

    @Test func deltaCoversEveryGPUField() {
        // A field left out of `delta` would report its whole-run total as the
        // decode figure, prefill included.
        var earlier = DecodePhaseTimings()
        earlier.gpuEmbedNanos = 1
        earlier.gpuCb1Nanos = 2
        earlier.gpuSharedNanos = 3
        earlier.gpuHitExpertsNanos = 4
        earlier.gpuRoutedNanos = 5
        earlier.gpuHeadNanos = 6
        earlier.gpuBusyNanos = 7
        var later = earlier
        later.gpuEmbedNanos += 10
        later.gpuCb1Nanos += 20
        later.gpuSharedNanos += 30
        later.gpuHitExpertsNanos += 40
        later.gpuRoutedNanos += 50
        later.gpuHeadNanos += 60
        later.gpuBusyNanos += 70

        let window = later.delta(since: earlier)
        #expect(window == DecodePhaseTimings(gpuEmbedNanos: 10,
                                             gpuCb1Nanos: 20,
                                             gpuSharedNanos: 30,
                                             gpuHitExpertsNanos: 40,
                                             gpuRoutedNanos: 50,
                                             gpuHeadNanos: 60,
                                             gpuBusyNanos: 70))
    }
}
