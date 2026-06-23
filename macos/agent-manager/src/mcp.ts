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

import type { QueueCommand } from "./queue/commands.js";

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
  /** The user's per-session free-text NOTE/goal typed into the dashboard tile —
   *  the STRONGEST goal signal for the manager. Omitted when unset. */
  userNotes?: string;
  /** (Phase 2.1) True iff the user DISMISSED the manager's current suggestion. The
   *  manager suppresses re-suggesting while this is true AND the change fingerprint
   *  is unchanged. The Swift side emits it as a plain bool (always present), but it
   *  is typed OPTIONAL here so a pre-upgrade host that omits it still typechecks —
   *  `undefined` reads as false (see shouldSuggest). */
  suggestionDismissed?: boolean;
  agentKind?: string;
  /** (Agent Queue) The STABLE host session id (`ghostty_surface_session_id`) — the
   *  supervisor's persistence/re-adoption key (§9). OMITTED (=== undefined) when
   *  absent so a pre-upgrade host that doesn't yet emit it still typechecks. Under
   *  the `.exec` backend / no pty-host it is 0, which the supervisor self-disables on. */
  sessionID?: number;
}

/** read_surface return: the viewport screen text + its grid dimensions. */
export interface SurfaceScreen {
  text: string;
  cols: number;
  rows: number;
}

/** The annotation write payload. The summarizer writes `summary` (+ optional
 *  phase/needsUser); the manager (Phase 2) writes `suggestion`. Every field is
 *  OPTIONAL — set_surface_annotation is a PARTIAL MERGE on the Swift side, so a
 *  writer sends ONLY the field(s) it owns and the others keep their prior value.
 *  AT LEAST ONE field must be present. */
export interface Annotation {
  summary?: string;
  suggestion?: string;
  phase?: string;
  needsUser?: boolean;
  /** (Phase 2.1) The manager's HONEST 0..1 self-rating of how well the suggested
   *  reply advances the user's goal. Written alongside `suggestion`; the tile dims
   *  a low-confidence one. */
  confidence?: number;
  /** (Agent Queue, §8.5) The work-item dedup KEY tagging this surface as a queue tile.
   *  Written at dispatch (and re-stamped on reconcile when a GUI restart dropped the
   *  in-memory annotation map — the durable store is truth, §9). The dashboard derives
   *  the per-tile origin marker + grouping from `queueName`; reconcile reads `queueKey`
   *  as the orphan-adoption hint. Partial-merge, like summary/suggestion. */
  queueKey?: string;
  /** (Agent Queue, §8.5) The owning run's name = the dashboard ORIGIN (§11). */
  queueName?: string;
  /** (Agent Queue, §8.5) The work-item url for the dashboard's clickable badge. */
  queueUrl?: string;
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

  /** set_surface_annotation(id, ann). A PARTIAL MERGE: only the provided fields
   *  are sent (the Swift side overlays them onto the prior annotation), so the
   *  summarizer and the manager can write their own fields independently. */
  async setAnnotation(id: string, ann: Annotation): Promise<void> {
    const args: Record<string, unknown> = { id };
    if (ann.summary !== undefined) args.summary = ann.summary;
    if (ann.suggestion !== undefined) args.suggestion = ann.suggestion;
    if (ann.phase !== undefined) args.phase = ann.phase;
    if (ann.needsUser !== undefined) args.needsUser = ann.needsUser;
    if (ann.confidence !== undefined) args.confidence = ann.confidence;
    if (ann.queueKey !== undefined) args.queueKey = ann.queueKey;
    if (ann.queueName !== undefined) args.queueName = ann.queueName;
    if (ann.queueUrl !== undefined) args.queueUrl = ann.queueUrl;
    // The result is "{\"ok\":true}" wrapped; we only need it not to be an error.
    await this.call("set_surface_annotation", args);
  }

  /**
   * (Agent Queue, §8.1) spawn_split_command — split a TARGET surface in a given
   * direction (or open the run's first tab when `firstTab`) running `command`, and
   * return the new leaf's stable identity `{id (UUID), sessionId}`. The macOS-layer
   * tool feeds the rendered command as input (interior newlines collapsed to one
   * trailing submit).
   *
   * GENERICITY / §13 (the #1 requirement): item fields reach the agent's launch
   * command as ENV VARS, NEVER spliced into the shell line. Those vars travel in the
   * `env` map (GHOSTTY_ITEM_*); the Swift `spawn_split_command` handler sets them on the
   * new split's `SurfaceConfiguration.environmentVariables` so the launched shell
   * inherits them, and the template's `command` references them as `$GHOSTTY_ITEM_*`.
   * `command` itself is the template's launch line passed through VERBATIM — the caller
   * MUST NOT string-substitute item fields into it (that would be injection). SAFETY: the
   * dedup/spawn gating is the caller's. Throws McpError on any failure (the loop catches +
   * skips the dispatch).
   */
  async spawnSplitCommand(args: {
    targetUUID?: string;
    direction?: "right" | "down" | "left" | "up";
    command: string;
    cwd?: string;
    firstTab?: boolean;
    /** The item-context env (GHOSTTY_ITEM_*) for the launched agent (§13). Forwarded
     *  to the tool as `env`; the Swift handler sets it on the new split's
     *  environmentVariables. Omitted from the wire payload when empty/undefined. */
    env?: Record<string, string>;
  }): Promise<{ id: string; sessionId: number }> {
    const toolArgs: Record<string, unknown> = { command: args.command };
    if (args.targetUUID !== undefined) toolArgs.targetUUID = args.targetUUID;
    if (args.direction !== undefined) toolArgs.direction = args.direction;
    if (args.cwd !== undefined) toolArgs.cwd = args.cwd;
    if (args.firstTab !== undefined) toolArgs.firstTab = args.firstTab;
    if (args.env !== undefined && Object.keys(args.env).length > 0) {
      toolArgs.env = args.env;
    }
    const payload = await this.call("spawn_split_command", toolArgs);
    const obj = parseToolJson(payload) as { id?: unknown; sessionId?: unknown };
    if (typeof obj.id !== "string" || obj.id.length === 0) {
      throw new McpError("spawn_split_command: malformed payload (no id)");
    }
    const sessionId = typeof obj.sessionId === "number" ? obj.sessionId : 0;
    return { id: obj.id, sessionId };
  }

  /**
   * (Agent Queue, §10) send_key — send a SINGLE real key event to a surface via the
   * existing MCP `send_key` tool (the supervisor's only key send; it never sends
   * free-form input). Used by the close sequence to deliver the template `agent.exit`
   * keys (default Ctrl-D) so the agent's child exits before the confirm-bypass close.
   * `key` is a template `exit.keys` entry passed verbatim. Throws McpError on failure.
   */
  async sendKey(id: string, key: string): Promise<void> {
    await this.call("send_key", { id, key });
  }

  /**
   * (Agent Queue, §10) send_text — TYPE a literal string into a surface (does NOT
   * submit). Used by the close sequence for agents whose exit is a typed command
   * (Claude Code's `/quit`); a `sendKey("enter")` follows to submit. Throws McpError on
   * any failure.
   */
  async sendText(id: string, text: string): Promise<void> {
    await this.call("send_text", { id, text });
  }

  /**
   * (Agent Queue, §8.2) force_close_surface — close WITHOUT the confirm-close prompt
   * (§10). The supervisor calls this only AFTER the agent's child has exited, so the
   * confirm-bypass close doesn't pop a modal. Throws McpError on any failure.
   */
  async forceCloseSurface(id: string): Promise<void> {
    await this.call("force_close_surface", { id });
  }

  /**
   * (Agent Queue, §8.3) signal_attention — ring the bell / raise attention for a
   * surface (fans out to the dashboard aggregate, web monitor, and push, reusing the
   * `.ghosttyBellDidRing` pipeline). Used by `onAgentExit=leave-and-bell` (§6) so a
   * crashed agent surfaces itself for human review. Generic + reusable. `reason` is an
   * optional human-readable note. Throws McpError on any failure.
   */
  async signalAttention(id: string, reason?: string): Promise<void> {
    const args: Record<string, unknown> = { id };
    if (reason !== undefined) args.reason = reason;
    await this.call("signal_attention", args);
  }

  /**
   * (Agent Queue, §8a) take_queue_commands — DRAIN + clear the GUI's in-memory FIFO of
   * GUI→sidecar control commands. Returns the drained commands (a `{commands:[...]}`
   * envelope on the wire). TOLERANT: a malformed payload, a non-array `commands`, or any
   * non-object entry yields `[]` (the worst case is a missed control intent the user can
   * re-trigger — the STARTED-run STATE itself is persisted sidecar-side, so a running
   * queue survives regardless). Per-entry, only a recognized `action` with the right shape
   * is kept; unrecognized entries are dropped. Throws McpError ONLY on a transport/protocol
   * failure (the loop catches it and simply skips the drain this sweep).
   */
  async takeQueueCommands(): Promise<QueueCommand[]> {
    const payload = await this.call("take_queue_commands", {});
    const obj = parseToolJson(payload);
    return coerceQueueCommands(obj);
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

/** The recognized control-command actions (§8a). */
const QUEUE_ACTIONS: ReadonlySet<string> = new Set([
  "start",
  "stop",
  "abort",
  "pause",
  "resume",
]);

/**
 * Coerce an arbitrary parsed `take_queue_commands` payload into a clean `QueueCommand[]`.
 * PURE + TOLERANT — exported for unit testing. Accepts the `{commands:[...]}` envelope
 * (the wire shape). Anything else — a non-object, a missing/non-array `commands`, a
 * non-object entry, or an entry with an unrecognized `action` — yields `[]` / drops that
 * entry. Only `action`, `template`, and `run` are carried (and only when string-typed).
 */
export function coerceQueueCommands(obj: unknown): QueueCommand[] {
  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) return [];
  const cmds = (obj as { commands?: unknown }).commands;
  if (!Array.isArray(cmds)) return [];
  const out: QueueCommand[] = [];
  for (const raw of cmds) {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) continue;
    const r = raw as Record<string, unknown>;
    const action = r.action;
    if (typeof action !== "string" || !QUEUE_ACTIONS.has(action)) continue;
    const cmd: QueueCommand = { action: action as QueueCommand["action"] };
    if (typeof r.template === "string" && r.template.length > 0) cmd.template = r.template;
    if (typeof r.run === "string" && r.run.length > 0) cmd.run = r.run;
    // (§8b) start-time params: an object of string→string (drop non-string values).
    if (r.params !== null && typeof r.params === "object" && !Array.isArray(r.params)) {
      const params: Record<string, string> = {};
      for (const [k, v] of Object.entries(r.params as Record<string, unknown>)) {
        if (typeof k === "string" && k.length > 0 && typeof v === "string") params[k] = v;
      }
      if (Object.keys(params).length > 0) cmd.params = params;
    }
    out.push(cmd);
  }
  return out;
}
