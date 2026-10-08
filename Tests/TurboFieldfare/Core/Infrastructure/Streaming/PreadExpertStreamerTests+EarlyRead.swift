import Darwin
import Foundation
import Metal
import Testing

@testable import TurboFieldfare

extension PreadExpertStreamerTests {
  /// An adopted early read serves the planned miss from the staging buffer,
  /// skips that read, and hands the slot's previous buffer back as staging.
  @Test func adoptedEarlyReadServesMissWithoutRereading() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: device, slotCount: 4)
    _ = try streamer.loadExpertsCached(experts: [0, 1])

    let staging = try streamer.makeStagingBuffer()
    let stagedBuffer = staging.buffer
    try streamer.readEarly(expert: 3, into: staging.pointer)
    let before = streamer.counters.snapshot()

    let plan = streamer.planExpertsCached(experts: [0, 3, 2])
    let index = try #require(plan.experts.firstIndex(of: 3))
    #expect(plan.misses.contains(index))
    let evictedBuffer = streamer.expertCachePlanBuffers(plan)[index].buffer
    streamer.adoptStagedExpert(staging, plan: plan, index: index)
    var waited = false
    let results = try streamer.executeExpertCachePlan(
      plan, skippingMisses: [index], beforeAdmitting: { waited = true })

    #expect(waited)
    #expect(results[index].buffer === stagedBuffer)
    #expect(staging.buffer === evictedBuffer)
    for (offset, result) in results.enumerated() {
      let got = Self.bytes(of: result.buffer, offset: 0, count: Self.expertStride)
      #expect(got.allSatisfy { $0 == Self.tagByte(plan.experts[offset]) })
    }
    let delta = streamer.counters.snapshot().delta(since: before)
    #expect(delta.reads == 1)  // expert 2 only; 3 came from staging
    #expect(delta.earlyReadsUsed == 1)
    #expect(streamer.residentExperts() == [0, 1, 2, 3])  // 4 slots: nothing evicted

    // The next plan finds 3 resident in the adopted buffer.
    let again = streamer.planExpertsCached(experts: [3])
    #expect(again.misses.isEmpty)
    let got = Self.bytes(of: streamer.expertCachePlanBuffers(again)[0].buffer,
                         offset: 0, count: Self.expertStride)
    #expect(got.allSatisfy { $0 == Self.tagByte(3) })
  }

  /// An early read counts as a read and an early read, and its bytes count
  /// toward bytes read; leaving it unused changes nothing in the cache.
  @Test func unusedEarlyReadLeavesCacheUnchanged() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path), device: device, slotCount: 4)
    _ = try streamer.loadExpertsCached(experts: [0, 1])
    let before = streamer.counters.snapshot()

    let staging = try streamer.makeStagingBuffer()
    try streamer.readEarly(expert: 3, into: staging.pointer)
    let delta = streamer.counters.snapshot().delta(since: before)
    #expect(delta.reads == 1)
    #expect(delta.earlyReads == 1)
    #expect(delta.earlyReadsUsed == 0)
    #expect(delta.bytesRead == UInt64(Self.expertStride))
    #expect(streamer.residentExperts() == [0, 1])
    let staged = Self.bytes(of: staging.buffer, offset: 0, count: Self.expertStride)
    #expect(staged.allSatisfy { $0 == Self.tagByte(3) })
  }

  @Test func earlyGuessIsBestNonResidentExpert() {
    let scores: [Float] = [0.5, 2.0, 1.5, 3.0]
    scores.withUnsafeBufferPointer { p in
      #expect(NextLayerExpertPrefetcher.choose(
        scores: p.baseAddress!, count: 4, resident: [3]) == [1])
      #expect(NextLayerExpertPrefetcher.choose(
        scores: p.baseAddress!, count: 4, resident: []) == [3])
      #expect(NextLayerExpertPrefetcher.choose(
        scores: p.baseAddress!, count: 4, resident: [0, 1, 2, 3]) == [])
    }
  }

  @Test func earlyGuessesAreBestNonResidentExpertsBestFirst() {
    let scores: [Float] = [0.5, 2.0, 1.5, 3.0, 2.0]
    scores.withUnsafeBufferPointer { p in
      #expect(NextLayerExpertPrefetcher.choose(
        scores: p.baseAddress!, count: 5, resident: [], limit: 2) == [3, 1])
      // Ties go to the lower ID.
      #expect(NextLayerExpertPrefetcher.choose(
        scores: p.baseAddress!, count: 5, resident: [3], limit: 2) == [1, 4])
      #expect(NextLayerExpertPrefetcher.choose(
        scores: p.baseAddress!, count: 5, resident: [1, 3, 4], limit: 3) == [2, 0])
    }
  }

  @Test func earlyReadsPerLayerComesFromTheEnvironment() {
    let key = NextLayerExpertPrefetcher.readsEnvironmentKey
    #expect(NextLayerExpertPrefetcher.readsPerLayer(environment: [:]) == 1)
    #expect(NextLayerExpertPrefetcher.readsPerLayer(environment: [key: "2"]) == 2)
    #expect(NextLayerExpertPrefetcher.readsPerLayer(environment: [key: "8"]) == 8)
    #expect(NextLayerExpertPrefetcher.readsPerLayer(environment: [key: "0"]) == 1)
    #expect(NextLayerExpertPrefetcher.readsPerLayer(environment: [key: "9"]) == 1)
    #expect(NextLayerExpertPrefetcher.readsPerLayer(environment: [key: "two"]) == 1)
  }
}
