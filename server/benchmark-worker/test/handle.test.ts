import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { handle } from "../src/index.ts";
import type { Deps, Row } from "../src/index.ts";
import { MAX_BODY_BYTES } from "../src/validate.ts";

const body = readFileSync(new URL("fixtures/report-format2.json", import.meta.url), "utf8");

function memory(allowed = true): Deps & { rows: Map<string, Row> } {
  const rows = new Map<string, Row>();
  return {
    rows,
    async insert(row) {
      if (rows.has(row.submissionID)) return false;
      rows.set(row.submissionID, row);
      return true;
    },
    async allow() { return allowed; },
    now: () => new Date("2026-10-13T18:00:00Z"),
  };
}

function post(text: string, type = "application/json"): Request {
  return new Request("https://bench.test/v1/results", {
    method: "POST", headers: { "content-type": type }, body: text,
  });
}

test("a report is stored once; sending it again says so", async () => {
  const deps = memory();
  const first = await handle(post(body), deps);
  assert.equal(first.status, 201);
  assert.deepEqual(await first.json(), { stored: "6F1C2B0E-3D4A-4E5B-9C6D-7E8F9A0B1C2D" });

  const row = [...deps.rows.values()][0];
  assert.equal(row.receivedAt, "2026-10-13T18:00:00.000Z");
  assert.deepEqual(JSON.parse(row.report), JSON.parse(body));
  assert.equal(row.device, "iPhone18,3");

  const again = await handle(post(body), deps);
  assert.equal(again.status, 409);
  assert.equal(deps.rows.size, 1);
});

test("a refused report names the field and stores nothing", async () => {
  const deps = memory();
  const report = JSON.parse(body);
  report.settings.topK = 40;
  const response = await handle(post(JSON.stringify(report)), deps);
  assert.equal(response.status, 400);
  assert.equal((await response.json()).field, "report.settings.topK");
  assert.equal(deps.rows.size, 0);
});

test("what is not a report is turned away before it is read", async () => {
  const deps = memory();
  assert.equal((await handle(post("{"), deps)).status, 400);
  assert.equal((await handle(post(body, "text/plain"), deps)).status, 415);
  assert.equal((await handle(post(" ".repeat(MAX_BODY_BYTES + 1)), deps)).status, 413);
  assert.equal((await handle(post(body), memory(false))).status, 429);
  assert.equal((await handle(new Request("https://bench.test/v1/results"), deps)).status, 405);
  assert.equal((await handle(new Request("https://bench.test/other"), deps)).status, 404);
  assert.equal(deps.rows.size, 0);
});
