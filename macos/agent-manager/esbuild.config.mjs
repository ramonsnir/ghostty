// (ramon fork / Agent Manager) Release bundling step. After `tsc` emits `dist/`,
// this RE-bundles the sidecar entry `dist/index.js` into a single self-contained
// ESM file with the Claude Agent SDK's JAVASCRIPT inlined — so the colleague DMG can
// ship `dist/` ONLY (no `node_modules`) and the summarizer's lazy
// `import("@anthropic-ai/claude-agent-sdk")` still resolves.
//
// THE WHOLE POINT (size + notarization): the SDK's native platform package
// `@anthropic-ai/claude-agent-sdk-darwin-arm64` contains a ~215MB arm64 `claude`
// Mach-O binary. We do NOT ship it (notarization hazard + huge). We never IMPORT it
// either — `model.ts` points the SDK at the colleague's ALREADY-INSTALLED `claude`
// via `pathToClaudeCodeExecutable` (GHOSTTY_CLAUDE_PATH), so the SDK's default
// executable-resolution (the only consumer of the native package) is bypassed. We
// mark that package EXTERNAL belt-and-suspenders so esbuild never pulls a Mach-O into
// the bundle; the result is ~MBs of pure JS.
//
// tsc still owns typecheck + the test build (`dist/**/*.test.js`); this only rewrites
// the runtime entry. Idempotent — re-running just rebuilds `dist/index.js`.

import { build } from "esbuild";
import { readFileSync, statSync } from "node:fs";

const OUT = "dist/index.js";

await build({
  entryPoints: ["dist/index.js"],
  outfile: OUT,
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  // Collapse banner-less; keep it readable-ish but minify to keep size down.
  minify: true,
  // Allow overwriting the entry in place (esbuild refuses an out == in without this).
  allowOverwrite: true,
  // NEVER bundle the 215MB native platform package — it is never imported at runtime
  // (we use the system `claude` via pathToClaudeCodeExecutable). Marking it external
  // means: if some default-path code path ever reaches for it, it throws a clean
  // module-not-found at runtime (which `summarize()` catches → self-disable) instead
  // of dragging a Mach-O into the notarized bundle.
  external: ["@anthropic-ai/claude-agent-sdk-darwin-arm64"],
  // ESM `import.meta.url` / dynamic import of the SDK are preserved/inlined by esbuild.
  logLevel: "info",
});

// Guard against accidentally inlining the 215MB native binary: a JS-only SDK bundle
// is a few MB. If the entry balloons, FAIL the build so a bad config can't ship a
// notarization-breaking Mach-O. (50MB is generous headroom over the ~MBs of JS.)
const bytes = statSync(OUT).size;
const MAX = 50 * 1024 * 1024;
if (bytes > MAX) {
  throw new Error(
    `bundle ${OUT} is ${(bytes / 1024 / 1024).toFixed(1)}MB (> ${MAX / 1024 / 1024}MB) — ` +
      `a native binary likely got inlined; check the 'external' list`,
  );
}
// Sanity: the bundle must NOT carry a Mach-O magic header (0xCAFEBABE / 0xFEEDFACF).
// Cheap check on the first bytes — a JS file starts with text.
const head = readFileSync(OUT).subarray(0, 4);
const magic = head.readUInt32BE(0);
if (
  magic === 0xcafebabe || // universal/fat Mach-O
  magic === 0xcafed00d || // (java class is cafebabe too; both flagged — neither is valid JS head)
  magic === 0xfeedface || // 32-bit Mach-O
  magic === 0xfeedfacf // 64-bit Mach-O
) {
  throw new Error(`bundle ${OUT} starts with a Mach-O magic header — native binary inlined`);
}

console.log(
  `agent-manager: bundled ${OUT} (${(bytes / 1024 / 1024).toFixed(1)}MB, SDK JS inlined, no native binary)`,
);
