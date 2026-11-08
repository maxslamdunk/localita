import Testing
import Foundation

@testable import TurboFieldfare

/// The prefill breakdown's interval arithmetic. Storage busy and its overlap
/// with the GPU are what size the prefill work, so the merge and intersection
/// are pinned here, along with every field surviving `delta` and `adding`.
@Suite struct PrefillPhaseTimingsTests {

    @Test func mergeCountsOverlapOnceAndDropsEmpty() {
        let merged = PrefillPhaseTimings.mergedIntervals([
            (start: 30, end: 60),
            (start: 0, end: 40),
            (start: 45, end: 50),
            (start: 100, end: 110),
            (start: 120, end: 120),
            (start: 130, end: 125),
        ])
        #expect(merged.map(\.start) == [0, 100])
        #expect(merged.map(\.end) == [60, 110])
        #expect(PrefillPhaseTimings.totalLength(of: merged) == 70)
    }

    @Test func overlapIntersectsTheTwoUnions() {
        // GPU: 0–10, 20–30. Storage: 5–25 read twice over, and 40–50.
        // Intersection: 5–10 and 20–25.
        let gpu: [(start: UInt64, end: UInt64)] = [(0, 10), (20, 30)]
        let storage: [(start: UInt64, end: UInt64)] = [(5, 25), (8, 22), (40, 50)]
        #expect(PrefillPhaseTimings.overlapNanoseconds(gpu, storage) == 10)
        #expect(PrefillPhaseTimings.overlapNanoseconds(storage, gpu) == 10)
        #expect(PrefillPhaseTimings.overlapNanoseconds(gpu, []) == 0)
    }

    @Test func bothIdleIsWallMinusEitherBusy() {
        var timings = PrefillPhaseTimings()
        timings.wallNanos = 100
        timings.gpuBusyNanos = 60
        timings.storageBusyNanos = 30
        timings.storageGPUOverlapNanos = 10
        #expect(timings.bothIdleNanos == 20)
        timings.wallNanos = 70
        #expect(timings.bothIdleNanos == 0)
    }

    @Test func deltaAndAddingCoverEveryField() {
        // Set every counter to a distinct value through the public setters, so
        // a field missing from the key-path list shows up as unequal.
        var unit = PrefillPhaseTimings()
        unit.chunks = 1
        unit.profiledChunks = 1
        let fields: [WritableKeyPath<PrefillPhaseTimings, UInt64>] = [
            \.wallNanos, \.attentionBlockNanos, \.routePlanNanos, \.sharedNanos, \.routedNanos,
            \.fetchNanos, \.drainNanos, \.tailNanos, \.headNanos,
            \.gpuEmbedNanos, \.gpuAttentionBlockNanos, \.gpuQKVProjectionNanos,
            \.gpuQKVEpilogueNanos, \.gpuAttentionNanos, \.gpuOutputProjectionNanos,
            \.gpuRouterNanos, \.gpuSharedNanos, \.gpuRoutedNanos, \.gpuTailNanos, \.gpuHeadNanos,
            \.gpuBusyNanos, \.storageBusyNanos, \.storageGPUOverlapNanos,
        ]
        for (index, field) in fields.enumerated() {
            unit[keyPath: field] = UInt64(index + 1)
        }
        let twice = unit.adding(unit)
        #expect(twice.chunks == 2)
        for (index, field) in fields.enumerated() {
            #expect(twice[keyPath: field] == UInt64(2 * (index + 1)))
        }
        #expect(twice.delta(since: unit) == unit)
        #expect(unit.delta(since: unit) == .zero)
    }
}
