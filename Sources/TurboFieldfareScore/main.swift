// Research only: teacher-forced quality meter.
//
// Feeds fixed chat transcripts through the model and records, at every
// continuation position, the next-token distribution. One run with
// `--ref-out` writes the reference (the unchanged runtime); runs with `--ref`
// score a changed runtime (a lossy expert simulation or an expert-skip
// policy, both set by environment variables) against it on exactly the same
// tokens:
//
//   KL      KL(reference || run), over the reference's top 64 tokens plus one
//           bucket for the rest, in nats per token. A lower bound on the full
//           KL (merging outcomes never raises KL).
//   top1    how often the run's most likely token is the reference's
//   NLL     mean negative log-likelihood of the transcript's own next token
//
// usage: TurboFieldfareScore --model <dir> --sequences <json>
//          (--ref-out <file> | --ref <file>) [--slots 24] [--prefill-chunk 256]
//          [--max-tokens <n>] [--positions-out <file>]
//
// The sequences file is a JSON array of {"messages": [{role, content}...],
// "continuation": "<text>"}. Each continuation is scored after the messages
// are rendered with the chat template (generation prompt included). The
// end-of-turn token is not scored: most stored answers stopped at a length
// limit, not at the end of a turn.
import Foundation
import Metal
import TurboFieldfare
import TurboFieldfareCLICore

struct Sequence: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }
    let messages: [Message]
    let continuation: String
}

let topN = 64

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

var options: [String: String] = [:]
var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let flag = argv.removeFirst()
    guard flag.hasPrefix("--"), !argv.isEmpty else { fail("bad arguments near \(flag)") }
    options[String(flag.dropFirst(2))] = argv.removeFirst()
}
guard let modelPath = options["model"], let sequencesPath = options["sequences"] else {
    fail("--model and --sequences are required")
}
let refOut = options["ref-out"]
let refIn = options["ref"]
guard (refOut == nil) != (refIn == nil) else { fail("exactly one of --ref-out, --ref") }
let slots = Int(options["slots"] ?? "24") ?? 24
let chunk = Int(options["prefill-chunk"] ?? "256") ?? 256
let maxTokens = Int(options["max-tokens"] ?? "100000") ?? 100_000

/// One position of the reference file.
struct RefRecord {
    var target: Int32
    var targetLogprob: Float
    var ids: [Int32]
    var logprobs: [Float]
    static let bytes = 8 + topN * 8
}

/// log-sum-exp, argmax and top-N of FP16 logits.
func summarize(_ logits: UnsafePointer<Float16>, vocab: Int)
    -> (lse: Double, argmax: Int, top: [(Int, Float)]) {
    var maxValue = -Float.infinity
    var argmax = 0
    for i in 0..<vocab {
        let v = Float(logits[i])
        if v > maxValue { maxValue = v; argmax = i }
    }
    var sum = 0.0
    // Candidates within 30 nats of the max cover every token that can rank
    // in a top 64 worth keeping; anything lower is below e^-30.
    var candidates: [(Int, Float)] = []
    for i in 0..<vocab {
        let v = Float(logits[i])
        sum += exp(Double(v - maxValue))
        if v > maxValue - 30 { candidates.append((i, v)) }
    }
    let lse = Double(maxValue) + log(sum)
    candidates.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    let top = candidates.prefix(topN).map { ($0.0, Float(Double($0.1) - lse)) }
    return (lse, argmax, Array(top))
}

let modelURL = URL(fileURLWithPath: modelPath)
let tokenizer = try await GFTokenizer.load(forModelDirectory: modelURL)
let sequences = try JSONDecoder().decode(
    [Sequence].self, from: Data(contentsOf: URL(fileURLWithPath: sequencesPath)))

let args = Args(model: modelPath, prompt: "x", temperature: 0.2, expertCacheSlots: slots,
                prefillChunkTokens: chunk)
let runtime = try args.resolvedRuntimeConfiguration(forceLogitsHead: true)
let context = try MetalContext()
let model = try Model.load(
    directoryURL: modelURL,
    device: context.device,
    streamingMode: .pread(slotCount: runtime.expertCacheSlots),
    expertCachePolicy: runtime.modelExpertCachePolicy,
    integrityPolicy: .sizeCheckTrustedReceipt)
let maxContext = 8192
let runner = try RealForwardRunner(model: model, context: context, maxContext: maxContext,
                                   runtimeConfiguration: runtime)
let vocab = model.config.vocabSize
let scratch = try RawCompletionScratch(context: context, vocab: vocab)

let environment = ProcessInfo.processInfo.environment
let lossy = environment["TURBO_FIELDFARE_LOSSY_EXPERTS"] ?? "off"
print("# score: slots=\(slots) prefill-chunk=\(chunk) lossy=\(lossy) "
      + "skip=\(runner.expertSkipDescription ?? "off") early=\(runner.earlyExpertReadDescription)")

@MainActor func scoreAll() async throws {
    var refHandle: FileHandle?
    var refData = Data()
    var refCursor = 0
    if let refOut {
        FileManager.default.createFile(atPath: refOut, contents: nil)
        refHandle = FileHandle(forWritingAtPath: refOut)
    } else if let refIn {
        refData = try Data(contentsOf: URL(fileURLWithPath: refIn))
    }
    var positionsLines: [String] = []

    func readRef() -> RefRecord {
        precondition(refCursor + RefRecord.bytes <= refData.count, "reference file too short")
        return refData.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: refCursor)
            let target = base.loadUnaligned(as: Int32.self)
            let tl = base.loadUnaligned(fromByteOffset: 4, as: Float.self)
            var ids: [Int32] = []
            var lps: [Float] = []
            for j in 0..<topN {
                ids.append(base.loadUnaligned(fromByteOffset: 8 + j * 8, as: Int32.self))
                lps.append(base.loadUnaligned(fromByteOffset: 12 + j * 8, as: Float.self))
            }
            refCursor += RefRecord.bytes
            return RefRecord(target: target, targetLogprob: tl, ids: ids, logprobs: lps)
        }
    }

    var totals = (n: 0, kl: 0.0, top1: 0, nll: 0.0, refNll: 0.0, maxKL: 0.0)
    var io = (bytes: UInt64(0), reads: UInt64(0), early: UInt64(0), hits: UInt64(0), requests: UInt64(0),
              prefillBytes: UInt64(0))
    var forwards = 0
    var decodeSeconds = 0.0
    for (s, sequence) in sequences.enumerated() {
        let messages = try sequence.messages.map { m -> GFTokenizer.Message in
            guard let role = GFTokenizer.Role(rawValue: m.role) else { fail("role \(m.role)") }
            return GFTokenizer.Message(role: role, content: m.content)
        }
        let promptIds = tokenizer.encode(try tokenizer.applyChatTemplate(messages), addBOS: false)
        var continuationIds = tokenizer.encode(sequence.continuation, addBOS: false)
        continuationIds = Array(continuationIds.prefix(maxTokens))
        var seq = (n: 0, kl: 0.0, top1: 0, nll: 0.0)
        let run = try await scoreTeacherForced(
            runner: runner, promptIds: promptIds, continuationIds: continuationIds,
            scratch: scratch, prefillConfig: runtime.prefillConfig) { index, target, logits in
            let (lse, argmax, top) = summarize(logits, vocab: vocab)
            let targetLogprob = Float(Double(Float(logits[Int(target)])) - lse)
            if let refHandle {
                var record = Data(capacity: RefRecord.bytes)
                withUnsafeBytes(of: target.littleEndian) { record.append(contentsOf: $0) }
                withUnsafeBytes(of: targetLogprob.bitPattern.littleEndian) { record.append(contentsOf: $0) }
                for j in 0..<topN {
                    let (id, lp) = j < top.count ? top[j] : (0, -Float.infinity)
                    withUnsafeBytes(of: Int32(id).littleEndian) { record.append(contentsOf: $0) }
                    withUnsafeBytes(of: lp.bitPattern.littleEndian) { record.append(contentsOf: $0) }
                }
                refHandle.write(record)
                seq.n += 1
                seq.nll -= Double(targetLogprob)
                return
            }
            let ref = readRef()
            precondition(ref.target == target, "reference and run disagree on the tokens")
            var kl = 0.0
            var pIn = 0.0
            var qIn = 0.0
            for j in 0..<topN where ref.logprobs[j].isFinite {
                let lp = Double(ref.logprobs[j])
                let lq = Double(Float(logits[Int(ref.ids[j])])) - lse
                kl += exp(lp) * (lp - lq)
                pIn += exp(lp)
                qIn += exp(lq)
            }
            let pTail = max(0, 1 - pIn)
            let qTail = max(1e-12, 1 - qIn)
            if pTail > 0 { kl += pTail * log(pTail / qTail) }
            seq.n += 1
            seq.kl += kl
            seq.top1 += argmax == Int(ref.ids[0]) ? 1 : 0
            seq.nll -= Double(targetLogprob)
            totals.refNll -= Double(ref.targetLogprob)
            totals.maxKL = max(totals.maxKL, kl)
            positionsLines.append(String(format: "%d %d %.6f %.4f %.4f %d", s, index, kl,
                                         -targetLogprob, -ref.targetLogprob,
                                         argmax == Int(ref.ids[0]) ? 1 : 0))
        }
        io.bytes += run.decodeIO.bytesRead
        io.reads += run.decodeIO.reads
        io.early += run.decodeIO.earlyReads
        io.hits += run.decodeIO.cacheHits
        io.requests += run.decodeIO.cacheRequests
        io.prefillBytes += run.prefillIO.bytesRead
        forwards += run.decodeForwards
        decodeSeconds += run.decodeSeconds
        totals.n += seq.n
        totals.kl += seq.kl
        totals.top1 += seq.top1
        totals.nll += seq.nll
        let fgReads = Double(run.decodeIO.reads - run.decodeIO.earlyReads) / Double(max(1, run.decodeForwards))
        print(String(format: "seq %d: prompt %d tok, scored %d; KL %.5f top1 %.4f NLL %.4f; "
                     + "decode fg reads/tok %.2f, MiB/tok %.2f, %.2f s/tok",
                     s, promptIds.count, seq.n, seq.kl / Double(max(1, seq.n)),
                     Double(seq.top1) / Double(max(1, seq.n)), seq.nll / Double(max(1, seq.n)),
                     fgReads, Double(run.decodeIO.bytesRead) / 1_048_576 / Double(max(1, run.decodeForwards)),
                     run.decodeSeconds / Double(max(1, run.decodeForwards))))
    }
    let n = Double(max(1, totals.n))
    let fg = Double(io.reads - io.early) / Double(max(1, forwards))
    let early = Double(io.early) / Double(max(1, forwards))
    let hit = String(format: "%.1f%%", 100 * Double(io.hits) / Double(max(1, io.requests)))
    if refOut != nil {
        print(String(format: "reference: %d positions, NLL %.4f", totals.n, totals.nll / n))
    } else {
        print(String(format: "TOTAL: %d positions, KL %.5f (max %.3f), top1 %.4f, NLL %.4f (ref %.4f, %+.4f)",
                     totals.n, totals.kl / n, totals.maxKL, Double(totals.top1) / n,
                     totals.nll / n, totals.refNll / n, (totals.nll - totals.refNll) / n))
    }
    print(String(format: "decode: %d forwards, fg reads/tok %.2f, early reads/tok %.2f, MiB/tok %.2f, "
                 + "hit %@, %.3f s/tok; prefill MiB %.1f",
                 forwards, fg, early, Double(io.bytes) / 1_048_576 / Double(max(1, forwards)),
                 hit, decodeSeconds / Double(max(1, forwards)), Double(io.prefillBytes) / 1_048_576))
    let skip = runner.expertSkipCounts
    if skip.layerSteps > 0 {
        print(String(format: "skip: dropped/layer %.3f, dropped mass/layer %.4f, substituted/layer %.3f",
                     Double(skip.dropped) / Double(skip.layerSteps),
                     skip.droppedMass / Double(skip.layerSteps),
                     Double(skip.substituted) / Double(skip.layerSteps)))
    }
    if let path = options["positions-out"], !positionsLines.isEmpty {
        try ("# seq index kl nll refnll top1agree\n" + positionsLines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
    try refHandle?.close()
}

try await scoreAll()
