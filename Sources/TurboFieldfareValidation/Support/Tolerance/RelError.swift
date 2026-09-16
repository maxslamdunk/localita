import Foundation

/// One line per relative-error comparison, so a passing suite reports *how
/// much* headroom it had and not merely that it passed.
///
/// Why this exists: `#expect(relErr < Tolerance.x)` prints `relErr` only on
/// failure, so a kernel passing at 0.99x its bound is indistinguishable from
/// one at 0.01x. That made the 2026-09-16 on-device run able to establish
/// conformance but not equivalence, and it means an Apple10 drift toward a
/// bound is invisible until it crosses.
///
/// Always on rather than gated behind an environment variable: reaching an
/// on-device test bundle with an env var means editing `EnvironmentVariables`
/// in the generated `.xctestrun`, which is fragile plumbing, and ~42 extra
/// lines in a 1,734-test run is not noise worth optimizing away.
///
/// ⚠️ This reports the raw error and its source location, **not** a ratio,
/// because the tolerance lives at the call site and this function cannot see
/// it. Read the ratio by looking up the `Tolerance` constant on the named
/// line. ⚠️ It also covers only comparisons that route through `RelError`;
/// suites asserting bytewise or structural equality — including both Vision
/// kernel suites — have no margin to report by construction.
public enum Margin {
    public static func record(_ relErr: Float, file: StaticString, line: UInt) {
        print("[margin] rel=\(relErr) at \(file):\(line)")
    }
}

/// Error-measurement helpers. Every test computed these inline; centralize.
public enum RelError {
    /// Standard relative error used across the test suite:
    ///   max_i |actual[i] - reference[i]|  /  max(max_i |reference[i]|, 1e-6)
    ///
    /// `file`/`line` default to the caller, so every existing call site is
    /// instrumented without being edited.
    public static func compute(actual: [Float], reference: [Float],
                               file: StaticString = #fileID,
                               line: UInt = #line) -> Float {
        precondition(actual.count == reference.count, "length mismatch")
        var maxAbsDiff: Float = 0
        var refNorm: Float = 0
        for i in 0..<actual.count {
            maxAbsDiff = max(maxAbsDiff, abs(actual[i] - reference[i]))
            refNorm = max(refNorm, abs(reference[i]))
        }
        let rel = maxAbsDiff / max(refNorm, 1e-6)
        Margin.record(rel, file: file, line: line)
        return rel
    }

    public static func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "length mismatch")
        var m: Float = 0
        for i in 0..<a.count {
            m = max(m, abs(a[i] - b[i]))
        }
        return m
    }

    /// Refines `compute` with both a relative and an absolute floor.
    /// Used when very small reference values would inflate relative error
    /// past the meaningful FP16 noise floor.
    public static func boundedRel(
        actual: [Float],
        reference: [Float],
        absFloor: Float,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Float {
        precondition(actual.count == reference.count, "length mismatch")
        var worst: Float = 0
        for i in 0..<actual.count {
            let diff = abs(actual[i] - reference[i])
            let denom = max(abs(reference[i]), absFloor)
            worst = max(worst, diff / denom)
        }
        Margin.record(worst, file: file, line: line)
        return worst
    }
}
