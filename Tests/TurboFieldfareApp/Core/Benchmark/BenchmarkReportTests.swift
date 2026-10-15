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

    /// A report written before format 2 still lists, with the new fields nil.
    @Test func aFormatOneReportStillReads() throws {
        let store = BenchmarkStore(root: tempRoot())
        defer { try? FileManager.default.removeItem(at: store.root) }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = try store.makeRunFolder(started: started)
        var saved = report(id: folder.lastPathComponent, started: started)
        saved.cases = [caseResult("short-explanation")]
        try store.save(saved)

        let url = folder.appendingPathComponent(BenchmarkStore.reportFileName)
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["format"] as? Int == 2)
        root["format"] = 1
        root["submissionID"] = nil
        try JSONSerialization.data(withJSONObject: root).write(to: url)

        let read = try #require(store.list().first)
        #expect(read.format == 1)
        #expect(read.submissionID == nil)
        #expect(read.cases[0].footers == nil)
        #expect(read.cases[0].peakFootprintBytes == nil)
    }

    /// The results Worker refuses any field it does not know, so the app must
    /// write exactly the fields of its fixture: decoding that file and
    /// encoding it again gives the same JSON.
    @Test func theWorkersFixtureIsWhatTheAppWrites() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("server/benchmark-worker/test/fixtures/report-format2.json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(BenchmarkReport.self, from: data)
        #expect(report.format == BenchmarkReport.currentFormat)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fixture = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let written = try JSONSerialization.jsonObject(with: encoder.encode(report))
            as? NSDictionary
        #expect(written == fixture)
    }

    @Test func eachRunGetsItsOwnSubmissionID() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let first = report(id: "a", started: started)
        let second = report(id: "a", started: started)
        #expect(first.submissionID != nil)
        #expect(first.submissionID != second.submissionID)
    }

    private let home = "/var/mobile/Containers/Data/Application/EBC8224E-FE39-4036-8976-9F126979E37C"

    /// The two path lines a real phone log has (`model-found` and
    /// `receipt-path-mismatch`), as the harness writes them.
    @Test func redactionTakesOutTheContainerPaths() {
        let found = "4, 65, model-found, footprint=1, \(home)/Library/Application Support/"
            + "TurboFieldfare/gemma4.gturbo"
        #expect(BenchmarkRedaction.redact(found, home: home)
            == "4, 65, model-found, footprint=1, ~/Library/Application Support/"
                + "TurboFieldfare/gemma4.gturbo")

        let stale = "/var/mobile/Containers/Data/Application/65DC2FE3-E4CA-4C5D-BC02-D42C5C039DC6"
        let mismatch = "receipt names \(stale)/Library/m.gturbo but the model is at "
            + "/private\(home)/Library/m.gturbo"
        #expect(BenchmarkRedaction.redact(mismatch, home: home)
            == "receipt names <other install>/Library/m.gturbo but the model is at "
                + "~/Library/m.gturbo")
    }

    @Test func redactionAlsoCoversTheAppBundleAndLeavesOtherTextAlone() {
        let bundle = "/private/var/containers/Bundle/Application/"
            + "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9/TurboFieldfareiOS.app/tokenizer.json"
        #expect(BenchmarkRedaction.redact("no tokenizer at \(bundle)", home: home)
            == "no tokenizer at <other install>/TurboFieldfareiOS.app/tokenizer.json")
        let footer = "[expert-io decode bytes/tok=227.02MB hit-rate=73.7%]"
        #expect(BenchmarkRedaction.redact(footer, home: home) == footer)
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

/// Answers every request with one status and body, and keeps the last request.
private final class StubResultsProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 201
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct BenchmarkSubmissionTests {
    private func report() -> BenchmarkReport {
        var report = BenchmarkReport(
            id: "20261013T183100Z", started: Date(timeIntervalSince1970: 1_800_000_000),
            device: .init(identifier: "iPhone18,3", physicalMemoryBytes: 8 << 30,
                          osVersion: "26.6", appVersion: "1.0 (1)",
                          thermalAtStart: "nominal", batteryAtStart: "90%/charging",
                          lowPowerModeAtStart: false),
            model: .init(name: "Gemma 4", folder: "gemma4.gturbo", manifestSHA256: nil),
            settings: .init(maxContext: 4096, maxNewTokens: 1024, expertCacheSlots: 24,
                            temperature: 0.2, topK: 64, topP: 0.95, seed: 1),
            plannedCases: BenchmarkProtocol.caseIDs)
        report.outcome = .completed
        return report
    }

    private func submission() -> BenchmarkSubmission {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubResultsProtocol.self]
        return BenchmarkSubmission(endpoint: URL(string: "https://bench.test/v1/results")!,
                                   session: URLSession(configuration: configuration))
    }

    /// `sentAt` is the phone's own note; the Worker would refuse the field.
    @Test func thePayloadLeavesOutWhenItWasSent() throws {
        let unsent = report()
        var sent = unsent
        sent.sentAt = Date(timeIntervalSince1970: 1_800_001_000)
        let payload = try BenchmarkSubmission.payload(for: sent)
        #expect(payload == (try BenchmarkSubmission.payload(for: unsent)))
        #expect(!String(decoding: payload, as: UTF8.self).contains("sentAt"))
        #expect(String(decoding: payload, as: UTF8.self).contains("\"90%/charging\""))
    }

    @Test func onlyTheCurrentFormatCanBeSent() {
        var old = report()
        #expect(BenchmarkSubmission.canSend(old))
        old.format = 1
        #expect(!BenchmarkSubmission.canSend(old))
    }

    @Test func theRequestIsThePayloadAsJSON() async throws {
        StubResultsProtocol.status = 201
        StubResultsProtocol.body = Data(#"{"stored":"x"}"#.utf8)
        let sent = report()
        #expect(try await submission().send(sent) == .stored)
        let request = try #require(StubResultsProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(StubResultsProtocol.lastBody == (try BenchmarkSubmission.payload(for: sent)))
    }

    @Test func eachReplyMeansWhatTheWorkerSays() async throws {
        let cases: [(Int, String, BenchmarkSubmission.Reply)] = [
            (409, #"{"error":"already stored"}"#, .stored),
            (400, #"{"error":"report.settings.topK: expected 64","field":"x"}"#,
             .refused("report.settings.topK: expected 64")),
            (429, "{}", .tryLater),
            (500, "", .failed(status: 500)),
        ]
        for (status, body, expected) in cases {
            StubResultsProtocol.status = status
            StubResultsProtocol.body = Data(body.utf8)
            #expect(try await submission().send(report()) == expected, "\(status)")
        }
    }

    @Test func markingARunSentKeepsTheDate() throws {
        let store = BenchmarkStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-sent-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let folder = try store.makeRunFolder(started: Date(timeIntervalSince1970: 1_800_000_000))
        var saved = report()
        saved.id = folder.lastPathComponent
        try store.save(saved)
        let when = Date(timeIntervalSince1970: 1_800_002_000)
        try store.markSent(saved.id, at: when)
        #expect(store.list().first?.sentAt == when)
    }
}
