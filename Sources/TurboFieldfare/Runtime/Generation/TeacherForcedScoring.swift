import Foundation
import Metal

/// What one teacher-forced pass cost.
package struct TeacherForcedRun: Sendable {
    package let prefillIO: ExpertIOStats
    package let decodeIO: ExpertIOStats
    package let decodeForwards: Int
    package let prefillSeconds: Double
    package let decodeSeconds: Double
}

/// Research only: runs `promptIds` through the production prefill, then feeds
/// `continuationIds` one decode forward at a time regardless of what the model
/// would have sampled, and hands `visit` the logits that predict each
/// continuation token. `visit(0, …)` sees the prefill's logits, which predict
/// the first continuation token.
///
/// It exists to compare a changed runtime against an unchanged one on exactly
/// the same tokens, so the comparison measures the change and not a divergent
/// generation. The runner must have a logits head (`forceLogitsHead`).
nonisolated(nonsending) package func scoreTeacherForced(
    runner: RealForwardRunner,
    promptIds: [Int32],
    continuationIds: [Int32],
    scratch: RawCompletionScratch,
    prefillConfig: PrefillRuntimeConfig,
    visit: (_ index: Int, _ target: Int32, _ logits: UnsafePointer<Float16>) throws -> Void
) async throws -> TeacherForcedRun {
    precondition(!runner.usesFusedGreedyHead, "teacher forcing needs a logits head")
    precondition(!continuationIds.isEmpty)
    let atPrefill = runner.expertIOStats
    let prefill = try await runRawPrefill(
        producer: runner,
        promptIds: promptIds,
        multimodalInput: nil,
        prefillConfig: prefillConfig,
        start: .reset,
        outputMode: .logits,
        seedUse: .decode(isPureGreedy: false),
        historyReserve: promptIds.count + continuationIds.count,
        scratch: scratch,
        onProgress: { _ in })
    let logits = UnsafePointer(scratch.logits.contents().assumingMemoryBound(to: Float16.self))
    let atDecode = runner.expertIOStats
    let decodeStart = Date()
    try visit(0, continuationIds[0], logits)
    var position = prefill.position
    for index in 1..<continuationIds.count {
        try Task.checkCancellation()
        try await runner.produce(token: continuationIds[index - 1], position: position,
                                 into: scratch.logits)
        position += 1
        try visit(index, continuationIds[index], logits)
    }
    let atEnd = runner.expertIOStats
    return TeacherForcedRun(
        prefillIO: atDecode.delta(since: atPrefill),
        decodeIO: atEnd.delta(since: atDecode),
        decodeForwards: continuationIds.count - 1,
        prefillSeconds: prefill.prefillSeconds,
        decodeSeconds: Date().timeIntervalSince(decodeStart))
}
