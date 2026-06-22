// (ramon fork / Agent Manager) Phase-1 MCP transport. A tiny DEPENDENCY-FREE
// JSON-RPC 2.0 client over the Node 18+ global `fetch` — NOT an MCP-client
// library (per the dependency-discipline rule: the only runtime dep is the
// Agent SDK). It talks to Ghostty's in-GUI MCP server (`POST ${url}`), parses
// the double-encoded tool-result envelope, and exposes typed wrappers for the
// three tools the summarizer needs: list_surfaces, read_surface,
// set_surface_annotation.
//
// Wire shapes (confirmed from the Swift source — MCPRPC/MCPTools/MCPLayout/
// MCPAnnotation.swift):
//   - request:  {jsonrpc:"2.0", id, method:"tools/call", params:{name, arguments}}
//   - success:  result.content[0].text is a STRING containing JSON (double-encoded)
//               -> JSON.parse(result.content[0].text) yields the structured payload.
//   - tool err: result.isError === true; result.content[0].text is a PLAIN string.
//   - rpc err:  top-level `error` object {code, message, data?} (no `result`).
// Everything is HTTP 200 (the JSON-RPC error lives in the body, not the status).
//
// ALL failure modes THROW an `McpError` the loop catches: the sidecar must never
// crash on a transient MCP failure — the caller logs + continues.

/** Thrown for any MCP transport / protocol / tool failure. The loop catches it. */
export class McpError extends Error {
  /** JSON-RPC error code when this is a protocol-level error, else undefined. */
  readonly code?: number;
  constructor(message: string, code?: number) {
    super(message);
    this.name = "McpError";
    this.code = code;
  }
}

/** A list_surfaces row. The optional fields are OMITTED (=== undefined) when
 *  unknown — never null/"". `notes` is the summarizer's own last summary
 *  round-tripping back. `agentKind` ("claude"/"codex") is the dashboard's
 *  authoritative subtree-walk DETECTION — the reliable "this is an agent" signal
 *  (the foreground `processName` is the pool wrapper `bash`, not the agent). */
export interface Surface {
  id: string;
  title: string;
  pwd: string;
  window: number;
  tab: number;
  tabTitle: string;
  splitIndex: number;
  splitCount: number;
  focused: boolean;
  bell: boolean;
  exited: boolean;
  atPrompt: boolean;
  processName?: string;
  command?: string;
  idleSeconds?: number;
  agentState?: string;
  lastPrompt?: string;
  lastTool?: string;
  notes?: string;
  agentKind?: string;
}

/** read_surface return: the viewport screen text + its grid dimensions. */
export interface SurfaceScreen {
  text: string;
  cols: number;
  rows: number;
}

/** The annotation write payload. Phase 1 writes ONLY summary (+ optional
 *  phase/needsUser); suggestion/confidence are manager Phase 2+. */
export interface Annotation {
  summary: string;
  phase?: string;
  needsUser?: boolean;
}

/** Minimal shape of a JSON-RPC response we care about. */
interface RpcResponse {
  jsonrpc?: string;
  id?: unknown;
  result?: {
    content?: Array<{ type?: string; text?: string }>;
    isError?: boolean;
  };
  error?: { code?: number; message?: string; data?: unknown };
}

export interface McpClientOptions {
  url: string;
  token?: string;
  /** Per-request timeout in ms (AbortController). Default 15000. */
  timeoutMs?: number;
}

/**
 * Dependency-free JSON-RPC client for Ghostty's MCP server. One instance per
 * sidecar; methods are independently awaitable. Every error path throws McpError.
 */
export class McpClient {
  private readonly url: string;
  private readonly headers: Record<string, string>;
  private readonly timeoutMs: number;
  private nextId = 1;

  constructor(opts: McpClientOptions) {
    this.url = opts.url;
    this.timeoutMs = opts.timeoutMs ?? 15000;
    this.headers = { "Content-Type": "application/json" };
    if (opts.token) this.headers["X-Ghostty-Token"] = opts.token;
  }

  /** list_surfaces -> the surfaces array. */
  async listSurfaces(): Promise<Surface[]> {
    const payload = await this.call("list_surfaces", {});
    const obj = parseToolJson(payload);
    const surfaces = (obj as { surfaces?: unknown }).surfaces;
    if (!Array.isArray(surfaces)) {
      throw new McpError("list_surfaces: malformed payload (no surfaces array)");
    }
    return surfaces as Surface[];
  }

  /** read_surface(id) -> the viewport text + grid. */
  async readSurface(id: string): Promise<SurfaceScreen> {
    const payload = await this.call("read_surface", { id });
    const obj = parseToolJson(payload) as Partial<SurfaceScreen>;
    if (typeof obj.text !== "string") {
      throw new McpError("read_surface: malformed payload (no text)");
    }
    return {
      text: obj.text,
      cols: typeof obj.cols === "number" ? obj.cols : 0,
      rows: typeof obj.rows === "number" ? obj.rows : 0,
    };
  }

  /** set_surface_annotation(id, ann). Writes ONLY summary/phase/needsUser. */
  async setAnnotation(id: string, ann: Annotation): Promise<void> {
    const args: Record<string, unknown> = { id, summary: ann.summary };
    if (ann.phase !== undefined) args.phase = ann.phase;
    if (ann.needsUser !== undefined) args.needsUser = ann.needsUser;
    // The result is "{\"ok\":true}" wrapped; we only need it not to be an error.
    await this.call("set_surface_annotation", args);
  }

  /**
   * Low-level tools/call. Returns the RAW `result.content[0].text` STRING on
   * success; the caller JSON.parses tool payloads. Throws McpError on a
   * non-200, a protocol-level error, a tool-level error (isError), or a
   * malformed body.
   */
  private async call(
    name: string,
    args: Record<string, unknown>,
  ): Promise<string> {
    const id = this.nextId++;
    const body = JSON.stringify({
      jsonrpc: "2.0",
      id,
      method: "tools/call",
      params: { name, arguments: args },
    });

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    let res: Response;
    try {
      res = await fetch(this.url, {
        method: "POST",
        headers: this.headers,
        body,
        signal: controller.signal,
      });
    } catch (err) {
      throw new McpError(
        `${name}: request failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    } finally {
      clearTimeout(timer);
    }

    if (!res.ok) {
      throw new McpError(`${name}: HTTP ${res.status}`);
    }

    let json: RpcResponse;
    try {
      json = (await res.json()) as RpcResponse;
    } catch {
      throw new McpError(`${name}: response body was not JSON`);
    }

    return extractToolText(name, json);
  }
}

/**
 * Given a parsed JSON-RPC response, return the tool's success `text` STRING, or
 * throw McpError for protocol errors (top-level `error`) and tool errors
 * (`result.isError`). PURE — exported for unit testing. The returned string is
 * the (still-encoded) tool payload; JSON.parse it via parseToolJson where the
 * tool returns JSON.
 */
export function extractToolText(name: string, json: RpcResponse): string {
  // (B) Protocol-level JSON-RPC error: top-level `error`, no `result`.
  if (json.error) {
    const code = json.error.code;
    const msg = json.error.message ?? "unknown error";
    throw new McpError(`${name}: JSON-RPC error ${code ?? "?"}: ${msg}`, code);
  }
  const result = json.result;
  if (!result || !Array.isArray(result.content) || result.content.length === 0) {
    throw new McpError(`${name}: malformed result envelope`);
  }
  const text = result.content[0]?.text;
  if (typeof text !== "string") {
    throw new McpError(`${name}: result content had no text`);
  }
  // (A) Tool-level error: success-shaped result with isError:true; text is a
  // PLAIN human message (do NOT JSON.parse it).
  if (result.isError === true) {
    throw new McpError(`${name}: tool error: ${text}`);
  }
  return text;
}

/**
 * JSON.parse a tool's success text into an object, wrapping a parse failure as
 * McpError. PURE — exported for unit testing.
 */
export function parseToolJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    throw new McpError("tool result was not valid JSON");
  }
}
