import Darwin
import Foundation
import Metal
import Testing

@testable import TurboFieldfare

/// Bytes/token instrumentation: the streamer must count exactly the bytes it
/// pulls through `pread` and exactly the requests the cache answered. A hit
/// that reads nothing is the whole point of the metric, so the fixtures below
/// pin bytes against hits rather than against request counts.
extension PreadExpertStreamerTests {
  @Test func countersRecordMissBytesAndReads() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let counters = ExpertIOCounters()
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path),
      device: device,
      slotCount: 4,
      counters: counters)

    #expect(counters.snapshot() == .zero)

    _ = try streamer.loadExpertsCached(experts: [0, 1])

    let afterMisses = counters.snapshot()
    #expect(afterMisses.cacheMisses == 2)
    #expect(afterMisses.cacheHits == 0)
    #expect(afterMisses.reads == 2)
    #expect(afterMisses.bytesRead == UInt64(2 * Self.expertStride))
    #expect(afterMisses.cacheHitRate == 0)
  }

  @Test func countersRecordHitsWithoutBytes() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let counters = ExpertIOCounters()
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path),
      device: device,
      slotCount: 4,
      counters: counters)

    _ = try streamer.loadExpertsCached(experts: [0, 1])
    let afterMisses = counters.snapshot()
    _ = try streamer.loadExpertsCached(experts: [0, 1])
    let afterHits = counters.snapshot()

    // A hit is a read that did not happen: requests advanced, bytes did not.
    #expect(afterHits.cacheHits == 2)
    #expect(afterHits.cacheMisses == 2)
    #expect(afterHits.cacheRequests == 4)
    #expect(afterHits.bytesRead == afterMisses.bytesRead)
    #expect(afterHits.reads == afterMisses.reads)
    #expect(afterHits.cacheHitRate == 0.5)
  }

  @Test func unplaceablePlanIsNotCounted() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let counters = ExpertIOCounters()
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path),
      device: device,
      slotCount: 4,
      counters: counters)

    _ = try streamer.loadExpertsCached(experts: [0, 1])
    let beforeRejectedPlan = counters.snapshot()

    let plan = streamer.planExpertsCachedIfPossible(
      experts: [0, 2, 3, 4],
      avoidingSlots: [0, 1])

    #expect(plan == nil)
    // A plan the cache could not place was never a request it answered;
    // counting it would depress the hit rate with phantom misses.
    #expect(counters.snapshot() == beforeRejectedPlan)
  }

  @Test func sharedCountersSumAcrossStreamers() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let counters = ExpertIOCounters()
    // Stands in for a model's per-layer streamers: one snapshot, whole model.
    let first = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path),
      device: device,
      slotCount: 4,
      counters: counters)
    let second = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path),
      device: device,
      slotCount: 4,
      counters: counters)

    _ = try first.loadExpertsCached(experts: [0, 1])
    _ = try second.loadExpertsCached(experts: [0, 1])

    let stats = counters.snapshot()
    #expect(stats.cacheMisses == 4)
    #expect(stats.reads == 4)
    #expect(stats.bytesRead == UInt64(4 * Self.expertStride))
  }

  @Test func deltaIsolatesAWindow() throws {
    let url = try Self.writeSyntheticLayer()
    defer { try? FileManager.default.removeItem(at: url) }
    let device = try MetalContext().device
    let counters = ExpertIOCounters()
    let streamer = try PreadExpertStreamer(
      layout: Self.makeLayout(path: url.path),
      device: device,
      slotCount: 4,
      counters: counters)

    _ = try streamer.loadExpertsCached(experts: [0, 1])
    let atWindowStart = counters.snapshot()
    _ = try streamer.loadExpertsCached(experts: [0, 2])

    // What the prefill/decode split relies on: one hit and one miss inside the
    // window, with everything before it excluded.
    let window = counters.snapshot().delta(since: atWindowStart)
    #expect(window.cacheHits == 1)
    #expect(window.cacheMisses == 1)
    #expect(window.reads == 1)
    #expect(window.bytesRead == UInt64(Self.expertStride))
    #expect(window.cacheHitRate == 0.5)
    #expect(window.megabytesPerForward(2) == Double(Self.expertStride) / 1_048_576.0 / 2)
    #expect(window.megabytesPerForward(0) == nil)
  }
}
