#!/usr/bin/env bash
# (ramon fork / Agent hooks) Codex CLI hook -> Ghostty MCP `/agent-state`.
#
# The Codex-CLI twin of example/claude-hooks/ghostty-agent-state.sh. Invoked by
# Codex's hook machinery (see this dir's hooks.json, merged into ~/.codex/hooks.json)
# with the agent state as the first CLI arg:
#
#     ghostty-agent-state.sh <working|waiting|idle>
#
# Codex's hook event -> state mapping (hooks.json):
#     SessionStart / UserPromptSubmit / PreToolUse -> working
#     PermissionRequest                            -> waiting   (needs your approval)
#     Stop / SessionEnd                            -> idle
#
# It derives the controlling tty of the terminal Codex is running in, best-effort
# extracts a tool/prompt/message hint from the hook JSON on stdin, and fires a
# single fire-and-forget POST to the in-GUI MCP server at
# http://127.0.0.1:<port>/agent-state. The Ghostty MCP handler resolves the tty to
# the matching terminal surface (via the host-pushed foreground pid) and drives the
# Agent Dashboard tile's per-tile agent state + a Web Push on "waiting". The POST
# carries `"kind":"codex"` so a cross-host / hook-only surface is labeled codex (not
# the hook-implied claude default). GUI + hooks only — there is no host change.
#
# Codex's stdin JSON uses the SAME field names Claude Code does — `session_id`,
# `cwd`, `tool_name`, `prompt` — so the extraction below is shared verbatim; the one
# Codex-specific nicety is falling back to `last_assistant_message` for the waiting
# hint (Codex has no `message` field). See CODEX-HOOKS.md for the full walkthrough.
#
# Design: the hook MUST NEVER block or fail the agent. Everything is best-effort:
# a missing server, missing token, or missing tty just makes the POST a silent
# no-op (curl is backgrounded with a tight --max-time and all output discarded),
# and the script always `exit 0`s immediately.
#
# Setup:
#   1. Copy this script to ~/.config/ghostty-ramon/codex-hooks/ and chmod +x it.
#   2. Merge hooks.json into ~/.codex/hooks.json, then run Codex's `/hooks` once to
#      TRUST it (Codex refuses to run an untrusted, non-managed hook).
# The in-GUI installer ("Install Agent Hooks") does step 1-2 for you.
#
# (cloud-hosts) REMOTE self-ID via a correlation nonce
# ----------------------------------------------------
# When Ghostty spawns an agent on a REMOTE ghostty-host box it injects ONE thing:
# a non-secret per-spawn correlation nonce (GHOSTTY_SURFACE_NONCE), via the
# spawn's initial input, which crosses to the box. The box cannot walk a process
# tree to a laptop-side tty, so this hook detects that env and POSTs
# {nonce, state} instead of {tty, state} — the MCP `/agent-state` route resolves
# the nonce to the (host, session id) via the GUI's nonce map. The tty-walk below
# is the LOCAL fallback (used when the nonce is absent). Identical to the Claude
# twin; a remote Codex agent lights up a cross-host tile exactly like a remote
# Claude one, and the `"kind":"codex"` field keeps the tile labeled correctly.
#
# The MCP ingest URL (GHOSTTY_MCP_URL, e.g. an https tailnet URL fronted by
# `tailscale serve`) is NOT injected by the GUI — it is a per-box, laptop-facing
# value, so provision it in the BOX's own environment (its ghostty-host systemd
# unit `Environment=GHOSTTY_MCP_URL=…`, or a shell profile), where the spawned
# shells inherit it. With no URL in the box environment this remote branch is a
# silent no-op. See CLOUD-HOSTS-DESIGN.md → Deployment.
#
# The token authorizing the remote POST is a PER-BOX, CAPABILITY-SCOPED token
# (authorizes /agent-state ingest ONLY, never /mcp spawn/input) — it is NOT the
# laptop's master mcp-token. Provision it ONCE per box into a 0600 file (default
# ~/.config/ghostty-ramon/mcp-capability-token; override GHOSTTY_MCP_TOKEN_FILE):
#
#     umask 077
#     printf '%s' "<per-box-capability-token>" \
#       > "$HOME/.config/ghostty-ramon/mcp-capability-token"
#     chmod 600 "$HOME/.config/ghostty-ramon/mcp-capability-token"
#
# The token is read from that file and fed to curl via `-K -` (a config file on
# stdin), NEVER on argv — the same leak-avoidance the local path uses below.
# Rotate it per box.

# Never let an error here surface to Codex.
set +e

# (ramon fork / Agent Manager) Hook-recursion guard. The Agent Manager sidecar
# sets GHOSTTY_AGENT_MANAGER=1 in the environment of any agent it spawns, so its
# own (current/future) agent activity does NOT loop back through this hook and
# re-POST agent-state. Exit immediately when set.
[ -n "$GHOSTTY_AGENT_MANAGER" ] && exit 0

state="$1"
case "$state" in
  working|waiting|idle) ;;
  *) exit 0 ;;   # unknown/blank state: nothing to report
esac

# --- stdin: the Codex hook event JSON (best-effort) --------------------------
# We do NOT require it to parse; we only fish out a tool_name / prompt / message
# hint when present so the dashboard tile can show context. Read with a short
# timeout so a hook wired without stdin can't hang us.
stdin_json=""
if [ ! -t 0 ]; then
  stdin_json="$(cat 2>/dev/null)"
fi

# Extract one string field from the (shallow) hook JSON. Prefer python3 for
# correct JSON handling; fall back to a tolerant sed if python3 is absent.
json_field() {
  field="$1"
  [ -n "$stdin_json" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$stdin_json" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d,dict): sys.exit(0)
v=d.get(sys.argv[1])
if isinstance(v,str): sys.stdout.write(v)
' "$field" 2>/dev/null
  else
    # Tolerant fallback: first "field":"value" occurrence, unescaped naively.
    printf '%s' "$stdin_json" \
      | sed -n 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -1
  fi
}

tool=""
prompt=""
message=""
case "$state" in
  working)
    # PreToolUse carries tool_name; UserPromptSubmit carries prompt. We extract
    # BOTH unconditionally: a given event only ever carries one, so the other
    # resolves to empty and is omitted from the POST. One code path for all three
    # "working" triggers (SessionStart / UserPromptSubmit / PreToolUse).
    tool="$(json_field tool_name)"
    prompt="$(json_field prompt)"
    ;;
  waiting)
    # PermissionRequest: Codex has no `message` field, so fall back to the
    # last assistant message, then to the tool name being approved.
    message="$(json_field message)"
    [ -n "$message" ] || message="$(json_field last_assistant_message)"
    [ -n "$message" ] || message="$(json_field tool_name)"
    ;;
esac

# --- JSON-escape a string for safe interpolation -----------------------------
# Drop ALL C0 control bytes (0x00–0x1F, incl. CR/LF/TAB) then escape backslashes
# and double-quotes. A raw control byte (e.g. a TAB in a prompt) is invalid in a
# JSON string per RFC 8259, so JSONSerialization in MCPAgentState.parse would
# reject the whole body (400) and the event would be silently lost; dropping the
# control bytes here keeps the hint best-effort lossy rather than dropping the
# event. (We strip rather than \uXXXX-escape: these are display hints, not data.)
json_escape() {
  printf '%s' "$1" \
    | tr -d '\000-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# --- session_id + cwd: passive capture for suspend/resume ---------------------
# (ramon fork / suspend-resume) Codex passes `session_id` (its OWN resume token —
# `codex-pool --resume <id>`) and `cwd` on the stdin JSON of every hook event.
# Capture both passively here so the fork can later suspend an idle Codex split
# (kill the child to reclaim RAM, keep the split) and Resume it in the same dir —
# exactly like the Claude path. The wire field is named `claudeSessionId` for
# historical reasons; it carries whichever agent's resume id (see MCPAgentState).
# Best-effort like the rest: empty ⇒ the field is simply omitted from the POST.
claude_session_id="$(json_field session_id)"
cwd="$(json_field cwd)"
sid_field=""
cwd_field=""
[ -n "$claude_session_id" ] && sid_field=",\"claudeSessionId\":\"$(json_escape "$claude_session_id")\""
[ -n "$cwd" ]               && cwd_field=",\"cwd\":\"$(json_escape "$cwd")\""

# --- CODEX_HOME: the account home that owns this session's rollout ------------
# (suspend-resume, Codex) Codex resume is `codex resume <id>` and reads the
# rollout from $CODEX_HOME/sessions — so a suspended session can ONLY be resumed
# under the SAME home that created it. An account pool points CODEX_HOME at an
# EPHEMERAL <pool>/creds SYMLINK whose target is the durable account home, and
# that symlink is torn down when the pooled run exits. So resolve to the PHYSICAL
# path (`pwd -P` follows the symlink) — that durable dir is where the rollout
# actually lives and is still valid after the pool dir is gone. Default home when
# CODEX_HOME is unset. The GUI records this so Resume can pin it (see MCPAgentState
# + SuspendManifest). Empty ⇒ the field is simply omitted.
codex_home="$(cd "${CODEX_HOME:-$HOME/.codex}" 2>/dev/null && pwd -P || printf '%s' "${CODEX_HOME:-$HOME/.codex}")"
codexhome_field=""
[ -n "$codex_home" ] && codexhome_field=",\"codexHome\":\"$(json_escape "$codex_home")\""

# --- REMOTE self-ID: POST {nonce, state} when spawned on a cloud box ----------
# (cloud-hosts, D6.) A remote-spawned agent carries GHOSTTY_SURFACE_NONCE (a
# non-secret per-spawn correlation id, GUI-injected via the spawn's initial
# input). GHOSTTY_MCP_URL (the full ingest URL) comes from the BOX's own
# environment. Correlate by nonce — the box has no laptop-side tty to walk to —
# and authorize with the PER-BOX capability token from a 0600 file (see the
# header comment). Best-effort + fire-and-forget; any missing piece is a silent
# no-op. The tty-walk below is the local fallback (nonce unset).
if [ -n "$GHOSTTY_SURFACE_NONCE" ]; then
  url="${GHOSTTY_MCP_URL:-}"
  [ -n "$url" ] || exit 0

  cap_token_file="${GHOSTTY_MCP_TOKEN_FILE:-$HOME/.config/ghostty-ramon/mcp-capability-token}"
  cap_token="$(head -1 "$cap_token_file" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$cap_token" ] || exit 0

  esc_nonce="$(json_escape "$GHOSTTY_SURFACE_NONCE")"
  tool_field=""
  prompt_field=""
  msg_field=""
  [ -n "$tool" ]    && tool_field=",\"tool\":\"$(json_escape "$tool")\""
  [ -n "$prompt" ]  && prompt_field=",\"prompt\":\"$(json_escape "$prompt")\""
  [ -n "$message" ] && msg_field=",\"message\":\"$(json_escape "$message")\""
  body="$(printf '{"nonce":"%s","state":"%s","kind":"codex"%s%s%s%s%s%s}' \
    "$esc_nonce" "$state" "$tool_field" "$prompt_field" "$msg_field" "$sid_field" "$cwd_field" "$codexhome_field")"

  printf 'header = "X-Ghostty-Token: %s"\n' "$cap_token" \
    | curl -fsS --max-time 2 -K - \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$body" >/dev/null 2>&1 &
  exit 0
fi

# --- tty: the surface's controlling terminal ---------------------------------
# Codex may spawn a hook on the SAME tty (the walk finds it at $$ immediately) or
# detached (own tty is "??"); either way, walk UP the ppid chain and take the
# nearest ancestor with a real tty — the codex process itself runs on it. Stop at
# init/no-parent or after a bounded number of hops.
tty=""
_pid="$$"
_hops=0
while [ -n "$_pid" ] && [ "$_pid" != "0" ] && [ "$_pid" != "1" ] && [ "$_hops" -lt 12 ]; do
  _t="$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d ' ')"
  case "$_t" in
    ""|"??"|"?") : ;;            # no tty at this level — keep walking up
    *) tty="$_t"; break ;;
  esac
  _pid="$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')"
  _hops=$(( _hops + 1 ))
done
# No tty anywhere up the chain -> the MCP handler can't correlate; nothing to do.
[ -n "$tty" ] || exit 0

# --- token: env var, else the per-machine secret file ------------------------
token="${GHOSTTY_MCP_TOKEN:-}"
if [ -z "$token" ]; then
  token="$(sed -n 's/^mcp-token *= *//p' "$HOME/.config/ghostty-ramon/local" 2>/dev/null | head -1)"
fi

# --- stamp-file debounce (the chatty `working`/PreToolUse path ONLY) ---------
# Identical to the Claude twin: the debounce applies to ALL `working` events
# (SessionStart / UserPromptSubmit / PreToolUse share the `working` arg). The
# stamp lives in a PRIVATE per-user dir ($TMPDIR — per-user 0700 /var/folders —
# or ~/.cache/ghostty-ramon), written under `set -C` (noclobber) so a pre-existing
# symlink is never followed. `waiting`/`idle` are rare/meaningful and never
# debounced. macOS `stat -f %m` is whole-seconds, so a 1s floor is used.
if [ "$state" = "working" ]; then
  if [ -n "$TMPDIR" ]; then
    stamp_dir="$TMPDIR"
  else
    stamp_dir="$HOME/.cache/ghostty-ramon"
    mkdir -p "$stamp_dir" 2>/dev/null
  fi
  safe_tty="$(printf '%s' "$tty" | tr '/' '_')"
  stamp="${stamp_dir}/ghostty-agent-codex-${safe_tty}"
  now="$(date +%s)"
  if [ -f "$stamp" ]; then
    last="$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null)"
    if [ -n "$last" ]; then
      delta=$(( now - last ))
      if [ "$delta" -lt 1 ]; then
        exit 0
      fi
    fi
  fi
  if [ -f "$stamp" ] && [ ! -h "$stamp" ]; then
    : > "$stamp" 2>/dev/null
  else
    ( set -C; : > "$stamp" ) 2>/dev/null
  fi
fi

esc_tty="$(json_escape "$tty")"
tool_field=""
prompt_field=""
msg_field=""
[ -n "$tool" ]    && tool_field=",\"tool\":\"$(json_escape "$tool")\""
[ -n "$prompt" ]  && prompt_field=",\"prompt\":\"$(json_escape "$prompt")\""
[ -n "$message" ] && msg_field=",\"message\":\"$(json_escape "$message")\""

body="$(printf '{"tty":"%s","state":"%s","kind":"codex"%s%s%s%s%s%s}' \
  "$esc_tty" "$state" "$tool_field" "$prompt_field" "$msg_field" "$sid_field" "$cwd_field" "$codexhome_field")"

# --- fire-and-forget POST ----------------------------------------------------
# Tight --max-time so a hung/absent server never stalls the agent. Backgrounded
# and detached; all output discarded; we exit 0 immediately. The Release MCP
# default port is 8765; GHOSTTY_MCP_PORT overrides for dev builds (8766/8767).
port="${GHOSTTY_MCP_PORT:-8765}"
url="http://127.0.0.1:${port}/agent-state"

if [ -n "$token" ]; then
  # Feed the token header via a curl config file on STDIN (`-K -`) rather than
  # an `-H` argv flag, so the MCP token (a shell-execution credential) never
  # appears in this curl's process argument list, where another local user
  # could snoop it with `ps -ww`. The body still rides argv (it is not secret).
  printf 'header = "X-Ghostty-Token: %s"\n' "$token" \
    | curl -fsS --max-time 2 -K - \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$body" >/dev/null 2>&1 &
else
  curl -fsS --max-time 2 \
    -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "$body" >/dev/null 2>&1 &
fi

exit 0
