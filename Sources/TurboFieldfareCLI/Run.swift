import Foundation
import Metal
import TurboFieldfare

private struct MessageJSON: Decodable {
    let role: String
    let content: String
}

public struct RunResult: Equatable, Sendable {
    public let exitCode: Int32
    public init(exitCode: Int32) { self.exitCode = exitCode }
}

public func run(args: Args,
                stdout: FileHandle = .standardOutput,
                stderr: FileHandle = .standardError) async -> RunResult {
    do {
        let modelURL = URL(fileURLWithPath: args.model)
        let tokenizer = try await GFTokenizer.load(forModelDirectory: modelURL)
        let promptIds: [Int32]
        if let rawPrompt = args.prompt {
            promptIds = tokenizer.encode(rawPrompt, addBOS: true)
        } else if let messagesFile = args.messagesFile {
            let data = try Data(contentsOf: URL(fileURLWithPath: messagesFile),
                                options: [.mappedIfSafe])
            let rows = try JSONDecoder().decode([MessageJSON].self, from: data)
            let messages = try rows.map { row -> GFTokenizer.Message in
                guard let role = GFTokenizer.Role(rawValue: row.role) else {
                    throw GFTokenizerError.invalidChatTemplate("unsupported role \(row.role)")
                }
                return GFTokenizer.Message(role: role, content: row.content)
            }
            let rendered = try tokenizer.applyChatTemplate(messages)
            promptIds = tokenizer.encode(rendered, addBOS: false)
        } else {
            return errored(stderr, "one of --prompt or --messages-file is required", 2)
        }
        guard !promptIds.isEmpty else { return errored(stderr, "empty prompt", 2) }
        guard promptIds.count < args.maxContext else {
            return errored(
                stderr,
                "context overflow: prompt \(promptIds.count) reaches maxContext \(args.maxContext)",
                2)
        }
        let effectiveMaxNew = min(args.maxNew, args.maxContext - promptIds.count)
        let config = GenerationConfig(
            maxNewTokens: effectiveMaxNew,
            temperature: args.temperature,
            topK: args.topK,
            topP: args.topP,
            repetitionPenalty: args.repetitionPenalty,
            seed: args.seed,
            stopStrings: args.stops,
            extraStopTokens: [])
        let runtime = try args.resolvedRuntimeConfiguration(
            forceLogitsHead: !config.isPureGreedy)

        guard MTLCreateSystemDefaultDevice() != nil else {
            return errored(stderr, "no Metal device", 1)
        }
        let context = try MetalContext()
        let model = try Model.load(
            directoryURL: modelURL,
            device: context.device,
            streamingMode: .pread(slotCount: runtime.expertCacheSlots),
            expertCachePolicy: runtime.modelExpertCachePolicy,
            integrityPolicy: .fullSha256)
        let runner = try RealForwardRunner(
            model: model,
            context: context,
            maxContext: args.maxContext,
            runtimeConfiguration: runtime)
        let scratch = try RawCompletionScratch(context: context,
                                               vocab: model.config.vocabSize)
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
                case .token(_, _, let delta):
                    if !delta.isEmpty { stdout.write(Data(delta.utf8)) }
                case .tail(let tail):
                    stdout.write(Data(tail.utf8))
                }
            }

        if !args.quiet {
            let tokensPerSecond = stats.decodeSeconds > 0
                ? Double(stats.newTokens) / stats.decodeSeconds
                : 0
            let footer = "\n[stop=\(String(describing: stats.reason)) prefill=\(stats.prefillTokens)tok new=\(stats.newTokens)tok decode=\(String(format: "%.2f", stats.decodeSeconds))s tok/s=\(String(format: "%.3f", tokensPerSecond))]\n"
            stderr.write(Data(footer.utf8))
            stderr.write(Data(expertIOFooter(stats).utf8))
            stderr.write(Data(phaseTimeFooter(stats).utf8))
        }
        return RunResult(exitCode: 0)
    } catch is CancellationError {
        stdout.write(Data("\n".utf8))
        return RunResult(exitCode: 130)
    } catch {
        return errored(stderr, "\(error)", 1)
    }
}

/// Second stderr footer line carrying the routed-expert byte profile. Kept on
/// its own line so the existing timing footer stays byte-for-byte what
/// `docs/COMMUNITY_BENCHMARKS.md` tells reporters to quote.
///
/// Decode is reported per forward pass, prefill in totals: prefill reads are
/// amortized over a whole prompt in tiles and a per-token figure there would
/// invite comparison with the decode number, which is the one thing it is not.
func expertIOFooter(_ stats: RawDecodeResult) -> String {
    func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.2f", Double(bytes) / 1_048_576.0)
    }
    func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "n/a" }
        return String(format: "%.1f%%", fraction * 100)
    }
    func perForward(_ total: UInt64) -> String {
        guard stats.decodeForwards > 0 else { return "n/a" }
        return String(format: "%.2f", Double(total) / Double(stats.decodeForwards))
    }
    let decode = stats.decodeExpertIO
    let prefill = stats.prefillExpertIO
    let bytesPerToken = stats.decodeMegabytesPerToken.map { String(format: "%.2fMB", $0) } ?? "n/a"
    return "[expert-io decode bytes/tok=\(bytesPerToken)"
        + " hit-rate=\(percent(decode.cacheHitRate))"
        + " req/tok=\(perForward(decode.cacheRequests))"
        + " reads/tok=\(perForward(decode.reads))"
        + " forwards=\(stats.decodeForwards)"
        + " | prefill bytes=\(megabytes(prefill.bytesRead))MB"
        + " hit-rate=\(percent(prefill.cacheHitRate))"
        + " reads=\(prefill.reads)]\n"
}

/// Third stderr footer line: where a decode forward's time goes, in
/// milliseconds per forward, alongside the wall time of a forward so each phase
/// can be read as a fraction of it.
///
/// The six columns run in sequence within a layer, and measurement on
/// 2026-08-10 found them covering 98.2–98.5% of `wall` across all three
/// benchmark cases with a flat ~5.9 ms residual — per-token sampling, which
/// runs outside the layer loop and is not counted here. So a total over them is
/// meaningful, unlike a total over the three counters this replaced: those were
/// CPU encode cost only, and adding them described nothing.
///
/// What the marker warns about is the one genuine overlap left. `io` is the
/// wall time of the routed-expert fetch, and the resident shared-expert branch
/// executes on the GPU throughout it. That GPU work is real and is not counted
/// anywhere; `io` is the window that hides it, not idle time waiting on disk.
///
/// Decode only: the production chunked-prefill path does not drive the
/// cb1/io/cb2 handoff, so there is no prefill half to report.
func phaseTimeFooter(_ stats: RawDecodeResult) -> String {
    let forwards = stats.decodeForwards
    func perForward(_ nanos: UInt64) -> String {
        guard let ms = DecodePhaseTimings.millisecondsPerForward(nanos, forwards: forwards) else {
            return "n/a"
        }
        return String(format: "%.2f", ms)
    }
    let phases = stats.decodePhaseTimings
    let wall = forwards > 0
        ? String(format: "%.2f", stats.decodeSeconds * 1000 / Double(forwards))
        : "n/a"
    return "[phase-time decode ms/fwd cb1=\(perForward(phases.cb1Nanos))"
        + " cb1-wait=\(perForward(phases.cb1WaitNanos))"
        + " io=\(perForward(phases.ioNanos))"
        + " cb2=\(perForward(phases.cb2Nanos))"
        + " routed-drain=\(perForward(phases.routedDrainNanos))"
        + " head=\(perForward(phases.headNanos))"
        + " wall=\(wall)"
        + " forwards=\(forwards) | sequential per layer; io hides the shared-expert branch]\n"
}

private func errored(_ stderr: FileHandle, _ message: String, _ code: Int32) -> RunResult {
    stderr.write(Data("error: \(message)\n".utf8))
    return RunResult(exitCode: code)
}
