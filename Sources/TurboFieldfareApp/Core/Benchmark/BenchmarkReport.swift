import Foundation

/// One run of the in-app benchmark: the frozen `real-generation-v1` cases at
/// the protocol's settings, each from a freshly loaded model, as
/// `docs/COMMUNITY_BENCHMARKS.md` runs them in a fresh process each.
///
/// It is written beside the run's logs when the run starts and again after
/// every case, so a run the system kills still leaves a report, marked
/// `running`. The logs hold the full footer lines; this holds what a list of
/// results shows and what a submission would carry. It holds no chat content:
/// the prompts are the frozen ones, and the generated text is kept only as a
/// SHA-256. Nor does it hold a path: a failure's reason goes through
/// `BenchmarkRedaction` first.
public struct BenchmarkReport: Codable, Equatable, Sendable {
    /// Bumped when a field changes meaning, so a reader can tell old reports.
    /// Format 2 added `submissionID` and, per case, the footer lines and the
    /// memory figures; a format 1 report reads with those nil.
    public static let currentFormat = 2

    public enum Outcome: Codable, Equatable, Sendable {
        /// Still running, or the process ended before the run did.
        case running
        case completed
        /// Stopped by the person running it.
        case cancelled
        /// Stopped because the app left the screen, which a run cannot survive.
        case interrupted
        case failed(String)
    }

    public struct DeviceInfo: Codable, Equatable, Sendable {
        /// The hardware identifier, such as `iPhone18,3`, not a marketing name.
        public var identifier: String
        public var physicalMemoryBytes: UInt64
        public var osVersion: String
        public var appVersion: String
        public var thermalAtStart: String
        public var batteryAtStart: String
        public var lowPowerModeAtStart: Bool

        public init(identifier: String, physicalMemoryBytes: UInt64, osVersion: String,
                    appVersion: String, thermalAtStart: String, batteryAtStart: String,
                    lowPowerModeAtStart: Bool) {
            self.identifier = identifier
            self.physicalMemoryBytes = physicalMemoryBytes
            self.osVersion = osVersion
            self.appVersion = appVersion
            self.thermalAtStart = thermalAtStart
            self.batteryAtStart = batteryAtStart
            self.lowPowerModeAtStart = lowPowerModeAtStart
        }
    }

    public struct ModelInfo: Codable, Equatable, Sendable {
        public var name: String
        public var folder: String
        /// SHA-256 of the installed `manifest.json`, which names the source
        /// checkpoint and the layout, as the Mac protocol records it.
        public var manifestSHA256: String?

        public init(name: String, folder: String, manifestSHA256: String?) {
            self.name = name
            self.folder = folder
            self.manifestSHA256 = manifestSHA256
        }
    }

    public struct RunSettings: Codable, Equatable, Sendable {
        public var maxContext: Int
        public var maxNewTokens: Int
        public var expertCacheSlots: Int
        public var temperature: Float
        public var topK: Int
        public var topP: Float
        public var seed: UInt64

        public init(maxContext: Int, maxNewTokens: Int, expertCacheSlots: Int,
                    temperature: Float, topK: Int, topP: Float, seed: UInt64) {
            self.maxContext = maxContext
            self.maxNewTokens = maxNewTokens
            self.expertCacheSlots = expertCacheSlots
            self.temperature = temperature
            self.topK = topK
            self.topP = topP
            self.seed = seed
        }
    }

    public struct CaseResult: Codable, Equatable, Sendable {
        public var caseID: String
        public var promptSHA256: String
        public var promptTokens: Int
        public var prefillSeconds: Double
        public var newTokens: Int
        public var decodeSeconds: Double
        public var stopReason: String
        /// Routed-expert MiB read per decode forward.
        public var decodeMiBPerToken: Double?
        public var decodeCacheHitRate: Double?
        /// Seconds waited before this case for the phone to cool.
        public var cooldownSeconds: Double
        public var thermalAtStart: String
        public var thermalAtEnd: String
        public var generatedSHA256: String
        /// The case's log, relative to the run's folder.
        public var logFile: String
        /// The runtime's footer lines as the log has them: `[expert-io …]`,
        /// `[phase-time …]`, `[gpu-time …]` and `[read-latency …]`. They are
        /// what a phone row in `MEASUREMENTS.md` is read from.
        public var footers: [String]?
        /// `phys_footprint` when the case ended, with the model still loaded.
        public var footprintBytes: UInt64?
        /// The process's highest footprint so far. The run shares its process
        /// with the chat and with the cases before it, so this is an upper
        /// bound on the case's own peak, not the peak itself.
        public var peakFootprintBytes: UInt64?
        /// `os_proc_available_memory` when the case ended. With the
        /// increased-memory-limit entitlement it overstates the real headroom.
        public var availableMemoryBytes: Int64?

        public var tokensPerSecond: Double {
            decodeSeconds > 0 ? Double(newTokens) / decodeSeconds : 0
        }

        public init(caseID: String, promptSHA256: String, promptTokens: Int,
                    prefillSeconds: Double, newTokens: Int, decodeSeconds: Double,
                    stopReason: String, decodeMiBPerToken: Double?,
                    decodeCacheHitRate: Double?, cooldownSeconds: Double,
                    thermalAtStart: String, thermalAtEnd: String,
                    generatedSHA256: String, logFile: String,
                    footers: [String]? = nil, footprintBytes: UInt64? = nil,
                    peakFootprintBytes: UInt64? = nil,
                    availableMemoryBytes: Int64? = nil) {
            self.caseID = caseID
            self.promptSHA256 = promptSHA256
            self.promptTokens = promptTokens
            self.prefillSeconds = prefillSeconds
            self.newTokens = newTokens
            self.decodeSeconds = decodeSeconds
            self.stopReason = stopReason
            self.decodeMiBPerToken = decodeMiBPerToken
            self.decodeCacheHitRate = decodeCacheHitRate
            self.cooldownSeconds = cooldownSeconds
            self.thermalAtStart = thermalAtStart
            self.thermalAtEnd = thermalAtEnd
            self.generatedSHA256 = generatedSHA256
            self.logFile = logFile
            self.footers = footers
            self.footprintBytes = footprintBytes
            self.peakFootprintBytes = peakFootprintBytes
            self.availableMemoryBytes = availableMemoryBytes
        }
    }

    public var format: Int
    /// The run's folder name, which is also its identity in the store.
    public var id: String
    /// A random UUID made when the run starts, so a result sent twice can be
    /// told apart from two runs. Nothing about the device goes into it.
    public var submissionID: String?
    public var started: Date
    public var finished: Date?
    public var outcome: Outcome
    public var device: DeviceInfo
    public var model: ModelInfo
    public var settings: RunSettings
    /// The cases the run was asked for, in order; `cases` holds those done.
    public var plannedCases: [String]
    public var cases: [CaseResult]
    /// When the person sent this run to the project. Kept on the phone only:
    /// `BenchmarkSubmission.payload` leaves it out.
    public var sentAt: Date?

    public init(id: String, started: Date, device: DeviceInfo, model: ModelInfo,
                settings: RunSettings, plannedCases: [String]) {
        self.format = Self.currentFormat
        self.id = id
        self.submissionID = UUID().uuidString
        self.started = started
        self.finished = nil
        self.outcome = .running
        self.device = device
        self.model = model
        self.settings = settings
        self.plannedCases = plannedCases
        self.cases = []
        self.sentAt = nil
    }
}

/// The frozen cases and settings a standard run uses, from
/// `docs/COMMUNITY_BENCHMARKS.md`: temperature 0.2, Top-K 64, Top-P 0.95, a
/// 4,096-token context and up to 1,024 new tokens. The seed is the harness's,
/// which every phone row in `MEASUREMENTS.md` used.
public enum BenchmarkProtocol {
    public static let caseIDs = ["short-explanation", "medium-review", "long-synthesis"]
    public static let maxContext = 4096
    public static let maxNewTokens = 1024
    public static let temperature: Float = 0.2
    public static let topK = 64
    public static let topP: Float = 0.95
    public static let seed: UInt64 = 1
}

/// When the next case may start. A run heats the phone, and a hot phone is
/// slower (`serious` costs about 12%), so each case after the first waits
/// for the thermal state to come back to where the run began. It always waits
/// a minute, because the reported state lags the heat, and never more than
/// five, the bench protocol's own cooldown; a case that starts warmer than
/// the run did records the state it started at.
public enum BenchmarkCooldown {
    public static let minimum: TimeInterval = 60
    public static let maximum: TimeInterval = 300

    public static func isDone(elapsed: TimeInterval,
                              runStart: ProcessInfo.ThermalState,
                              now: ProcessInfo.ThermalState) -> Bool {
        if elapsed >= maximum { return true }
        return elapsed >= minimum && now.rawValue <= runStart.rawValue
    }

    public static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Benchmark runs on disk: one folder per run under `root`, holding
/// `report.json` and the run's logs. The folders are what a person shares,
/// so everything about a run stays in its own.
public struct BenchmarkStore: Sendable {
    public static let reportFileName = "report.json"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// A new, empty folder for a run, named by its start time so the names
    /// sort in run order.
    public func makeRunFolder(started: Date) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime,
                                   .withTimeZone]
        let base = formatter.string(from: started).replacingOccurrences(of: ":", with: "")
        var name = base
        var suffix = 1
        while FileManager.default.fileExists(atPath: folder(for: name).path) {
            suffix += 1
            name = "\(base)-\(suffix)"
        }
        let url = folder(for: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func folder(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    public func save(_ report: BenchmarkReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: folder(for: report.id)
            .appendingPathComponent(Self.reportFileName), options: .atomic)
    }

    /// Every readable report, newest first. A folder without a readable
    /// report is skipped rather than failing the list.
    public func list() -> [BenchmarkReport] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder
                .appendingPathComponent(Self.reportFileName)) else { return nil }
            return try? decoder.decode(BenchmarkReport.self, from: data)
        }
        .sorted { $0.started > $1.started }
    }

    /// The run's files, report first, for sharing.
    public func files(for id: String) -> [URL] {
        let folder = folder(for: id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted { lhs, rhs in
            if lhs == Self.reportFileName { return true }
            if rhs == Self.reportFileName { return false }
            return lhs < rhs
        }
        .map { folder.appendingPathComponent($0) }
    }

    /// Records that the run was sent, in its own report.
    public func markSent(_ id: String, at date: Date) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var report = try decoder.decode(BenchmarkReport.self, from: Data(
            contentsOf: folder(for: id).appendingPathComponent(Self.reportFileName)))
        report.sentAt = date
        try save(report)
    }

    public func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: folder(for: id))
    }
}

/// Sends a run to the project's results Worker (`server/benchmark-worker/`),
/// which checks it against the protocol and stores it. What is sent is
/// `payload(for:)`, byte for byte, which the send sheet shows in full first.
public struct BenchmarkSubmission: Sendable {
    /// The deployed Worker (2026-10-15). The app offers no sending when nil.
    /// Changing it strands app versions already out, which keep sending here.
    public static let defaultEndpoint = URL(
        string: "https://turbo-fieldfare-bench.gemma-local-ios.workers.dev/v1/results")

    public enum Reply: Equatable, Sendable {
        /// Stored now, or already stored by an earlier send of the same run.
        case stored
        /// The Worker refused the report; the reason names the field.
        case refused(String)
        /// Too many sends from this network lately.
        case tryLater
        case failed(status: Int)
    }

    public let endpoint: URL
    public let session: URLSession

    public init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Only a report in the Worker's format can be sent; it refuses others.
    public static func canSend(_ report: BenchmarkReport) -> Bool {
        report.format == BenchmarkReport.currentFormat
    }

    /// The report as sent: without `sentAt`, which is the phone's own note.
    public static func payload(for report: BenchmarkReport) throws -> Data {
        var sent = report
        sent.sentAt = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(sent)
    }

    /// Throws only when the Worker could not be reached.
    public func send(_ report: BenchmarkReport) async throws -> Reply {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let (data, response) = try await session.upload(
            for: request, from: Self.payload(for: report))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 201, 409:
            return .stored
        case 400:
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return .refused(body?["error"] as? String ?? "the report was refused")
        case 429:
            return .tryLater
        default:
            return .failed(status: status)
        }
    }
}

/// Takes the app's container paths out of what a run writes. A path under
/// `/var/mobile/Containers/Data/Application/<UUID>` names the install, and
/// logs and failure reasons quote such paths. The app's own home becomes
/// `~`; another install's container, which a stale receipt can name, becomes
/// `<other install>`, so a line that compared the two still reads as a
/// comparison.
public enum BenchmarkRedaction {
    public static func redact(_ text: String, home: String = NSHomeDirectory()) -> String {
        var result = text
        if home.hasPrefix("/") && home.count > 1 {
            let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
            if !trimmed.hasPrefix("/private/") {
                result = result.replacingOccurrences(of: "/private" + trimmed, with: "~")
            }
            result = result.replacingOccurrences(of: trimmed, with: "~")
        }
        return result.replacing(container, with: "<other install>")
    }

    private nonisolated(unsafe) static let container = try! Regex(
        "(?:/private)?/var/(?:mobile/)?[Cc]ontainers/"
            + "(?:Data/Application|Bundle/Application|Shared/AppGroup)/"
            + "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
}
