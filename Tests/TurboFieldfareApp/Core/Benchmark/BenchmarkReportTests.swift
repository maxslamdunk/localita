import Foundation
import Testing
@testable import TurboFieldfareAppCore

@Suite struct BenchmarkReportTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func report(id: String, started: Date) -> BenchmarkReport {
        BenchmarkReport(
            id: id, started: started,
            device: .init(identifier: "iPhone18,3", physicalMemoryBytes: 8 << 30,
                          osVersion: "26.6", appVersion: "0.9 (12)",
                          thermalAtStart: "nominal", batteryAtStart: "80%/charging",
                          lowPowerModeAtStart: false),
            model: .init(name: "Gemma 4", folder: "gemma4.gturbo", manifestSHA256: "ab"),
            settings: .init(maxContext: 4096, maxNewTokens: 1024, expertCacheSlots: 24,
                            temperature: 0.2, topK: 64, topP: 0.95, seed: 1),
            plannedCases: BenchmarkProtocol.caseIDs)
    }

    private func caseResult(_ id: String) -> BenchmarkReport.CaseResult {
        .init(caseID: id, promptSHA256: "p", promptTokens: 61, prefillSeconds: 9.1,
              newTokens: 511, decodeSeconds: 100, stopReason: "endOfTurn",
              decodeMiBPerToken: 160.7, decodeCacheHitRate: 0.79, cooldownSeconds: 0,
              thermalAtStart: "nominal", thermalAtEnd: "fair",
              generatedSHA256: "g", logFile: "\(id).log")
    }

    @Test func aReportRoundTripsThroughTheStore() throws {
        let store = BenchmarkStore(root: tempRoot())
        defer { try? FileManager.default.removeItem(at: store.root) }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = try store.makeRunFolder(started: started)
        var saved = report(id: folder.lastPathComponent, started: started)
        saved.cases = [caseResult("short-explanation")]
        saved.outcome = .failed("no Metal device")
        saved.finished = started.addingTimeInterval(120)
        try store.save(saved)

        #expect(store.list() == [saved])
        #expect(saved.cases[0].tokensPerSecond == 5.11)
    }

    /// A run started in the same second as another gets its own folder.
    @Test func runFoldersAreNeverShared() throws {
        let store = BenchmarkStore(root: tempRoot())
        defer { try? FileManager.default.removeItem(at: store.root) }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try store.makeRunFolder(started: started)
        let second = try store.makeRunFolder(started: started)
        #expect(first != second)
    }

    @Test func theListIsNewestFirstAndSkipsUnreadableFolders() throws {
        let store = BenchmarkStore(root: tempRoot())
        defer { try? FileManager.default.removeItem(at: store.root) }
        let older = Date(timeIntervalSince1970: 1_800_000_000)
        let newer = older.addingTimeInterval(3600)
        for started in [older, newer] {
            let folder = try store.makeRunFolder(started: started)
            try store.save(report(id: folder.lastPathComponent, started: started))
        }
        let broken = try store.makeRunFolder(started: newer.addingTimeInterval(60))
        try Data("{".utf8).write(to: broken.appendingPathComponent(BenchmarkStore.reportFileName))
        _ = try store.makeRunFolder(started: newer.addingTimeInterval(120))

        #expect(store.list().map(\.started) == [newer, older])
    }

    @Test func sharedFilesPutTheReportFirstAndDeleteRemovesTheRun() throws {
        let store = BenchmarkStore(root: tempRoot())
        defer { try? FileManager.default.removeItem(at: store.root) }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = try store.makeRunFolder(started: started)
        let id = folder.lastPathComponent
        try Data().write(to: folder.appendingPathComponent("a-short.log"))
        try store.save(report(id: id, started: started))

        #expect(store.files(for: id).map(\.lastPathComponent)
            == [BenchmarkStore.reportFileName, "a-short.log"])
        try store.delete(id)
        #expect(store.list().isEmpty)
    }

    @Test func cooldownWaitsAMinuteThenForTheStartingStateAndNeverPastFive() {
        typealias C = BenchmarkCooldown
        #expect(!C.isDone(elapsed: 30, runStart: .nominal, now: .nominal))
        #expect(C.isDone(elapsed: 60, runStart: .nominal, now: .nominal))
        #expect(!C.isDone(elapsed: 200, runStart: .nominal, now: .fair))
        #expect(C.isDone(elapsed: 200, runStart: .fair, now: .fair))
        #expect(C.isDone(elapsed: 300, runStart: .nominal, now: .serious))
    }
}
