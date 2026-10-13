// What the Worker accepts: a `BenchmarkReport` as the app writes it, format 2
// (`Sources/TurboFieldfareApp/Core/Benchmark/BenchmarkReport.swift`), run
// under `BenchmarkProtocol`. Keys the app does not write are refused at every
// level, so a stored row holds exactly the known fields and nothing smuggled
// beside them. The ranges only keep out what no phone could have produced;
// they cannot tell a believable invented run from a real one.

/// The frozen `real-generation-v1` cases, in run order, and the SHA-256 of
/// each prompt file under `docs/benchmark-prompts/real-generation-v1/`.
export const CASES: ReadonlyArray<readonly [string, string]> = [
  ["short-explanation", "c57da2677143657be55e03797c1aabe8e012d61c1a71bf9345acdd575117d1e1"],
  ["medium-review", "23add7976db2069c9927affd13c2f5120508702a1c4915ea88b7de565bdd4b33"],
  ["long-synthesis", "b12e4a71493ad151d7a85b91e878ba784b116ef65de9fcb1b1b1c05198b537b8"],
];

export const FORMAT = 2;
/// A real report is about 9 KB.
export const MAX_BODY_BYTES = 64 * 1024;

const GiB = 1024 ** 3;
const THERMAL = ["nominal", "fair", "serious", "critical", "unknown"];
const STOP_REASONS = ["eos", "endOfTurn", "maxTokens", "stopString", "cancelled", "toolCalls"];
const OUTCOMES = ["running", "completed", "cancelled", "interrupted", "failed"];
const FOOTERS = ["expert-io", "phase-time", "gpu-time", "read-latency"];
const HEX64 = /^[0-9a-f]{64}$/;
const UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i;
const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
/// The benchmark shipped in October 2026; nothing can have run before it.
const EARLIEST_RUN = Date.parse("2026-10-01T00:00:00Z");

export class Invalid extends Error {
  field: string;
  constructor(field: string, message: string) {
    super(`${field}: ${message}`);
    this.field = field;
  }
}

type Fields = Record<string, unknown>;

function fields(value: unknown, path: string, required: string[],
                optional: string[] = []): Fields {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Invalid(path, "expected an object");
  }
  const object = value as Fields;
  for (const key of required) {
    if (!(key in object)) throw new Invalid(`${path}.${key}`, "missing");
  }
  for (const key of Object.keys(object)) {
    if (!required.includes(key) && !optional.includes(key)) {
      throw new Invalid(`${path}.${key}`, "not a field of the report");
    }
  }
  return object;
}

function text(value: unknown, path: string, pattern: RegExp): string {
  if (typeof value !== "string" || !pattern.test(value)) {
    throw new Invalid(path, `expected a string matching ${pattern}`);
  }
  return value;
}

function oneOf(value: unknown, path: string, allowed: string[]): string {
  if (typeof value !== "string" || !allowed.includes(value)) {
    throw new Invalid(path, `expected one of ${allowed.join(", ")}`);
  }
  return value;
}

function number(value: unknown, path: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max) {
    throw new Invalid(path, `expected a number from ${min} to ${max}`);
  }
  return value;
}

function integer(value: unknown, path: string, min: number, max: number): number {
  const n = number(value, path, min, max);
  if (!Number.isInteger(n)) throw new Invalid(path, "expected an integer");
  return n;
}

function exactly(value: unknown, path: string, expected: number): void {
  if (value !== expected) throw new Invalid(path, `expected ${expected}, the protocol's`);
}

function date(value: unknown, path: string, now: Date): number {
  const time = Date.parse(text(value, path, ISO_DATE));
  if (Number.isNaN(time) || time < EARLIEST_RUN || time > now.getTime() + 86_400_000) {
    throw new Invalid(path, "not a date a run could have");
  }
  return time;
}

/// The fields a stored row indexes, besides the report itself.
export interface Accepted {
  submissionID: string;
  format: number;
  device: string;
  appVersion: string;
  outcome: string;
}

/// Throws `Invalid` naming the first field that fails.
export function validateReport(value: unknown, now: Date): Accepted {
  const report = fields(value, "report",
    ["format", "id", "submissionID", "started", "outcome", "device", "model",
     "settings", "plannedCases", "cases"],
    ["finished"]);
  exactly(report.format, "report.format", FORMAT);
  const submissionID = text(report.submissionID, "report.submissionID", UUID);
  text(report.id, "report.id", /^[0-9A-Za-z+-]{1,64}$/);
  const started = date(report.started, "report.started", now);
  if (report.finished !== undefined
      && date(report.finished, "report.finished", now) < started) {
    throw new Invalid("report.finished", "before the run started");
  }

  const outcome = fields(report.outcome, "report.outcome", [], OUTCOMES);
  const kinds = Object.keys(outcome);
  if (kinds.length !== 1) throw new Invalid("report.outcome", "expected one outcome");
  const kind = kinds[0];
  if (kind === "failed") {
    const failed = fields(outcome.failed, "report.outcome.failed", ["_0"]);
    text(failed._0, "report.outcome.failed._0", /^[^\u0000-\u001f]{0,500}$/);
  } else {
    fields(outcome[kind], `report.outcome.${kind}`, []);
  }

  const device = fields(report.device, "report.device",
    ["identifier", "physicalMemoryBytes", "osVersion", "appVersion", "thermalAtStart",
     "batteryAtStart", "lowPowerModeAtStart"]);
  const identifier = text(device.identifier, "report.device.identifier",
                          /^(iPhone|iPad)\d{1,3},\d{1,3}$/);
  integer(device.physicalMemoryBytes, "report.device.physicalMemoryBytes", 2 * GiB, 64 * GiB);
  text(device.osVersion, "report.device.osVersion", /^\d{2}(\.\d{1,2}){0,2}$/);
  const appVersion = text(device.appVersion, "report.device.appVersion",
                          /^[0-9A-Za-z.]{1,16} \([0-9A-Za-z.]{1,16}\)$/);
  oneOf(device.thermalAtStart, "report.device.thermalAtStart", THERMAL);
  text(device.batteryAtStart, "report.device.batteryAtStart",
       /^-?\d{1,3}%\/(charging|full|unplugged|unknown)$/);
  if (typeof device.lowPowerModeAtStart !== "boolean") {
    throw new Invalid("report.device.lowPowerModeAtStart", "expected true or false");
  }

  const model = fields(report.model, "report.model", ["name", "folder"], ["manifestSHA256"]);
  text(model.name, "report.model.name", /^[^\u0000-\u001f]{1,64}$/);
  text(model.folder, "report.model.folder", /^[^/\u0000-\u001f]{1,120}\.gturbo$/);
  if (model.manifestSHA256 !== undefined) {
    text(model.manifestSHA256, "report.model.manifestSHA256", HEX64);
  }

  const settings = fields(report.settings, "report.settings",
    ["maxContext", "maxNewTokens", "expertCacheSlots", "temperature", "topK", "topP", "seed"]);
  exactly(settings.maxContext, "report.settings.maxContext", 4096);
  exactly(settings.maxNewTokens, "report.settings.maxNewTokens", 1024);
  exactly(settings.temperature, "report.settings.temperature", 0.2);
  exactly(settings.topK, "report.settings.topK", 64);
  exactly(settings.topP, "report.settings.topP", 0.95);
  exactly(settings.seed, "report.settings.seed", 1);
  // Not fixed: the slot count is a per-device default, and finding the best
  // one per device is part of what results are for.
  integer(settings.expertCacheSlots, "report.settings.expertCacheSlots", 8, 64);

  const planned = report.plannedCases;
  if (!Array.isArray(planned) || planned.length !== CASES.length
      || planned.some((id, i) => id !== CASES[i][0])) {
    throw new Invalid("report.plannedCases", "expected the three real-generation-v1 cases");
  }

  const cases = report.cases;
  if (!Array.isArray(cases) || cases.length > CASES.length) {
    throw new Invalid("report.cases", `expected at most ${CASES.length} cases`);
  }
  if (kind === "completed" && cases.length !== CASES.length) {
    throw new Invalid("report.cases", "a completed run has every case");
  }
  cases.forEach((entry, i) => validateCase(entry, `report.cases[${i}]`, CASES[i]));

  return { submissionID: submissionID.toUpperCase(), format: FORMAT, device: identifier,
           appVersion, outcome: kind };
}

function validateCase(value: unknown, path: string,
                      [caseID, promptSHA256]: readonly [string, string]): void {
  const result = fields(value, path,
    ["caseID", "promptSHA256", "promptTokens", "prefillSeconds", "newTokens",
     "decodeSeconds", "stopReason", "cooldownSeconds", "thermalAtStart", "thermalAtEnd",
     "generatedSHA256", "logFile", "footers", "footprintBytes", "peakFootprintBytes",
     "availableMemoryBytes"],
    ["decodeMiBPerToken", "decodeCacheHitRate"]);
  if (result.caseID !== caseID) throw new Invalid(`${path}.caseID`, `expected ${caseID}`);
  if (result.promptSHA256 !== promptSHA256) {
    throw new Invalid(`${path}.promptSHA256`, "not the frozen prompt");
  }
  integer(result.promptTokens, `${path}.promptTokens`, 1, 4096);
  number(result.prefillSeconds, `${path}.prefillSeconds`, 0, 3600);
  const newTokens = integer(result.newTokens, `${path}.newTokens`, 0, 1024);
  const decodeSeconds = number(result.decodeSeconds, `${path}.decodeSeconds`, 0, 36_000);
  // About ten times the fastest phone row.
  if (newTokens > 1 && (decodeSeconds === 0 || newTokens / decodeSeconds > 100)) {
    throw new Invalid(`${path}.decodeSeconds`, "faster than any phone decodes");
  }
  oneOf(result.stopReason, `${path}.stopReason`, STOP_REASONS);
  // The zero-hit ceiling is 768.75 MiB a token; the early read adds up to
  // one expert a layer on top.
  if (result.decodeMiBPerToken !== undefined) {
    number(result.decodeMiBPerToken, `${path}.decodeMiBPerToken`, 0, 1024);
  }
  if (result.decodeCacheHitRate !== undefined) {
    number(result.decodeCacheHitRate, `${path}.decodeCacheHitRate`, 0, 1);
  }
  number(result.cooldownSeconds, `${path}.cooldownSeconds`, 0, 900);
  oneOf(result.thermalAtStart, `${path}.thermalAtStart`, THERMAL);
  oneOf(result.thermalAtEnd, `${path}.thermalAtEnd`, THERMAL);
  text(result.generatedSHA256, `${path}.generatedSHA256`, HEX64);
  text(result.logFile, `${path}.logFile`, /^[0-9A-Za-z._-]{1,120}\.log$/);

  const footers = result.footers;
  if (!Array.isArray(footers) || footers.length !== FOOTERS.length) {
    throw new Invalid(`${path}.footers`, `expected ${FOOTERS.join(", ")}`);
  }
  footers.forEach((line, i) => text(line, `${path}.footers[${i}]`,
                                    new RegExp(`^\\[${FOOTERS[i]} [ -~]{1,1000}\\]$`)));

  const footprint = integer(result.footprintBytes, `${path}.footprintBytes`, 1, 64 * GiB);
  const peak = integer(result.peakFootprintBytes, `${path}.peakFootprintBytes`, 1, 64 * GiB);
  if (peak < footprint) {
    throw new Invalid(`${path}.peakFootprintBytes`, "below the footprint");
  }
  integer(result.availableMemoryBytes, `${path}.availableMemoryBytes`, 0, 64 * GiB);
}
