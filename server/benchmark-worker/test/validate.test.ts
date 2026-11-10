import { strict as assert } from "node:assert";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { CASES, Invalid, validateReport } from "../src/validate.ts";

const now = new Date("2026-10-13T18:00:00Z");

/// The first in-app run (2026-10-13) as format 2, its footers and memory
/// figures taken from its logs. The Swift tests decode the same file, so the
/// app and the Worker agree on its fields.
function fixture(format: 2 | 3 = 2): any {
  return JSON.parse(readFileSync(new URL(`fixtures/report-format${format}.json`,
                                         import.meta.url), "utf8"));
}

function rejects(report: unknown, field: string): void {
  assert.throws(() => validateReport(report, now),
                (error: unknown) => error instanceof Invalid && error.field === field,
                `expected ${field} to be refused`);
}

test("a real run passes", () => {
  const accepted = validateReport(fixture(), now);
  assert.deepEqual(accepted, {
    submissionID: "6F1C2B0E-3D4A-4E5B-9C6D-7E8F9A0B1C2D", format: 2,
    device: "iPhone18,3", appVersion: "1.0 (1)", outcome: "completed",
  });
});

test("the prompt hashes are the frozen files'", () => {
  for (const [caseID, sha] of CASES) {
    const file = new URL(`../../../docs/benchmark-prompts/real-generation-v1/${caseID}.json`,
                         import.meta.url);
    assert.equal(createHash("sha256").update(readFileSync(file)).digest("hex"), sha, caseID);
  }
});

test("a field the app does not write is refused, at any level", () => {
  const top = fixture();
  top.note = "hello";
  rejects(top, "report.note");
  const nested = fixture();
  nested.cases[1].email = "someone@example.com";
  rejects(nested, "report.cases[1].email");
});

test("another format, protocol or prompt is refused", () => {
  const format = fixture();
  format.format = 1;
  rejects(format, "report.format");
  const temperature = fixture();
  temperature.settings.temperature = 0.7;
  rejects(temperature, "report.settings.temperature");
  const prompt = fixture();
  prompt.cases[2].promptSHA256 = "0".repeat(64);
  rejects(prompt, "report.cases[2].promptSHA256");
  const order = fixture();
  order.cases.reverse();
  rejects(order, "report.cases[0].caseID");
});

test("a run that stopped early is accepted with the cases it has", () => {
  const failed = fixture();
  failed.outcome = { failed: { _0: "no Metal device" } };
  failed.cases = failed.cases.slice(0, 1);
  assert.equal(validateReport(failed, now).outcome, "failed");

  const killed = fixture();
  killed.outcome = { running: {} };
  killed.cases = [];
  delete killed.finished;
  assert.equal(validateReport(killed, now).outcome, "running");

  const short = fixture();
  short.cases.pop();
  rejects(short, "report.cases");
});

test("figures no phone could produce are refused", () => {
  const fast = fixture();
  fast.cases[0].decodeSeconds = 1;
  rejects(fast, "report.cases[0].decodeSeconds");
  const bytes = fixture();
  bytes.cases[0].decodeMiBPerToken = 5000;
  rejects(bytes, "report.cases[0].decodeMiBPerToken");
  const peak = fixture();
  peak.cases[0].peakFootprintBytes = peak.cases[0].footprintBytes - 1;
  rejects(peak, "report.cases[0].peakFootprintBytes");
  const future = fixture();
  future.started = "2027-01-01T00:00:00Z";
  rejects(future, "report.started");
});

test("a footer must be the line it says it is, in order", () => {
  const swapped = fixture();
  swapped.cases[0].footers.reverse();
  rejects(swapped, "report.cases[0].footers[0]");
  const control = fixture();
  control.cases[0].footers[1] = "[phase-time decode\nwall=1]";
  rejects(control, "report.cases[0].footers[1]");
});

test("the slot count may vary, within reason", () => {
  const slots = fixture();
  slots.settings.expertCacheSlots = 32;
  validateReport(slots, now);
  slots.settings.expertCacheSlots = 1000;
  rejects(slots, "report.settings.expertCacheSlots");
});

/// The same run as format 3, made the fourth of a seven-run settings sweep.
test("a format 3 sweep run passes, and format 2 still does", () => {
  assert.equal(validateReport(fixture(3), now).format, 3);
  assert.equal(validateReport(fixture(2), now).format, 2);
});

test("format 3 records skipping and early reads, and only the values the app runs", () => {
  for (const threshold of [0, 0.08, 0.1]) {
    const report = fixture(3);
    report.settings.expertSkipThreshold = threshold;
    validateReport(report, now);
  }
  const skip = fixture(3);
  skip.settings.expertSkipThreshold = 0.5;
  rejects(skip, "report.settings.expertSkipThreshold");
  const early = fixture(3);
  early.settings.earlyExpertReads = 8;
  rejects(early, "report.settings.earlyExpertReads");
  const missing = fixture(3);
  delete missing.settings.earlyExpertReads;
  rejects(missing, "report.settings.earlyExpertReads");
});

test("format 2 cannot carry format 3's fields", () => {
  const settings = fixture(2);
  settings.settings.expertSkipThreshold = 0.08;
  rejects(settings, "report.settings.expertSkipThreshold");
  const sweep = fixture(2);
  sweep.sweep = fixture(3).sweep;
  rejects(sweep, "report.sweep");
});

test("a sweep says which run it is, of how many", () => {
  const past = fixture(3);
  past.sweep.index = 8;
  rejects(past, "report.sweep.index");
  const id = fixture(3);
  id.sweep.submissionID = "not-a-uuid";
  rejects(id, "report.sweep.submissionID");
  const extra = fixture(3);
  extra.sweep.device = "x";
  rejects(extra, "report.sweep.device");
  const alone = fixture(3);
  delete alone.sweep;
  validateReport(alone, now);
});
