// Receives benchmark results from the app. `POST /v1/results` takes one
// report as JSON (`validate.ts`), and stores it as one row in D1 if it passes.
//
// Nothing about the sender is kept. The rate limiter keys on the address in
// memory and writes nothing, and the Worker logs nothing (observability is
// off in `wrangler.toml`).

import { Invalid, MAX_BODY_BYTES, validateReport } from "./validate.ts";
import type { Accepted } from "./validate.ts";

export interface Row extends Accepted {
  receivedAt: string;
  /// The report as parsed and re-serialised, so its spacing is not the sender's.
  report: string;
}

export interface Deps {
  /// False when a row with the submission's ID is already stored.
  insert(row: Row): Promise<boolean>;
  /// False when the sender has sent too much lately.
  allow(key: string): Promise<boolean>;
  now(): Date;
}

function reply(status: number, body: Record<string, unknown>,
               headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

/// The body as text, or nil past `max` bytes, without reading further than that.
async function readCapped(request: Request, max: number): Promise<string | null> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > max) return null;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

export async function handle(request: Request, deps: Deps): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/" && request.method === "GET") {
    return new Response("TurboFieldfare benchmark results. The app sends them to "
      + "POST /v1/results.\n", { headers: { "content-type": "text/plain" } });
  }
  if (url.pathname !== "/v1/results") return reply(404, { error: "not found" });
  if (request.method !== "POST") {
    return reply(405, { error: "use POST" }, { allow: "POST" });
  }

  const address = request.headers.get("cf-connecting-ip") ?? "unknown";
  if (!(await deps.allow(address))) {
    return reply(429, { error: "too many results at once; try again in a minute" });
  }
  if (!(request.headers.get("content-type") ?? "").startsWith("application/json")) {
    return reply(415, { error: "expected application/json" });
  }

  let body: string | null;
  try {
    body = await readCapped(request, MAX_BODY_BYTES);
  } catch {
    return reply(400, { error: "the body is not UTF-8" });
  }
  if (body === null) return reply(413, { error: `over ${MAX_BODY_BYTES} bytes` });

  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return reply(400, { error: "the body is not JSON" });
  }

  const now = deps.now();
  let accepted;
  try {
    accepted = validateReport(parsed, now);
  } catch (error) {
    if (error instanceof Invalid) {
      return reply(400, { error: error.message, field: error.field });
    }
    throw error;
  }

  const stored = await deps.insert({
    ...accepted, receivedAt: now.toISOString(), report: JSON.stringify(parsed),
  });
  // A repeat is not an error for the app: the result is stored either way.
  return stored
    ? reply(201, { stored: accepted.submissionID })
    : reply(409, { error: "already stored", stored: accepted.submissionID });
}

interface Env {
  DB: {
    prepare(query: string): {
      bind(...values: unknown[]): { run(): Promise<{ meta: { changes: number } }> };
    };
  };
  SUBMIT_LIMITER: { limit(options: { key: string }): Promise<{ success: boolean }> };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, {
      async insert(row) {
        const result = await env.DB.prepare(
          "INSERT INTO submissions (submission_id, received_at, format, device, "
            + "app_version, outcome, report) VALUES (?, ?, ?, ?, ?, ?, ?) "
            + "ON CONFLICT (submission_id) DO NOTHING")
          .bind(row.submissionID, row.receivedAt, row.format, row.device,
                row.appVersion, row.outcome, row.report)
          .run();
        return result.meta.changes === 1;
      },
      async allow(key) {
        return (await env.SUBMIT_LIMITER.limit({ key })).success;
      },
      now: () => new Date(),
    });
  },
};
