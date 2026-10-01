import Foundation
import Metal
import TurboFieldfare

/// One row of the `--messages-file` JSON.
private struct MessageJSON: Decodable {
    let role: String
    let content: MessageContentJSON
}

private enum MessageContentJSON: Decodable {
    case text(String)
    case parts([MessagePartJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .parts(try container.decode([MessagePartJSON].self))
        }
    }
}

private struct MessagePartJSON: Decodable {
    let type: String
    let text: String?
    let path: String?
}

enum PromptInput {
    case raw(String)
    case messages([GFTokenizer.Message])
    case multimodal(messages: [MultimodalMessage], images: [UUID: URL])

    /// Whether this prompt carries images. `--messages-file` reaches the image
    /// path with `args.images` empty, so the runtime checks that depend on
    /// images ask the parsed input, not the flag list.
    var hasImages: Bool {
        if case .multimodal = self { return true }
        return false
    }
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
        let input = try parseInput(args: args)
        var selectedDevice: MTLDevice?
        if input.hasImages {
            guard let device = MetalContext.makeSystemDefaultDevice() else {
                return errored(stderr, "no Metal device", 1)
            }
            try VisionRuntime.requireSupportedDevice(device)
            selectedDevice = device
        }
        let tokenizer = try await GFTokenizer.load(forModelDirectory: modelURL)
        var promptIds: [Int32]
        var multimodalMessages: [MultimodalMessage]?
        var imageURLs: [UUID: URL] = [:]
        switch input {
        case .raw(let text):
            multimodalMessages = nil
            promptIds = tokenizer.encode(text, addBOS: true)
        case .messages(let messages):
            multimodalMessages = nil
            promptIds = tokenizer.encode(
                try tokenizer.applyChatTemplate(messages), addBOS: false)
        case .multimodal(let messages, let images):
            multimodalMessages = messages
            imageURLs = images
            // Filled in after the tower runs; the renderer needs the projected
            // features to lay out the placeholder spans.
            promptIds = []
        }
        if multimodalMessages == nil {
            guard !promptIds.isEmpty else { return errored(stderr, "empty prompt", 2) }
        }
        guard multimodalMessages != nil || promptIds.count < args.maxContext else {
            return errored(
                stderr,
                "context overflow: prompt \(promptIds.count) reaches maxContext \(args.maxContext)",
                2)
        }
        func makeConfig(maxNewTokens: Int) -> GenerationConfig {
            GenerationConfig(
                maxNewTokens: maxNewTokens,
                temperature: args.temperature,
                topK: args.topK,
                topP: args.topP,
                repetitionPenalty: args.repetitionPenalty,
                seed: args.seed,
                stopStrings: args.stops,
                extraStopTokens: [])
        }
        // Hoisted above the `auto` estimate, which needs a device to read image
        // geometry. Planning never touches the GPU, but building the plan does
        // need the device the run will use.
        guard let device = selectedDevice ?? MetalContext.makeSystemDefaultDevice() else {
            return errored(stderr, "no Metal device", 1)
        }

        var effectiveArgs = args
        if args.resolvesPrefillChunkAuto {
            let promptTokens = try estimatedPromptTokens(
                input: input, tokenizer: tokenizer, device: device)
            effectiveArgs.prefillChunkTokens =
                PrefillRuntimeConfig.autoChunkTokens(promptTokens: promptTokens)
            if !args.quiet {
                let line = "[prefill chunk auto: "
                    + "\(effectiveArgs.prefillChunkTokens) tokens for a "
                    + "\(promptTokens)-token prompt]\n"
                stderr.write(Data(line.utf8))
            }
        }
        let args = effectiveArgs
        let runtime = try args.resolvedRuntimeConfiguration(
            forceLogitsHead: !makeConfig(maxNewTokens: args.maxNew).isPureGreedy,
            imagePrompt: input.hasImages)

        if !args.quiet,
           let notice = prefillCoercionNotice(
            hasImages: input.hasImages, config: runtime.prefillConfig) {
            stderr.write(Data((notice + "\n").utf8))
        }

        // An image prompt that cannot fit is decided by geometry, so decide it
        // before spending a model load and a GPU encode on it. The plan reads
        // metadata only, and the same plan is reused at encode time so each
        // image is opened and parsed once.
        var imagePlans: [UUID: VisionImagePlan] = [:]
        if let multimodalMessages {
            // Dictionary order depends on a per-process hash seed, so planning
            // straight from `imageURLs` named a different image on each run when
            // two were bad. The prompt's own part order is the stable one.
            let ordered = orderedImageIDs(messages: multimodalMessages, images: imageURLs)
            // The device from the guard above, not a fresh `MetalContext`:
            // building one compiles every shader module, and planning never
            // touches the GPU.
            let preprocessor = Gemma4ImagePreprocessor(device: device, config: VisionConfig())
            var projected = 0
            for id in ordered {
                guard let url = imageURLs[id] else { continue }
                let plan = try preprocessor.plan(fileURL: url)
                imagePlans[id] = plan
                projected += plan.geometry.softTokenCount
                    + VisionImageTokenBudget.markerTokensPerImage
            }
            // The text counts too. The tokenizer is already loaded, so this is
            // free and it closes the common case: a prompt whose text overflows
            // used to be refused only after the pack opened and every image had
            // been encoded. A lower bound - the template's framing tokens are
            // not counted - so it can only refuse what could never fit.
            for message in multimodalMessages {
                for part in message.content {
                    if case .text(let text) = part {
                        projected += tokenizer.encode(text, addBOS: false).count
                    }
                }
            }
            guard projected < args.maxContext else {
                return errored(
                    stderr,
                    "context overflow: prompt needs at least \(projected) tokens, "
                        + "which reaches maxContext \(args.maxContext)",
                    2)
            }
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
        let multimodalInput: MultimodalPrefillInput?
        if let multimodalMessages {
            let vision = try VisionRuntime.open(
                textModelURL: modelURL,
                context: context,
                visionPackURL: args.visionPack.map { URL(fileURLWithPath: $0) })
            var features: [UUID: VisionFeatures] = [:]
            features.reserveCapacity(imageURLs.count)
            let visionStarted = ContinuousClock.now
            for id in orderedImageIDs(messages: multimodalMessages, images: imageURLs) {
                guard let url = imageURLs[id] else { continue }
                try Task.checkCancellation()
                if let plan = imagePlans[id] {
                    features[id] = try vision.encodeImage(
                        plan: plan,
                        languageModel: model,
                        residencyPolicy: args.visionResidency,
                        checkCancellation: { try Task.checkCancellation() })
                } else {
                    features[id] = try vision.encodeImage(
                        at: url,
                        languageModel: model,
                        residencyPolicy: args.visionResidency,
                        checkCancellation: { try Task.checkCancellation() })
                }
            }
            if !args.quiet {
                let duration = visionStarted.duration(to: .now)
                let seconds = Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1e18
                stderr.write(Data(
                    "[vision images=\(imageURLs.count) encode=\(String(format: "%.3f", seconds))s]\n".utf8))
            }
            let rendered = try MultimodalPromptRenderer.render(
                messages: multimodalMessages,
                featuresByID: features,
                tokenizer: tokenizer)
            promptIds = rendered.effectiveTokenIDs
            multimodalInput = rendered
            guard promptIds.count < args.maxContext else {
                return errored(
                    stderr,
                    "context overflow: prompt \(promptIds.count) reaches maxContext \(args.maxContext)",
                    2)
            }
        } else {
            multimodalInput = nil
        }
        let effectiveMaxNew = min(args.maxNew, args.maxContext - promptIds.count)
        let config = makeConfig(maxNewTokens: effectiveMaxNew)

        let stats = try await runRawCompletion(
            producer: runner,
            tokenizer: tokenizer,
            promptIds: promptIds,
            multimodalInput: multimodalInput,
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
            stderr.write(Data(gpuTimeFooter(stats).utf8))
            stderr.write(Data(readLatencyFooter(stats).utf8))
        }
        return RunResult(exitCode: 0)
    } catch let error as ArgsError {
        return errored(stderr, "\(error)", 2)
    } catch let error as VisionImageError {
        return errored(stderr, "\(error)", 3)
    } catch let error as VisionPackError {
        return errored(stderr, "\(error)", 4)
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

/// Fourth stderr footer line: GPU execution per decode forward, read from each
/// command buffer's own timestamps after it finished.
///
/// It answers what `[phase-time …]` cannot. `cb1-wait` is how long the CPU
/// blocked, and the GPU spends part of that finishing the previous layer's
/// routed experts, which the runner queues without waiting on. Here each
/// command buffer is charged separately: `cb1` is attention and the router
/// alone, and `hit-experts` plus `routed` is the expert work. The parts can
/// overlap on the GPU, so they are not summed; `busy` is their union, and
/// `idle` is `wall − busy`, the time per forward the GPU had nothing to run.
///
/// Decode only, like `[phase-time …]`.
func gpuTimeFooter(_ stats: RawDecodeResult) -> String {
    let forwards = stats.decodeForwards
    let phases = stats.decodePhaseTimings
    func perForward(_ nanos: UInt64) -> String {
        guard let ms = DecodePhaseTimings.millisecondsPerForward(nanos, forwards: forwards) else {
            return "n/a"
        }
        return String(format: "%.2f", ms)
    }
    let wallMs = forwards > 0 ? stats.decodeSeconds * 1000 / Double(forwards) : nil
    let busyMs = DecodePhaseTimings.millisecondsPerForward(phases.gpuBusyNanos, forwards: forwards)
    let idle = wallMs.flatMap { wall in busyMs.map { String(format: "%.2f", wall - $0) } } ?? "n/a"
    let wall = wallMs.map { String(format: "%.2f", $0) } ?? "n/a"
    return "[gpu-time decode ms/fwd embed=\(perForward(phases.gpuEmbedNanos))"
        + " cb1=\(perForward(phases.gpuCb1Nanos))"
        + " shared=\(perForward(phases.gpuSharedNanos))"
        + " hit-experts=\(perForward(phases.gpuHitExpertsNanos))"
        + " routed=\(perForward(phases.gpuRoutedNanos))"
        + " head=\(perForward(phases.gpuHeadNanos))"
        + " busy=\(perForward(phases.gpuBusyNanos))"
        + " idle=\(idle)"
        + " wall=\(wall)"
        + " forwards=\(forwards) | command-buffer timestamps; parts may overlap, busy is their union]\n"
}

/// Fifth stderr footer line: how long each routed-expert read took, decode and
/// prefill separately, as the share of reads in each latency bucket.
///
/// A read the OS serves from its file cache takes a few hundred microseconds
/// for an expert; one that goes to storage takes about two milliseconds. So
/// the low buckets count misses that cost no storage time, which no byte
/// counter can see. Shares are of reads in the window, and the mean is of one
/// read's own duration — reads within a layer run concurrently, so it is not
/// `io` divided by reads.
func readLatencyFooter(_ stats: RawDecodeResult) -> String {
    func bound(_ micros: UInt64) -> String {
        String(format: "%g", Double(micros) / 1000.0)
    }
    func describe(_ io: ExpertIOStats) -> String {
        let bounds = ExpertIOStats.readLatencyBucketBoundsMicros
        let total = io.timedReads
        let mean = io.meanReadLatencyMilliseconds.map { String(format: "%.2fms", $0) } ?? "n/a"
        var parts = ["reads=\(total)", "mean=\(mean)"]
        for (index, count) in io.readLatencyBuckets.enumerated() {
            let label: String
            if index == 0 {
                label = "<\(bound(bounds[0]))ms"
            } else if index < bounds.count {
                label = "\(bound(bounds[index - 1]))-\(bound(bounds[index]))ms"
            } else {
                label = ">=\(bound(bounds[bounds.count - 1]))ms"
            }
            let share = total > 0
                ? String(format: "%.1f%%", Double(count) / Double(total) * 100)
                : "n/a"
            parts.append("\(label)=\(share)")
        }
        return parts.joined(separator: " ")
    }
    return "[read-latency decode \(describe(stats.decodeExpertIO))"
        + " | prefill \(describe(stats.prefillExpertIO))]\n"
}

/// The order the messages reference their images, so a repeated command plans
/// and encodes them the same way every run.
func orderedImageIDs(messages: [MultimodalMessage],
                     images: [UUID: URL]) -> [UUID] {
    var ordered: [UUID] = []
    var seen: Set<UUID> = []
    for message in messages {
        for part in message.content {
            if case .image(let id) = part, images[id] != nil, seen.insert(id).inserted {
                ordered.append(id)
            }
        }
    }
    for id in images.keys.sorted(by: { $0.uuidString < $1.uuidString })
    where !seen.contains(id) {
        ordered.append(id)
    }
    return ordered
}

/// The line to print when an image prompt overrides the requested prefill mode.
///
/// The override itself happens deep in `RawCompletion`, silently, while
/// `RUNTIME_CONTROLS.md` says `--prefill off` disables that path. A flag that is
/// ignored without a word is worse than one that is refused, so the CLI says it
/// before the model loads.

/// A prompt-length estimate good enough to choose a chunk size.
///
/// Deliberately cheap: it tokenises text and reads image geometry, and never
/// loads the model. Being a little low only costs one extra chunk.
func estimatedPromptTokens(
    input: PromptInput,
    tokenizer: GFTokenizer,
    device: MTLDevice
) throws -> Int {
    switch input {
    case .raw(let text):
        return tokenizer.encode(text, addBOS: true).count
    case .messages(let messages):
        return tokenizer.encode(try tokenizer.applyChatTemplate(messages),
                                addBOS: false).count
    case .multimodal(let messages, let images):
        var total = 0
        for message in messages {
            for part in message.content {
                if case .text(let text) = part {
                    total += tokenizer.encode(text, addBOS: false).count
                }
            }
        }
        let preprocessor = Gemma4ImagePreprocessor(
            device: device, config: VisionConfig())
        for url in images.values {
            // Not `try?`: an image that cannot be planned would count as zero
            // soft tokens, so `auto` would size the chunk for the text alone and
            // put the multimodal prompt back on the many-chunk path this flag
            // exists to avoid. An unplannable image fails the run anyway, and
            // failing here says why, before the load.
            total += try preprocessor.plan(fileURL: url).geometry.softTokenCount
            total += VisionImageTokenBudget.markerTokensPerImage
        }
        return total
    }
}

func prefillCoercionNotice(
    hasImages: Bool, config: PrefillRuntimeConfig
) -> String? {
    guard hasImages, config.coercedForImagePrompt() != nil else { return nil }
    return "[prefill coerced to chunked: image prompts require it]"
}

func parseInput(args: Args) throws -> PromptInput {
    if let prompt = args.prompt {
        return .raw(prompt)
    }
    if let chatPrompt = args.chatPrompt {
        guard !args.images.isEmpty else {
            return .messages([GFTokenizer.Message(role: .user, content: chatPrompt)])
        }
        var images: [UUID: URL] = [:]
        var content: [MultimodalContentPart] = []
        for path in args.images {
            let id = UUID()
            images[id] = URL(fileURLWithPath: path)
            content.append(.image(id: id))
        }
        if !chatPrompt.isEmpty { content.append(.text(chatPrompt)) }
        return .multimodal(
            messages: [MultimodalMessage(role: .user, content: content)],
            images: images)
    }
    guard let path = args.messagesFile else {
        throw ArgsError.modeMissing
    }
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let rows = try JSONDecoder().decode([MessageJSON].self, from: data)
    let base = url.deletingLastPathComponent()
    var images: [UUID: URL] = [:]
    let messages: [MultimodalMessage] = try rows.map { row in
        guard let role = GFTokenizer.Role(rawValue: row.role) else {
            throw ArgsError.invalidValue(flag: "--messages-file", value: "unknown role: \(row.role)")
        }
        let parts: [MultimodalContentPart]
        switch row.content {
        case .text(let text):
            parts = [.text(text)]
        case .parts(let rows):
            parts = try rows.map { part in
                switch part.type {
                case "text":
                    guard let text = part.text else {
                        throw ArgsError.invalidValue(
                            flag: "--messages-file", value: "text part is missing text")
                    }
                    return .text(text)
                case "image_file":
                    guard role == .user, let path = part.path else {
                        throw ArgsError.invalidValue(
                            flag: "--messages-file", value: "image_file requires a user role and path")
                    }
                    let id = UUID()
                    // Test the string, not a URL: `URL(fileURLWithPath:)`
                    // resolves against the process directory, so its `path` is
                    // always absolute and the relative branch never ran. A
                    // relative path belongs to the messages file's directory.
                    images[id] = path.hasPrefix("/")
                        ? URL(fileURLWithPath: path)
                        : base.appendingPathComponent(path)
                    return .image(id: id)
                default:
                    throw ArgsError.invalidValue(
                        flag: "--messages-file", value: "unknown content type: \(part.type)")
                }
            }
        }
        return MultimodalMessage(role: role, content: parts)
    }
    if images.isEmpty {
        return .messages(messages.map { message in
            GFTokenizer.Message(
                role: message.role,
                content: message.content.compactMap {
                    if case .text(let text) = $0 { text } else { nil }
                }.joined())
        })
    }
    return .multimodal(messages: messages, images: images)
}

/// An image prompt's token count follows from geometry, so an oversized one can
/// be refused in milliseconds instead of after a model load and a GPU encode.
func validatePromptSize(
    tokens: Int,
    args: Args,
    stderr: FileHandle
) -> RunResult? {
    guard tokens + args.maxNew <= args.maxContext else {
        return errored(
            stderr,
            "context overflow: prompt \(tokens) + maxNew \(args.maxNew) exceeds maxContext \(args.maxContext)",
            2)
    }
    return nil
}

private func errored(_ stderr: FileHandle, _ message: String, _ code: Int32) -> RunResult {
    stderr.write(Data("error: \(message)\n".utf8))
    return RunResult(exitCode: code)
}
