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
import type { QueueGraphReport, QueueStatusReport } from "./queue/status.js";

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
  /** (Agent Manager) Whether the user HID this surface's tile in the Agent Dashboard.
   *  OMITTED (=== undefined) when not hidden / unknown. The summarizer skips hidden
   *  tiles — no point spending a Haiku call on a tile you've decluttered away. */
  hidden?: boolean;
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
 *  phase/needsUser); the Agent Queue supervisor writes the queue tags. Every field
 *  is OPTIONAL — set_surface_annotation is a PARTIAL MERGE on the Swift side, so a
 *  writer sends ONLY the field(s) it owns and the others keep their prior value.
 *  AT LEAST ONE field must be present. */
export interface Annotation {
  summary?: string;
  phase?: string;
  needsUser?: boolean;
  /** (Agent Queue, §8.5) The work-item dedup KEY tagging this surface as a queue tile.
   *  Written at dispatch (and re-stamped on reconcile when a GUI restart dropped the
   *  in-memory annotation map — the durable store is truth, §9). The dashboard derives
   *  the per-tile origin marker + grouping from `queueName`; reconcile reads `queueKey`
   *  as the orphan-adoption hint. Partial-merge, like summary. */
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
    if (ann.phase !== undefined) args.phase = ann.phase;
    if (ann.needsUser !== undefined) args.needsUser = ann.needsUser;
    if (ann.queueKey !== undefined) args.queueKey = ann.queueKey;
    if (ann.queueName !== undefined) args.queueName = ann.queueName;
    if (ann.queueUrl !== undefined) args.queueUrl = ann.queueUrl;
    // The result is "{\"ok\":true}" wrapped; we only need it not to be an error.
    await this.call("set_surface_annotation", args);
  }

  /**
   * (Agent Queue, §11 health) Push the run-level health snapshot to the GUI so the Agent
   * Dashboard can show the queue's presence + backlog + what's next — even before any
   * split spawns. Fire-and-forget from the caller's view (the runner catches errors); the
   * wire args mirror `QueueStatusReport` 1:1 (`maxItems` is a number or null = unlimited).
   */
  async reportQueueStatus(status: QueueStatusReport): Promise<void> {
    await this.call("report_queue_status", {
      queueName: status.queueName,
      present: status.present,
      phase: status.phase,
      queued: status.queued,
      listOk: status.listOk,
      active: status.active,
      dispatched: status.dispatched,
      maxItems: status.maxItems,
      concurrency: status.concurrency,
      next: status.next,      // each carries key/title?/url?
      running: status.running, // key/title?/url? per running agent
    });
  }

  /**
   * (Agent Queue, backlog graph) Push the run's WHOLE-board snapshot to the GUI via the
   * `report_queue_graph` MCP tool, so the dashboard shows the "N backlog" button + renders
   * the dependency-graph canvas. Fired only when the optional `provider.graph` is defined
   * and a fetch SUCCEEDS (throttled at `intervals.listMs`), plus once with `present:false`
   * when the run is removed. Fire-and-forget from the caller's view (the runner catches
   * errors); the wire args mirror `QueueGraphReport` 1:1.
   */
  async reportQueueGraph(graph: QueueGraphReport): Promise<void> {
    await this.call("report_queue_graph", {
      queueName: graph.queueName,
      present: graph.present,
      backlog: graph.backlog,
      nodes: graph.nodes, // each: key, done, labels[], blockedBy[], + optional fields
    });
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
    /** (balanced BSP §12) Split the LARGEST pane in the target's tab along its longer
     *  side instead of using `direction` — the queue's default tiling, which self-heals
     *  when a pane closes. `targetUUID` then just anchors the tab. */
    balanced?: boolean;
    command: string;
    cwd?: string;
    firstTab?: boolean;
    /** (multi-tab overflow §12) When opening an OVERFLOW tab (`firstTab:true`), the UUID of a
     *  live pane of the SAME run so the new tab joins that pane's window — keeping all of a
     *  run's tabs in ONE window. Omitted for the run's very first tab (frontmost window). */
    windowAnchorUUID?: string;
    /** The item-context env (GHOSTTY_ITEM_*) for the launched agent (§13). Forwarded
     *  to the tool as `env`; the Swift handler sets it on the new split's
     *  environmentVariables. Omitted from the wire payload when empty/undefined. */
    env?: Record<string, string>;
  }): Promise<{ id: string; sessionId: number }> {
    const toolArgs: Record<string, unknown> = { command: args.command };
    if (args.targetUUID !== undefined) toolArgs.targetUUID = args.targetUUID;
    if (args.direction !== undefined) toolArgs.direction = args.direction;
    if (args.balanced !== undefined) toolArgs.balanced = args.balanced;
    if (args.cwd !== undefined) toolArgs.cwd = args.cwd;
    if (args.firstTab !== undefined) toolArgs.firstTab = args.firstTab;
    if (args.windowAnchorUUID !== undefined) toolArgs.windowAnchorUUID = args.windowAnchorUUID;
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
   * (Agent Queue, §12 continuous packing) move_surface_into_tab — MOVE an existing surface
   * (`sourceUUID`) into the TAB that holds `targetAnchorUUID`, as a balanced split, FOCUS-
   * PRESERVING. Used by the packer to consolidate a fragmented run's tabs (merge a whole tab
   * into an earlier one with room); the source tab closes when it empties. Throws McpError on
   * failure (the packer logs + retries next sweep). Reuses Ghostty's proven cross-tab/window
   * move primitive GUI-side.
   */
  async moveSurfaceIntoTab(args: {
    sourceUUID: string;
    targetAnchorUUID: string;
    balanced?: boolean;
  }): Promise<void> {
    await this.call("move_surface_into_tab", {
      sourceUUID: args.sourceUUID,
      targetAnchorUUID: args.targetAnchorUUID,
      ...(args.balanced !== undefined ? { balanced: args.balanced } : {}),
    });
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
   * (bell-attention) set_attention — set/clear the sticky "attention needed" STATE on
   * a surface (the loud Tier-2 treatment: strong tab marker, dashboard sort+highlight,
   * push). Distinct from `signal_attention` (a one-shot bell ring): this is a persistent
   * state the GUI clears on focus. The bell-attention pass calls it with `on:true` when
   * Haiku promotes a bell. `reason` is an optional human note. Throws McpError on failure.
   */
  async setAttention(id: string, on: boolean, reason?: string): Promise<void> {
    const args: Record<string, unknown> = { id, on };
    if (reason !== undefined) args.reason = reason;
    await this.call("set_attention", args);
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
   * (bell-attention v2 slice 4) wait_for_event long-poll. Parks server-side until a
   * matching event fires or `timeoutMs` elapses, returning the fired `{id,type}` or
   * `null` on timeout. The HTTP request timeout is set ABOVE the park timeout so the
   * fetch never aborts a still-parked wait (a spurious abort would look like a miss).
   * `types` defaults to bell-only; an empty `ids` matches any surface.
   */
  async waitForEvent(spec: {
    ids?: string[];
    types?: string[];
    timeoutMs: number;
  }): Promise<{ id: string; type: string } | null> {
    const payload = await this.call(
      "wait_for_event",
      {
        filter: { ids: spec.ids ?? [], types: spec.types ?? ["bell"] },
        timeoutMs: spec.timeoutMs,
      },
      spec.timeoutMs + 10000,
    );
    return parseWaitForEvent(payload);
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
    timeoutMs?: number,
  ): Promise<string> {
    const id = this.nextId++;
    const body = JSON.stringify({
      jsonrpc: "2.0",
      id,
      method: "tools/call",
      params: { name, arguments: args },
    });

    const controller = new AbortController();
    // A long-poll (wait_for_event) parks server-side up to its own timeout, so the
    // caller can pass a larger request timeout; default to the client's timeout.
    const timer = setTimeout(() => controller.abort(), timeoutMs ?? this.timeoutMs);
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

/**
 * (bell-attention v2 slice 4) Parse a `wait_for_event` tool payload. The wire shape is
 * `{"event":{"id","type",...}}` on a fired event and `{"event":null}` on timeout. PURE
 * + TOLERANT — exported for unit testing. Returns `{id,type}` only when both are strings;
 * anything else (timeout, malformed, missing fields) yields `null` (treated as "no event"
 * by the caller, which simply re-parks — never a throw).
 */
export function parseWaitForEvent(
  text: string,
): { id: string; type: string } | null {
  let obj: unknown;
  try {
    obj = JSON.parse(text);
  } catch {
    return null;
  }
  if (obj === null || typeof obj !== "object") return null;
  const ev = (obj as { event?: unknown }).event;
  if (ev === null || typeof ev !== "object") return null;
  const { id, type } = ev as { id?: unknown; type?: unknown };
  if (typeof id !== "string" || typeof type !== "string") return null;
  return { id, type };
}

/** The recognized control-command actions (§8a). */
const QUEUE_ACTIONS: ReadonlySet<string> = new Set([
  "start",
  "stop",
  "abort",
  "pause",
  "resume",
  "set_max_items",
  "set_concurrency",
]);

/**
 * Coerce an arbitrary parsed `take_queue_commands` payload into a clean `QueueCommand[]`.
 * PURE + TOLERANT — exported for unit testing. Accepts the `{commands:[...]}` envelope
 * (the wire shape). Anything else — a non-object, a missing/non-array `commands`, a
 * non-object entry, or an entry with an unrecognized `action` — yields `[]` / drops that
 * entry. Only `action`, `template`, `run`, `params`, `maxItems`, and `concurrency` are
 * carried (and only when correctly typed).
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
    // (live maxItems edit) the raw cap value for set_max_items — a string only.
    if (typeof r.maxItems === "string" && r.maxItems.length > 0) cmd.maxItems = r.maxItems;
    // (live concurrency edit) the raw value for set_concurrency — a string only.
    if (typeof r.concurrency === "string" && r.concurrency.length > 0) cmd.concurrency = r.concurrency;
    out.push(cmd);
  }
  return out;
}
