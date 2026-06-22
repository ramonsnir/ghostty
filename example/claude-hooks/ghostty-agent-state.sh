#!/usr/bin/env bash
# (ramon fork / Agent hooks) Claude Code hook -> Ghostty MCP `/agent-state`.
#
# Invoked by Claude Code's hook machinery (see settings-hooks.json) with the
# agent state as the first CLI arg:
#
#     ghostty-agent-state.sh <working|waiting|idle>
#
# It derives the controlling tty of the terminal Claude Code is running in,
# best-effort extracts a tool/prompt/message hint from the hook JSON on stdin,
# and fires a single fire-and-forget POST to the in-GUI MCP server at
# http://127.0.0.1:<port>/agent-state. The Ghostty MCP handler resolves the tty
# to the matching terminal surface (via the host-pushed foreground pid) and
# drives the Agent Dashboard tile's per-tile agent state + a Web Push on
# "waiting". GUI + hooks only — there is no host change.
#
# Design: the hook MUST NEVER block or fail the agent. Everything is best-effort:
# a missing server, missing token, or missing tty just makes the POST a silent
# no-op (curl is backgrounded with a tight --max-time and all output discarded),
# and the script always `exit 0`s immediately.
#
# Setup:
#   1. Copy this script to ~/.config/ghostty-ramon/claude-hooks/ and chmod +x it.
#   2. Merge settings-hooks.json into ~/.claude/settings.json.
# See AGENT-DASHBOARD.md for the full walkthrough.

# Never let an error here surface to Claude Code.
set +e

state="$1"
case "$state" in
  working|waiting|idle) ;;
  *) exit 0 ;;   # unknown/blank state: nothing to report
esac

# --- stdin: the Claude Code hook event JSON (best-effort) --------------------
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
    # PreToolUse carries tool_name; UserPromptSubmit/SessionStart carry prompt.
    # We extract BOTH unconditionally: a given event only ever carries one, so the
    # other resolves to empty and is omitted from the POST. This is intentional —
    # it keeps one code path for all three "working" triggers.
    tool="$(json_field tool_name)"
    prompt="$(json_field prompt)"
    ;;
  waiting)
    message="$(json_field message)"
    ;;
esac

# --- tty: the surface's controlling terminal ---------------------------------
# Claude Code runs in the terminal surface, so this script's controlling tty is
# the surface's tty. `ps -o tty=` is the portable read; fall back to the `tty`
# builtin if ps yields the no-tty marker "??".
tty="$(ps -o tty= -p "$$" 2>/dev/null | tr -d ' ')"
if [ -z "$tty" ] || [ "$tty" = "??" ] || [ "$tty" = "?" ]; then
  tty="$(tty 2>/dev/null)"
  case "$tty" in
    "not a tty"|"") tty="" ;;
  esac
fi
# No tty -> the MCP handler can't correlate; nothing to do.
[ -n "$tty" ] || exit 0

# --- token: env var, else the per-machine secret file ------------------------
token="${GHOSTTY_MCP_TOKEN:-}"
if [ -z "$token" ]; then
  token="$(sed -n 's/^mcp-token *= *//p' "$HOME/.config/ghostty-ramon/local" 2>/dev/null | head -1)"
fi

# --- stamp-file debounce (the chatty `working`/PreToolUse path ONLY) ---------
# NOTE the debounce applies to ALL `working` events (UserPromptSubmit, PreToolUse,
# AND SessionStart share the `working` arg, so this script cannot tell them apart).
# That is fine: PreToolUse is the chatty one this guards, and in the common turn
# order UserPromptSubmit stamps first and the immediately-following PreToolUse is
# correctly swallowed. The rare reverse edge (a SessionStart stamp <1s before a
# UserPromptSubmit) can drop the prompt POST; that loss is accepted (the prompt
# subtitle is a display hint, and app-side coalescing is a second line of defense).
# `waiting`/`idle` (Notification/Stop/SessionEnd) are rare/meaningful and never
# debounced. macOS `stat -f %m` is whole-seconds, so a 1s floor is used when
# sub-second mtime is unavailable (see SPEC §1.4 / §3.1.4).
#
# Security: the stamp lives in a PRIVATE per-user dir ($TMPDIR — per-user 0700
# /var/folders — or, only if unset, ~/.cache/ghostty-ramon which we create). We do
# NOT fall back to world-writable /tmp: a predictable name there (tty names are
# enumerable) under a truncating `: > "$stamp"` redirect would let a local attacker
# pre-create the path as a symlink and have us clobber a victim file. We also write
# under `set -C` (noclobber) so even within the private dir a pre-existing symlink
# is never followed by the truncating create.
if [ "$state" = "working" ]; then
  if [ -n "$TMPDIR" ]; then
    stamp_dir="$TMPDIR"
  else
    stamp_dir="$HOME/.cache/ghostty-ramon"
    mkdir -p "$stamp_dir" 2>/dev/null
  fi
  safe_tty="$(printf '%s' "$tty" | tr '/' '_')"
  stamp="${stamp_dir}/ghostty-agent-${safe_tty}"
  now="$(date +%s)"
  if [ -f "$stamp" ]; then
    # Sub-second where available (GNU stat %.Y); else whole-second macOS stat.
    last="$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null)"
    if [ -n "$last" ]; then
      delta=$(( now - last ))
      # 1s floor for the ~750ms intent (whole-second mtime resolution).
      if [ "$delta" -lt 1 ]; then
        exit 0
      fi
    fi
  fi
  # Refresh the stamp's mtime. Under `set -C` (noclobber) a pre-existing symlink at
  # this path makes the create fail instead of following it; in that case `touch`
  # an existing regular file (it won't create through a dangling symlink) so the
  # debounce still advances without ever clobbering a symlink target.
  if [ -f "$stamp" ] && [ ! -h "$stamp" ]; then
    : > "$stamp" 2>/dev/null
  else
    ( set -C; : > "$stamp" ) 2>/dev/null
  fi
fi

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

esc_tty="$(json_escape "$tty")"
tool_field=""
prompt_field=""
msg_field=""
[ -n "$tool" ]    && tool_field=",\"tool\":\"$(json_escape "$tool")\""
[ -n "$prompt" ]  && prompt_field=",\"prompt\":\"$(json_escape "$prompt")\""
[ -n "$message" ] && msg_field=",\"message\":\"$(json_escape "$message")\""

body="$(printf '{"tty":"%s","state":"%s"%s%s%s}' \
  "$esc_tty" "$state" "$tool_field" "$prompt_field" "$msg_field")"

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
