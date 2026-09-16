import CryptoKit
import Foundation
import Metal
import UIKit
import os
import TurboFieldfare

// Track A step 3: the smallest thing that can load the real model on the phone
// and generate from it. No optimization, 16 expert-cache slots, Mac parity —
// the point is a zero-loss reference on the device, which is the instrument
// Track B cannot work without.

/// Where `devicectl` pushes the model. This is the path
/// `AppModelLocation.resolve` already falls through to for a standalone app —
/// inside a bundle the package-root probe cannot match, so it lands here.
enum ModelLocation {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base
            .appendingPathComponent("TurboFieldfare", isDirectory: true)
            .appendingPathComponent("gemma4.gturbo", isDirectory: true)
    }
}

/// `phys_footprint` and the jetsam headroom, the two numbers A1 was measured in.
enum Mem {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    static func available() -> Int { os_proc_available_memory() }

    /// ⚠️ With the increased-memory-limit entitlement this overstates the real
    /// kill point by ~841 MB (measured 2026-09-16). Log it, never size against it.
    static func line() -> String {
        "footprint=\(footprint()) available=\(available())"
    }
}

/// One case of the frozen `real-generation-v1` set, pushed to the device rather
/// than copied into the app bundle. Duplicating the prompts into `iOS/` would
/// create a second copy that can drift from the canonical
/// `docs/benchmark-prompts/`, and the protocol's whole point is that everyone
/// generates from the same bytes — so the file is carried over and its SHA-256
/// is logged, making the run self-verifying against
/// `docs/COMMUNITY_BENCHMARKS.md`.
enum PromptCase {
    struct MessageJSON: Decodable {
        let role: String
        let content: String
    }

    static func directory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("prompts", isDirectory: true)
    }

    /// Returns the decoded messages and the file's SHA-256, so the log records
    /// which frozen bytes produced the number.
    static func load(_ caseID: String) throws -> (messages: [GFTokenizer.Message], sha256: String) {
        let url = directory().appendingPathComponent("\(caseID).json")
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let decoded = try JSONDecoder().decode([MessageJSON].self, from: data)
        let messages: [GFTokenizer.Message] = try decoded.map {
            guard let role = GFTokenizer.Role(rawValue: $0.role) else {
                throw HarnessError.badPromptCase("unknown role \($0.role) in \(caseID).json")
            }
            return GFTokenizer.Message(role: role, content: $0.content)
        }
        return (messages, digest)
    }
}

/// The device conditions that make one run incomparable with another. The A1
/// and B1 probes logged thermal state and battery beside every point for this
/// reason; a decode run needs them on the same grounds. Free space is here
/// because `devicectl` reports total capacity only, and the model is ~14.3 GB.
enum DeviceState {
    /// Queried against `Documents`, which exists from first launch. Asking
    /// `Application Support` returned nil in a fresh container — the directory
    /// is not created until something writes there — and the harness logged a
    /// useless `free=-1`. The figure is volume-wide, so any existing URL on it
    /// gives the same answer.
    static func freeSpaceBytes() -> Int64 {
        let url = FileManager.default.urls(for: .documentDirectory,
                                           in: .userDomainMask)[0]
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? -1
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func battery() -> String {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = Int((UIDevice.current.batteryLevel * 100).rounded())
        switch UIDevice.current.batteryState {
        case .charging: return "\(level)%/charging"
        case .full: return "\(level)%/full"
        case .unplugged: return "\(level)%/unplugged"
        default: return "\(level)%/unknown"
        }
    }
}

struct HarnessSettings {
    /// The benchmark protocol passes `--max-context 4096` explicitly, so the
    /// measured rows are 4K regardless of the 8K CLI default.
    var maxContext = 4096
    var maxNewTokens = 128
    /// The platform's production default, **not** a literal. Since 2026-09-16
    /// that is 32 on iOS, measured at +59 / +56 / +34% over 16. Hardcoding 16
    /// here would silently override the shared constant and hold every device
    /// run at the old value while the runtime claimed otherwise — which is
    /// exactly the drift the constant exists to prevent.
    var expertCacheSlots = RuntimeConfiguration.productionExpertCacheSlots
    var temperature: Float = 0.2
    var topK = 64
    var topP: Float = 0.95
    var seed: UInt64 = 1
    var label = "run"
    /// A `real-generation-v1` case id — `short-explanation`, `medium-review` or
    /// `long-synthesis`. When set, the prompt comes from the pushed file and
    /// `prompt` is ignored, which is the only way to produce a row that can sit
    /// beside a Mac row.
    var caseID: String?
    var prompt = "Explain what a mixture-of-experts language model is, and why "
        + "streaming experts from storage changes the engineering problem."
    /// Prompt tokens per chunked-prefill step; allowed values are 32, 64, 128,
    /// 256. Chunks loop *outside* layers, so each one re-reads that layer's
    /// routed experts, which is why prefill runs at a 0.0% cache hit rate and
    /// why halving the chunk count helps.
    ///
    /// ⚠️ Chunk count is the **dominant** term, not the only one: per-chunk
    /// read volume also grows with chunk size (6,341 → 7,659 MiB/chunk on the
    /// medium case), because a wider chunk routes to more distinct experts. So
    /// doubling the size does not halve the bytes — measured −39.6% and −43.2%,
    /// not −50%. An earlier version of this comment said read volume "tracks
    /// chunk count and nothing else"; that was falsified on 2026-09-16.
    ///
    /// Unset means `auto`, resolved against the prompt length once it is known.
    var prefillChunkTokens = 128
    /// Whether `--prefill-chunk-tokens` was actually passed. Needed because the
    /// default is indistinguishable from an explicit `128` otherwise, and
    /// `--prefill-chunk-tokens 128` must pin 128 rather than silently becoming
    /// `auto`.
    var prefillChunkExplicit = false

    static func fromLaunchArguments() -> HarnessSettings {
        var settings = HarnessSettings()
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if let v = value("--label") { settings.label = v }
        if let v = value("--case") { settings.caseID = v }
        if let v = value("--prompt") { settings.prompt = v }
        if let v = value("--max-new").flatMap(Int.init) { settings.maxNewTokens = v }
        if let v = value("--max-context").flatMap(Int.init) { settings.maxContext = v }
        if let v = value("--slots").flatMap(Int.init) { settings.expertCacheSlots = v }
        if let v = value("--prefill-chunk-tokens").flatMap(Int.init) {
            settings.prefillChunkTokens = v
            settings.prefillChunkExplicit = true
        }
        return settings
    }
}

/// One fsynced line per event. A run that ends in a jetsam kill leaves no
/// return value and no console, so the log has to be durable at every step —
/// the same reason the A1 probe fsynced. The last line written is the evidence.
final class RunLog {
    private let handle: FileHandle?
    private let started = DispatchTime.now().uptimeNanoseconds
    private var seq = 0

    let url: URL

    init(label: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]
        url = documents.appendingPathComponent("decode-\(label)-\(stamp).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    @discardableResult
    func write(_ event: String, _ detail: String = "") -> String {
        seq += 1
        let ms = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let line = "\(seq), \(ms), \(event), \(Mem.line())\(detail.isEmpty ? "" : ", " + detail)"
        if let handle, let data = (line + "\n").data(using: .utf8) {
            handle.write(data)
            fsync(handle.fileDescriptor)
        }
        return line
    }
}

enum HarnessError: LocalizedError {
    case noMetalDevice
    case modelMissing(String)
    case tokenizerMissing(String)
    case badPromptCase(String)
    case badSetting(String)

    var errorDescription: String? {
        switch self {
        case .noMetalDevice:
            return "no Metal device"
        case .modelMissing(let path):
            return "no model at \(path) — push one with `devicectl device copy to`"
        case .tokenizerMissing(let path):
            return "no tokenizer sidecar under \(path)"
        case .badPromptCase(let detail):
            return "prompt case unusable: \(detail)"
        case .badSetting(let detail):
            return "unsupported setting: \(detail)"
        }
    }
}

@MainActor
final class Harness: ObservableObject {
    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false

    private var log: RunLog?

    private func emit(_ event: String, _ detail: String = "") {
        let line = log?.write(event, detail) ?? "\(event) \(detail)"
        lines.append(line)
    }

    func run(settings: HarnessSettings = .fromLaunchArguments()) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let log = RunLog(label: settings.label)
        self.log = log
        emit("start", "os=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
            + " free=\(DeviceState.freeSpaceBytes())"
            + " thermal=\(DeviceState.thermal()) battery=\(DeviceState.battery())")

        do {
            try await generate(settings: settings)
        } catch {
            // `ModelError` is `CustomStringConvertible` but not `LocalizedError`,
            // so `localizedDescription` renders it as an opaque
            // "ModelError error 11" and discards the detail the enum already
            // carries. Log the real description first; keep the localized one
            // for error types that do supply a useful string.
            emit("failed", "\(String(describing: error)) | \(error.localizedDescription)")
        }
    }

    private func generate(settings: HarnessSettings) async throws {
        // Metal comes first, deliberately, and before any check that can fail.
        // `MetalContext.init` compiles all 14 shader modules from source at
        // startup via `Bundle.module`, and whether that resolves inside an app
        // bundle is the one runtime risk that can be retired without the model
        // being present. Ordering the model check ahead of it meant a phone
        // with no model told us nothing at all.
        guard let device = MetalContext.makeSystemDefaultDevice() else {
            throw HarnessError.noMetalDevice
        }
        emit("metal-device", "name=\(device.name) apple10=\(device.supportsFamily(.apple10))")
        let shaderStart = DispatchTime.now().uptimeNanoseconds
        let context = try MetalContext()
        emit("shaders-compiled",
             "ms=\((DispatchTime.now().uptimeNanoseconds - shaderStart) / 1_000_000)")

        let modelURL = ModelLocation.directory
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw HarnessError.modelMissing(modelURL.path)
        }
        emit("model-found", modelURL.path)

        // Resolved explicitly rather than through `load(forModelDirectory:)`,
        // whose fallback is a network fetch from the Hub. On a phone that would
        // turn a missing sidecar into a silent download instead of an error.
        guard let tokenizerFolder = GFTokenizer.tokenizerFolder(forModelDirectory: modelURL) else {
            throw HarnessError.tokenizerMissing(modelURL.path)
        }
        let tokenizer = try await GFTokenizer.load(from: tokenizerFolder)
        emit("tokenizer-loaded")

        // Hoisted above the runtime configuration, because that is what `auto`
        // needs: `autoChunkTokens` picks the smallest allowed chunk covering the
        // prompt, so the token count must exist before the config is built.
        // `Run.swift` orders the CLI the same way. Encoding depends only on the
        // tokenizer, so moving it up is safe. The one visible consequence is
        // that `prompt-encoded` now precedes `model-loaded`, so its footprint
        // reading no longer includes the model; the run-matrix script greps
        // events by name rather than by order, so parsing is unaffected.
        //
        // A `real-generation-v1` case when one is named, so the row can sit
        // beside a Mac row; the ad-hoc prompt otherwise, which cannot. The
        // SHA-256 goes in the log so the run proves which frozen bytes it used.
        let promptIds: [Int32]
        if let caseID = settings.caseID {
            let loaded = try PromptCase.load(caseID)
            promptIds = tokenizer.encode(
                try tokenizer.applyChatTemplate(loaded.messages), addBOS: false)
            emit("prompt-encoded", "case=\(caseID) sha256=\(loaded.sha256) "
                + "messages=\(loaded.messages.count) tokens=\(promptIds.count)")
        } else {
            promptIds = tokenizer.encode(
                try tokenizer.applyChatTemplate([.init(role: .user, content: settings.prompt)]),
                addBOS: false)
            emit("prompt-encoded", "case=ad-hoc-NOT-COMPARABLE tokens=\(promptIds.count)")
        }

        // `settings` is a `let` parameter, so the resolved size is a local
        // rather than a mutation.
        let resolvedChunkTokens = settings.prefillChunkExplicit
            ? settings.prefillChunkTokens
            : PrefillRuntimeConfig.autoChunkTokens(promptTokens: promptIds.count)
        if !settings.prefillChunkExplicit {
            emit("prefill-chunk-auto",
                 "resolved=\(resolvedChunkTokens) for \(promptIds.count) prompt tokens")
        }

        let config = GenerationConfig(
            maxNewTokens: settings.maxNewTokens,
            temperature: settings.temperature,
            topK: settings.topK,
            topP: settings.topP,
            seed: settings.seed)
        // `RuntimeConfiguration.init` enforces both of these with a
        // `precondition`, which **traps** rather than throwing — and a trap
        // writes no log line at all, so the run would simply vanish with no
        // evidence of why. Refuse an unsupported value here instead, where the
        // failure can be logged.
        guard RuntimeConfiguration.allowedExpertCacheSlots
            .contains(settings.expertCacheSlots) else {
            throw HarnessError.badSetting("slots \(settings.expertCacheSlots) not in "
                + "\(RuntimeConfiguration.allowedExpertCacheSlots)")
        }
        guard RuntimeConfiguration.allowedPrefillChunkTokens
            .contains(resolvedChunkTokens) else {
            throw HarnessError.badSetting("prefill chunk \(resolvedChunkTokens) "
                + "not in \(RuntimeConfiguration.allowedPrefillChunkTokens)")
        }
        let runtime = RuntimeConfiguration(
            expertCacheSlots: settings.expertCacheSlots,
            prefillChunkTokens: resolvedChunkTokens,
            // A sampling config cannot use the fused head's GPU argmax.
            forceLogitsHead: !config.isPureGreedy)

        // `.fullSha256` verifies each 410 MiB layer file on its first routed
        // touch, landing that cost inside the `io` phase it is meant to
        // measure, so the receipt is preferred wherever it is usable.
        //
        // On iOS it currently never is. `validateManifestBinding` compares
        // `receipt.modelDirectoryPath` against the live directory, and a
        // side-loaded artifact still carries the Mac path it was verified at.
        // The deeper problem is that an app's container UUID changes on every
        // install — observed across three installs on 2026-09-16 — so even a
        // receipt regenerated on the device would be void after the next one.
        // An absolute-path binding cannot hold on iOS.
        //
        // Detect that instead of hashing silently, and say what it costs: a run
        // that falls back here has SHA-256 of 12.01 GiB smeared through its
        // `io` figures, so its timings are NOT comparable with MEASUREMENTS.md.
        var integrityPolicy: ModelIntegrityPolicy = .fullSha256
        do {
            let receipt = try VerifiedInstallReceiptReader.load(directoryURL: modelURL)
            let actualPath = modelURL.standardizedFileURL.path
            if receipt.modelDirectoryPath == actualPath {
                integrityPolicy = .sizeCheckTrustedReceipt
            } else {
                emit("receipt-path-mismatch",
                     "receipt names \(receipt.modelDirectoryPath) but the model is at "
                        + "\(actualPath) — falling back to fullSha256, so io timings "
                        + "from this run are contaminated")
            }
        } catch {
            emit("no-install-receipt", "\(String(describing: error)) — falling back to "
                + "fullSha256, so io timings from this run are contaminated")
        }
        let loadStarted = DispatchTime.now().uptimeNanoseconds
        let model = try Model.load(
            directoryURL: modelURL,
            device: context.device,
            streamingMode: .pread(slotCount: runtime.expertCacheSlots),
            expertCachePolicy: runtime.modelExpertCachePolicy,
            integrityPolicy: integrityPolicy)
        emit("model-loaded",
             "policy=\(integrityPolicy == .fullSha256 ? "fullSha256" : "trustedReceipt") "
                + "ms=\((DispatchTime.now().uptimeNanoseconds - loadStarted) / 1_000_000)")

        let runner = try RealForwardRunner(
            model: model,
            context: context,
            maxContext: settings.maxContext,
            runtimeConfiguration: runtime)
        let scratch = try RawCompletionScratch(context: context, vocab: model.config.vocabSize)
        // Both knobs go in the log, not just the launch label. The slot matrix
        // relied on labels alone to tell configurations apart; with two knobs
        // varying, a log that does not state its own configuration is one
        // mislabelled run away from a wrong conclusion.
        // Both knobs plus where the chunk size came from. A log that does not
        // state its own configuration is one mislabelled run away from a wrong
        // conclusion, and with `auto` in play the size is no longer inferable
        // from the launch arguments alone.
        emit("runner-ready", "slots=\(runtime.expertCacheSlots) "
            + "prefillChunk=\(runtime.prefillChunkTokens) "
            + "prefillChunkSource=\(settings.prefillChunkExplicit ? "explicit" : "auto") "
            + "prefill=\(runtime.prefillPolicy.rawValue)")

        var text = ""
        let stats = try await runRawCompletion(
            producer: runner,
            tokenizer: tokenizer,
            promptIds: promptIds,
            config: config,
            context: context,
            scratch: scratch,
            prefillConfig: runtime.prefillConfig) { progress in
                switch progress {
                case .prefill:
                    break
                case .token(let index, _, let delta):
                    text += delta
                    // Footprint every 16 tokens: the jetsam-survival evidence
                    // Track A's definition of done asks for. Thermal comes with
                    // it because a protocol run is minutes long and B1 reached
                    // `fair` — sampling only at start would hide a mid-run slide
                    // that makes the phases incomparable within the same run.
                    if index % 16 == 0 {
                        _ = self.log?.write("token", "index=\(index) "
                            + "thermal=\(DeviceState.thermal()) "
                            + "battery=\(DeviceState.battery())")
                    }
                case .tail(let tail):
                    text += tail
                }
            }

        let tokensPerSecond = stats.decodeSeconds > 0
            ? Double(stats.newTokens) / stats.decodeSeconds
            : 0
        emit("done", "[stop=\(String(describing: stats.reason)) "
            + "prefill=\(stats.prefillTokens)tok new=\(stats.newTokens)tok "
            + "decode=\(String(format: "%.2f", stats.decodeSeconds))s "
            + "tok/s=\(String(format: "%.3f", tokensPerSecond))]")
        emit("expert-io", expertIOFooter(stats))
        emit("phase-time", phaseTimeFooter(stats))
        lines.append("--- generated ---")
        lines.append(text)
    }
}
