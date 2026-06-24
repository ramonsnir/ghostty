// (ramon fork / Agent Manager) Optional summarizer ACCOUNT routing. GENERIC and
// colleague-safe: by DEFAULT (no config) the summarizer inherits the ambient
// Claude Code auth — exactly the prior behavior, and it works on a machine with
// NO `claude-accounts`/`claude-pool` at all. When the user configures an account,
// the summarizer's single-shot model calls run with CLAUDE_CONFIG_DIR pointed at
// that account's config dir, so the (chatty) Haiku traffic bills against a
// SEPARATE account instead of draining the user's main pool.
//
// The spec is read from the GHOSTTY_AGENT_MANAGER_ACCOUNT env var (wins if set)
// or the file ~/.config/ghostty-ramon/agent-manager/account (a sibling of the
// summarizer.md/manager.md override files — same established config dir). It is:
//   - a BARE NAME (e.g. "dev")        -> <home>/.claude-accounts/<name>
//                                        (the claude-accounts convention)
//   - an ABSOLUTE or ~-prefixed PATH  -> used directly as CLAUDE_CONFIG_DIR
//   - a relative path containing "/"  -> used as-is (treated as a path)
// A spec that does NOT resolve to an existing directory is IGNORED (the caller
// warns + falls back to the ambient auth), so a stale name never breaks anyone.

import { join, isAbsolute } from "node:path";
import { statSync, readFileSync } from "node:fs";

import { OVERRIDE_DIR } from "./prompt.js";

/** The fixed sub-path (under the home dir) for the account spec file. */
export const ACCOUNT_RELPATH = [...OVERRIDE_DIR, "account"];

/** Resolve the absolute path to the account spec file for a given home dir. */
export function accountSpecPath(home: string): string {
  return join(home, ...ACCOUNT_RELPATH);
}

/** Injectable filesystem seam (for tests). */
export interface AccountFs {
  /** file contents, or null if it does not exist / cannot be read. */
  readText(path: string): string | null;
  /** true iff `path` exists and is a directory. */
  isDir(path: string): boolean;
}

/** Real-fs implementation of AccountFs (the production default). */
export const realAccountFs: AccountFs = {
  readText(path: string): string | null {
    try {
      return readFileSync(path, "utf8");
    } catch {
      return null;
    }
  },
  isDir(path: string): boolean {
    try {
      return statSync(path).isDirectory();
    } catch {
      return false;
    }
  },
};

/**
 * Read the raw account spec: the GHOSTTY_AGENT_MANAGER_ACCOUNT env var (when
 * non-empty after trimming) wins; otherwise the account file's contents (or null
 * when absent). The returned string is NOT trimmed — `resolveAccountDir` trims it.
 */
export function readAccountSpec(home: string, fs: AccountFs = realAccountFs): string | null {
  const env = process.env.GHOSTTY_AGENT_MANAGER_ACCOUNT;
  if (env !== undefined && env.trim() !== "") return env;
  return fs.readText(accountSpecPath(home));
}

/**
 * Resolve a raw spec to an absolute CLAUDE_CONFIG_DIR, or null when unset or when
 * it does not point at an existing directory. PURE over the injected fs seam.
 *
 * Empty/whitespace ⇒ null (inherit ambient auth). `~`/`~/x` expand against `home`.
 * An absolute path or any value containing "/" is treated as a path used as-is;
 * a bare token is a claude-accounts account name ⇒ <home>/.claude-accounts/<name>.
 * A resolved path that is not an existing directory ⇒ null (caller warns + inherits).
 */
export function resolveAccountDir(
  spec: string | null | undefined,
  home: string,
  fs: AccountFs = realAccountFs,
): string | null {
  const raw = spec?.trim();
  if (!raw) return null;

  let path: string;
  if (raw === "~") {
    path = home;
  } else if (raw.startsWith("~/")) {
    path = join(home, raw.slice(2));
  } else if (isAbsolute(raw) || raw.includes("/")) {
    path = raw; // an explicit path (absolute, or relative-with-slash)
  } else {
    path = join(home, ".claude-accounts", raw); // a bare account name
  }

  if (!fs.isDir(path)) return null; // stale/missing ⇒ inherit (caller warns)
  return path;
}
