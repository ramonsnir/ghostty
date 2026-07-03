# SHARED-QUEUES-SPEC — shareable Agent Queue templates

**Status:** IMPLEMENTED (this spec is the authoritative design; the code matches it).
**Revision 1** — line numbers + the provider-exec / palette-delegation / sidecar-dedup
descriptions reconciled against the shipped code (`queue/*.ts`, `QueuePalette.swift`,
`AgentManagerController.swift`, `Config.zig`).

**Goal.** Make Agent Queue *templates* shareable from a repo (e.g. a shared git repo) **in
addition to** the personal `~/.config/ghostty-ramon/agent-manager/queues` dir, via two
mechanisms plus a docs-only hygiene note:

- **Mechanism 1 — multi-location discovery.** `agent-queue-templates-dir` becomes a
  *list* (RepeatableString, like `project-directory`). Both readers — the macOS palette
  and the sidecar loader — iterate an ordered **search path** (default dir first, then
  each configured dir) with **first-in-search-order-wins** basename collision.
- **Mechanism 2 — the `{templateDir}` portability token.** A template's `provider.*`
  commands / `agent.command` / param `valuesCommand`s may reference their own sibling
  scripts via the literal token `{templateDir}`, which the TS loader substitutes with the
  template file's own resolved directory. `GHOSTTY_QUEUE_TEMPLATE_DIR` is also exported
  into the provider exec env and the spawned agent split env.

This spec FORMALIZES the fixed wire contract below into a file-by-file implementation.
No behavior may deviate from the contract.

---

## 0. Fixed wire contract (authoritative — do not deviate)

1. **Config key name stays `agent-queue-templates-dir`**, now a RepeatableString / list
   (like `project-directory`).
2. **Effective search path** = `[ default ~/.config/ghostty-ramon/agent-manager/queues ]`
   FIRST, then each configured dir in config order; **dedup by canonical/resolved path**;
   the **default is ALWAYS included first**.
3. **Basename collision across dirs: FIRST-in-search-order WINS** (personal/default
   overrides a shared repo dir).
4. **Env var GUI→sidecar: `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS`** = the FULL search path
   (default + configured), already tilde-expanded macOS-side, joined by a single
   **NEWLINE (`\n`)**. BACK-COMPAT: the sidecar also reads the old singular
   `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR` as a **one-element list** when the plural is absent.
5. **Portability token: the literal string `{templateDir}`** — substituted with the
   template file's OWN resolved directory (**NO trailing slash**) in:
   `provider.list.command`, `provider.status.command`, `provider.graph.command`,
   `agent.command` (a string), and every param `valuesCommand`. Substitution happens in
   the TS loader AFTER the template dir is known, BEFORE any exec. Also export env
   `GHOSTTY_QUEUE_TEMPLATE_DIR` (= that dir) into BOTH the provider exec env AND the
   spawned agent split env, so scripts can find their siblings.
6. **Rehydration determinism:** `active-runs.json` must record the RESOLVED template file
   path (or dir) so a restart re-resolves the SAME file even if a later-added dir shadows
   the basename.

> **Contract note (flag for maintainer, do NOT silently expand):** item 5 lists
> `list` / `status` / `graph` command + `agent.command` + `valuesCommand`. It does **not**
> list `provider.claim.command`. This spec implements EXACTLY the contract set; if
> claim-script portability is desired, raise it — it is a one-line addition to
> `substituteTemplateDir` but is intentionally out of scope here.

---

## 1. Effective search-path algorithm (exact)

**This algorithm is the GUI-side (macOS) builder, and it is AUTHORITATIVE.** The GUI
computes the canonical dedup key, dedups, and emits the final ordered list over
`GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS`. The sidecar does NOT recompute this canonical key —
it consumes the list verbatim (see the note after the bullets). The two layers therefore
do **not** need equivalent canonicalization; only the GUI's matters for dedup.

Given the configured list `configured: string[]` (config order, may be empty) and the
constant default dir `D = "~/.config/ghostty-ramon/agent-manager/queues"`:

```
searchPath(configured, D):                # GUI-side / macOS — authoritative
  raw   = [D] ++ configured          # default ALWAYS first
  seen  = {}                         # set of canonical keys
  out   = []
  for dir in raw:
    e = tildeExpand(dir)             # ~/… → absolute; already-absolute passes through
    e = standardize(e)               # NSString.standardizingPath (the authoritative key)
    if e is empty: continue
    k = canonical(e)                 # dedup key = the standardized absolute path
    if k in seen: continue
    seen.add(k)
    out.push(e)
  return out
```

- **Order-preserving, default-first, deduped.** The dedup key is the standardized
  absolute path produced by `NSString.standardizingPath` (do NOT `realpath`/resolve
  symlinks — a symlink is a legitimate distinct entry; `standardizingPath` expands `~`,
  collapses `.` / `..` / duplicate separators, and may resolve some symlinks, all of which
  is fine for a dedup key).
- macOS builds this and joins with `"\n"` into `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS`.
- **The sidecar uses the list VERBATIM — it does NO dedup and NO re-canonicalization.** It
  receives the list already tilde-expanded and deduped by the GUI's authoritative
  `standardizingPath` key, and it ONLY splits on `"\n"`, trims each line, and drops
  empty/blank lines (§6.2 `parseTemplatesDirs` — no dedup step at all). This is deliberate:
  the two layers do NOT and need NOT compute the same canonical key. TS has no equivalent of
  `standardizingPath` — `path.resolve` neither expands `~` nor collapses symlinks and is
  cwd-relative, so any sidecar-side canonicalization would be a strictly WEAKER, potentially
  DIFFERENT key that could reorder or wrongly-merge entries the GUI intentionally kept. So
  the GUI's standardized key is the SINGLE source of dedup truth; the sidecar's only job is
  to honor the GUI's ordering and first-wins collision, which it does by iterating the list
  AS GIVEN (first-wins basename resolution below walks `searchPath` in order).

**Basename resolution (first-wins).** To resolve a template basename `b` to a file:

```
resolveTemplatePath(searchPath, b):
  for dir in searchPath:            # already default-first, deduped
    p = join(dir, b + ".json")
    if exists(p): return p          # FIRST hit wins
  return null
```

**Discovery (palette listing).** Enumerate each dir in search order; the FIRST dir that
contains `<b>.json` owns basename `b`; later dirs' same-basename files are shadowed. A
basename present in more than one search dir is flagged as a **duplicate** so the palette
can badge its winning source dir (see §5.4).

---

## 2. `{templateDir}` substitution rules (exact)

- **Token:** the literal 12-char string `{templateDir}` (case-sensitive, braces included).
- **Replacement value:** the template file's own resolved directory = `dirname(resolvedPath)`,
  which carries **no trailing slash** (Node `path.dirname` and Foundation both guarantee
  this).
- **When:** in the TS loader, AFTER the file path is resolved and loaded/validated, BEFORE
  the template is handed to the runner (so every downstream exec already sees literal
  paths). Applied in the same impure seam that already `expandHome`s `workdir`.
- **Where (the contract's five sites, and ONLY these):**
  - `template.provider.list.command: string[]`
  - `template.provider.status.command: string[]`
  - `template.provider.graph?.command: string[]` (only when present)
  - `template.agent.command: string` (a single string)
  - each `template.params[i].valuesCommand?: string[]` (only when present)
- **Substring, not whole-element.** Unlike `{key}` (a whole-argv-element swap in
  `renderArgv`), `{templateDir}` is a **substring** replace within each string, so
  `["python3", "{templateDir}/list.py"]` → `["python3", "<dir>/list.py"]`. ALL occurrences
  in a string are replaced (`s.split("{templateDir}").join(dir)`).
- **No-op safety.** A template with no token is byte-identical after substitution.

---

## 3. Rehydration determinism (record change)

- `ActiveRunRecord` gains an OPTIONAL `templatePath?: string` = the RESOLVED absolute path
  the run was loaded from (not just the basename).
- A `QueueRun` carries the resolved `templatePath` (and its derived `templateDir =
  dirname(templatePath)`), set by the run factory at `start` time.
- `activeRunRecords(...)` persists `run.templatePath` into each record.
- `rehydrateActiveRuns(...)` prefers `rec.templatePath`: if it is a non-empty string AND
  the file still exists, load from that EXACT path (so a later-added dir that shadows the
  basename cannot re-point a running queue). Otherwise fall back to
  `resolveTemplatePath(searchPath, rec.template)` (back-compat with pre-this-change
  records and with a moved file). If neither resolves, drop the run with a logged error
  (unchanged from today).
- `parseActiveRuns` tolerantly carries `templatePath` (kept only when a non-empty string);
  `serializeActiveRuns` round-trips it.

---

## 4. Zig core changes

### 4.1 `src/config/Config.zig`

- **Field (currently L3005):** change
  ```zig
  @"agent-queue-templates-dir": ?[:0]const u8 = null,
  ```
  to
  ```zig
  @"agent-queue-templates-dir": RepeatableString = .{},
  ```
  Model exactly on `@"project-directory": RepeatableString = .{},` (L2908) and
  `@"agent-dashboard-commands"` (L2924). The `RepeatableString` type (L6363) already
  provides `parseCLI`/`clone`/`equal`/`formatEntry`/`cval` and its C view
  (`list_c` + `C { items, len }`), so **no new plumbing** is needed — the generic
  `ghostty_config_get` path returns it as `ghostty_config_string_list_s` (the same
  bridge `project-directory` uses). **No `src/config/CApi.zig` or `include/ghostty.h`
  change** (the `ghostty_config_string_list_s` typedef at ghostty.h:558 already exists).
- **Doc comment (L2995–3005):** rewrite to describe a REPEATABLE list of BASE dirs holding
  queue TEMPLATE JSON files; keep the leading `(ramon fork / Agent Queue Supervisor)`
  prefix (load-bearing: the MCP fork-only-key detector keys off `(ramon fork`). State:
  each entry is a directory searched for `*.json` templates; the built-in default
  `~/.config/ghostty-ramon/agent-manager/queues` is ALWAYS searched FIRST, then each
  configured dir in order; a basename found in more than one dir resolves to the
  first-in-search-order copy; `~` is expanded macOS-side. Remove the old
  `[:0]const u8`/`ghostty_config_get`-scalar NOTE (no longer applies).
- **Test (existing `test "agent-queue: parse and default"`, L11733):** remove the two
  templates-dir scalar assertions (the `== null` at L11742 and the `expectEqualStrings …
  .?` at L11757–11760) plus its `--agent-queue-templates-dir=…` iter arg (L11751); leave
  the `agent-queue` bool + `agent-queue-max-total` assertions intact.
- **New test `test "agent-queue-templates-dir: RepeatableString parse"`** (place beside
  the agent-queue tests; mirror the `RepeatableString cval*` tests at L6544+):
  - default: `cfg.@"agent-queue-templates-dir".list.items.len == 0`.
  - single `--agent-queue-templates-dir=/a/b` → `list.items.len == 1`, item `== "/a/b"`.
  - two flags `/a/b` then `/c/d` → `len == 2`, order preserved (`[0]=="/a/b"`, `[1]=="/c/d"`).
  - empty value `--agent-queue-templates-dir=` resets to `len == 0`.
  - **cval C-list view:** after two entries, `cval().len == 2` and
    `sliceTo(cval().items[0],0) == "/a/b"`, `[1] == "/c/d"` (mirror `RepeatableString cval`).
  - **round-trip:** `formatEntry` yields `agent-queue-templates-dir = /a/b\nagent-queue-templates-dir = /c/d\n`
    (mirror `formatConfig multiple items`).

---

## 5. macOS (Swift) changes

### 5.1 `macos/Sources/Ghostty/Ghostty.Config.swift`

- **Replace** the scalar getter `agentQueueTemplatesDir: String?` (L1001–1009) with a LIST
  getter mirroring `projectDirectories` (L820–828):
  ```swift
  // (ramon fork / Agent Queue Supervisor) The CONFIGURED template search dirs
  // (repeatable). Empty when unset; the default dir is prepended by the effective
  // search-path builder, not here.
  var agentQueueTemplatesDirs: [String] {
      guard let config = self.config else { return [] }
      var v: ghostty_config_string_list_s = .init()
      let key = "agent-queue-templates-dir"
      guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return [] }
      guard v.len > 0 else { return [] }
      let buffer = UnsafeBufferPointer(start: v.items, count: Int(v.len))
      return buffer.compactMap { $0.map { String(cString: $0) } }
  }
  ```
  Remove the old scalar getter entirely (callers are updated below).

### 5.2 `macos/Sources/Features/MCP/MCPKnowledge.swift`

- **Reader table (L72):** replace
  `("agent-queue-templates-dir", { $0.agentQueueTemplatesDir ?? "" }),`
  with a list join, e.g.
  `("agent-queue-templates-dir", { $0.agentQueueTemplatesDirs.joined(separator: ", ") }),`
  (display-only string for `get_effective_config`). The key name is unchanged, so
  `readersIncludeAllForkOnlyKeys` / `featureDocsCoverAllForkOnlyKeys` coverage is unaffected.

### 5.3 `macos/Sources/Features/AgentManager/AgentManagerController.swift`

- **Stored input:** replace the field `private let agentQueueTemplatesDir: String?` (L71)
  with `private let agentQueueTemplatesDirs: [String]`; in `init` (L118) set it from
  `ghostty.config.agentQueueTemplatesDirs`.
- **Default constant:** add
  `static let defaultTemplatesDir = "~/.config/ghostty-ramon/agent-manager/queues"`
  with a comment "keep in sync with `QueuePaletteView.defaultTemplatesDir` and the sidecar
  `QUEUES_DIR`".
- **`applyAgentQueueEnv` (L352):** change the signature from `templatesDir: String?` to
  `templatesDirs: [String]` and add `defaultDir: String`, and rewrite the dir handling:
  - **Enabled:** build the effective search path per §1 (`[defaultDir] + templatesDirs`,
    each `expandingTildeInPath` + `standardizingPath`, drop empties, dedup by standardized
    path, order-preserving), set
    `env["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS"] = searchPath.joined(separator: "\n")`, and
    STRIP the legacy singular key: `env.removeValue(forKey: "GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR")`.
    (The default dir is never empty, so the plural is always set; there is no "omit" branch.)
  - **Disabled:** additionally strip BOTH `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS` and the
    legacy `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR` (in addition to the existing
    `GHOSTTY_AGENT_QUEUE` / `_MAX_TOTAL` / `_HERO_MAX`).
  - Factor the search-path construction into a pure static helper
    `static func effectiveTemplateSearchPath(configured: [String], defaultDir: String) -> [String]`
    so it is unit-testable without a live config (same style as the other pure `apply*Env`
    helpers).
  - Keep it PURE (no filesystem access — expansion/standardization only), matching the
    surrounding helpers.
- **Call site (`childEnvironment`, L292–297):** pass `templatesDirs: agentQueueTemplatesDirs,
  defaultDir: Self.defaultTemplatesDir` instead of `templatesDir:`.

### 5.4 `macos/Sources/Features/Command Palette/QueuePalette.swift`

- **`QueuePaletteView.templatesDir: String?` (L34)** → `let templatesDirs: [String]` (the
  CONFIGURED list; may be empty). `defaultTemplatesDir` (L38) stays.
- **Effective search path:** add
  ```swift
  static func effectiveSearchDirs(
      configured: [String],
      fileManager fm: FileManager = .default
  ) -> [String]
  ```
  returning `[defaultTemplatesDir] + configured`, each `expandingTildeInPath` +
  `standardizingPath`, deduped by standardized path, order-preserving (§1). (There is ONE
  canonical implementation, not two synced copies: `effectiveSearchDirs` **DELEGATES** to
  `AgentManagerController.effectiveTemplateSearchPath(configured: templatesDirs, defaultDir:
  defaultTemplatesDir)`, so the palette listing and the env the sidecar consumes can never
  desync. The `fileManager` param is accepted for call-site symmetry but unused. A
  differential test `effectiveSearchDirsMatchesControllerTwin` locks the two to the same
  output.)
- **Multi-dir discovery:** add
  ```swift
  static func discoverTemplates(
      dirs: [String],
      fileManager fm: FileManager = .default
  ) -> [QueueTemplateEntry]
  ```
  that iterates `dirs` in order, calling the existing single-dir
  `discoverTemplates(dir:fileManager:)` (L186, KEEP it — it is the per-dir primitive and
  its tests stay valid), and merges with **first-in-search-order wins** by basename. Each
  kept entry records the **winning source dir**; a basename seen in more than one dir is
  marked as a duplicate. Sort the merged list case-insensitively by `displayName`
  (basename tie-break), same as today.
- **`QueueTemplateEntry` (L314):** add `let sourceDir: String` (the winning dir the entry
  was resolved from) and `let isShadowed: Bool` or a companion `duplicateBasenames:
  Set<String>` returned alongside — pick ONE representation and keep it `Equatable`.
  Recommended: add `let sourceDir: String` and `let hasDuplicate: Bool` (true when the
  same basename existed in a later dir too).
- **`templateOptions` (L125):**
  - `let dirs = Self.effectiveSearchDirs(configured: templatesDirs)`.
  - `let templates = Self.discoverTemplates(dirs: dirs)`.
  - For each entry resolve params/probe/displayName against the entry's **winning dir**:
    `Self.templateParams(dir: entry.sourceDir, basename: entry.basename)`,
    `Self.templateProbe(dir: entry.sourceDir, basename: entry.basename)`
    (these helpers at L218/L239/L275 already take a `dir` — pass `entry.sourceDir`).
  - **Source badge:** when `entry.hasDuplicate`, append the winning dir to the option's
    subtitle, e.g. `"Start a queue run · from \((entry.sourceDir as NSString).abbreviatingWithTildeInPath)"`,
    so a shadowed basename is not silently ambiguous. Non-duplicate entries keep the plain
    subtitle.
  - The empty-state row's subtitle should reference the FULL search path (all dirs), not a
    single dir.
- **`{templateDir}` parity in the palette EXEC paths (§2).** The palette is a SECOND exec
  path — the param form's live `list` PREVIEW and each param's `valuesCommand` SUGGESTION
  probe both run provider argv GUI-side (`QueueParamProber` → `QueueProviderProbe.run`),
  separate from the sidecar's TS loader. So the palette must substitute `{templateDir}` and
  export `GHOSTTY_QUEUE_TEMPLATE_DIR` itself, matching the sidecar's `substituteTemplateDir`
  + `queueProviderEnv`, or a shared-repo template that references sibling scripts gets a
  broken preview and empty suggestions even though the actual run works:
  - Add the pure `QueuePaletteView.substituteTemplateDir(_ argv:dir:)` +
    `templateDirToken = "{templateDir}"` (substring replace of ALL occurrences; empty dir
    leaves the token literal). `templateProbe` substitutes the `list.command` and records
    the resolved `templateDir`; `templateParams` substitutes each `valuesCommand`. Both use
    the SAME resolved dir the reader already computes (`(dir as NSString).expandingTildeInPath`
    of `entry.sourceDir`).
  - Thread the resolved dir through `QueueTemplateProbe.templateDir` and
    `QueueParamPrompt.templateDir` into `QueueParamProber`, which overlays
    `env["GHOSTTY_QUEUE_TEMPLATE_DIR"] = templateDir` onto the `providerEnv` used by BOTH the
    preview and the suggestion execs. (`""` ⇒ omit the var, back-compat.)

### 5.5 `macos/Sources/Features/Terminal/TerminalView.swift`

- **`QueuePaletteView(...)` (L157–162):** replace
  `templatesDir: ghostty.config.agentQueueTemplatesDir`
  with
  `templatesDirs: ghostty.config.agentQueueTemplatesDirs`.

---

## 6. Sidecar (TypeScript) changes — `macos/agent-manager/src/`

### 6.1 `queue/templates.ts` (pure substitution)

- Add a PURE, exported function:
  ```ts
  /** (shared templates) Substitute the literal `{templateDir}` token with `dir` (no
   *  trailing slash) in the five contract sites. PURE — returns a NEW template; a token
   *  in any OTHER field is left untouched. `{key}` (renderArgv) is unaffected. */
  export function substituteTemplateDir(t: QueueTemplate, dir: string): QueueTemplate
  ```
  Implementation: `const sub = (s: string) => s.split(TEMPLATE_DIR_TOKEN).join(dir);`
  with `export const TEMPLATE_DIR_TOKEN = "{templateDir}";`. Apply `sub` (substring) to:
  - `provider.list.command.map(sub)`
  - `provider.status.command.map(sub)`
  - `provider.graph.command.map(sub)` (only when `provider.graph` present)
  - `agent.command` → `sub(agent.command)`
  - each `params[i].valuesCommand?.map(sub)` (only when present)
  Return a shallow-cloned template with those replaced (deep-clone the touched
  sub-objects; leave everything else referentially shared is fine since callers treat the
  result as immutable). Do NOT touch `provider.claim.command` (see the contract note).

### 6.2 `queue/wiring.ts` (loader seam + search path + factory + rehydrate)

- **Import:** add `existsSync` (already imported), `dirname` (already imported),
  `substituteTemplateDir` from `./templates.js`.
- **`parseTemplatesDirs`** (new, exported, PURE over `env`):
  ```ts
  /** Resolve the effective search path from the process env (contract item 4):
   *  the plural GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS split on "\n" (drop empty lines);
   *  else the legacy singular GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR as a one-element list;
   *  else [defaultTemplatesDir()]. The GUI already tilde-expanded/deduped the plural. */
  export function parseTemplatesDirs(env: NodeJS.ProcessEnv, home?: string): string[]
  ```
  Defensive: `.map(s => s.trim()).filter(Boolean)`; if the resulting list is empty, fall
  back to `[defaultTemplatesDir(home)]`.
- **`resolveTemplatePath`** (new, exported): `resolveTemplatePath(searchPath: string[],
  basename: string): string | null` — first `join(dir, basename + ".json")` that
  `existsSync` (first-wins, §1). No `~` expansion here (dirs arrive absolute).
- **Refactor `loadTemplateByName`** into a path-based loader:
  ```ts
  /** Load + validate the template at an ABSOLUTE path; expand its workdir `~` AND
   *  substitute `{templateDir}` = dirname(path) in the five contract sites. */
  export function loadTemplateAtPath(path: string): LoadResult
  ```
  Body: `makeTemplateLoader(path, realTemplateFs).load()`; if `ok`, first
  `res.template.workdir = expandHome(res.template.workdir)` (unchanged), then
  `res.template = substituteTemplateDir(res.template, dirname(path))`. Keep a thin
  `loadTemplateByName(searchPath, basename)` wrapper that does
  `resolveTemplatePath(...)` → `loadTemplateAtPath(...)` (returns a not-found LoadResult
  when unresolved) so call sites read naturally and the resolved path is available.
- **`makeFileRunFactory(searchPath: string[], stateDir: string)`** (signature change from
  `templatesDir: string`): resolve `const path = resolveTemplatePath(searchPath, basename)`;
  on null → the existing "cannot start" error + null. Load via `loadTemplateAtPath(path)`.
  On success construct the run with the resolved path threaded through:
  `makeQueueRun(res.template, storeIO, { templateName: basename, params: runParams,
  templatePath: path })`.
- **`rehydrateActiveRuns(searchPath: string[], stateDir: string)`** (signature change):
  for each record, choose the path deterministically (§3):
  `const path = (rec.templatePath && existsSync(rec.templatePath)) ? rec.templatePath :
  resolveTemplatePath(searchPath, rec.template);` — if null, log + skip (unchanged). Load
  via `loadTemplateAtPath(path)`; keep the legacy-state-file migration block unchanged;
  pass `templatePath: path` into `makeQueueRun`.
- `defaultStateDir` (L157) and `defaultTemplatesDir` (L163) are UNCHANGED. **Confirm
  `defaultStateDir` stays hardcoded to `join(home, ...QUEUES_DIR, ".state")` — independent
  of the templates search path — so run state NEVER writes into a shared repo dir.** (No
  code change; it is a hygiene invariant, called out in the docs.)

### 6.3 `queue/runner.ts` (run carries the path; env injection)

- **`QueueRun`** (interface, ~L110): add
  - `templatePath: string;` (the resolved abs path the run loaded from; `""` for
    test-constructed runs) and
  - `templateDir: string;` (derived `dirname(templatePath)`; `""` when no path).
- **`makeQueueRun`** (L278): add `templatePath?: string` to `opts`; in the returned object
  set `templatePath: opts.templatePath ?? ""` and `templateDir: opts.templatePath ?
  dirname(opts.templatePath) : ""`. Import `dirname` from `node:path`. Existing callers
  that omit it (all current tests) get `""` — harmless (`GHOSTTY_QUEUE_TEMPLATE_DIR=""`).
- **`activeRunRecords`** (L442): add `if (run.templatePath) rec.templatePath =
  run.templatePath;` (omit when empty, keep the record tidy + back-compat).
- **Provider exec env — add `GHOSTTY_QUEUE_TEMPLATE_DIR`.** Introduce a helper
  `function queueProviderEnv(run: QueueRun): Record<string,string>` returning
  `{ ...resolveParamsEnv(run.template, run.params), ...(run.templateDir ?
  { GHOSTTY_QUEUE_TEMPLATE_DIR: run.templateDir } : {}) }` (it reads `run.template`
  internally, so it is correct whether the call site aliases the template as `t` or uses
  `run.template`; helper is at `runner.ts` L360). **Every provider exec site must call
  `queueProviderEnv(run)` — do NOT rely on the inline `env: resolveParamsEnv(t, run.params)`
  pattern alone**, because ONE of the five (the status-probe batch) is written as a `const`
  binding, not an inline `env:` property, and would be missed by a literal pattern search on
  `env:`. The exhaustive list is the FIVE sites below (shipped line numbers; re-grep
  `queueProviderEnv(` in `runner.ts` — after the change `resolveParamsEnv(` appears ONLY
  inside `queueProviderEnv`, and `queueProviderEnv(` returns exactly these five call sites):
  - **L971** — `fetchGraphResult` (graph fetch; `cwd: run.template.workdir`): inline
    `env: resolveParamsEnv(run.template, run.params),` → `env: queueProviderEnv(run),`.
  - **L1224** — the per-agent STATUS-PROBE batch: a **`const` binding reused across
    `Promise.all`**, `const env = resolveParamsEnv(run.template, run.params);` →
    **`const env = queueProviderEnv(run);`** (each `probeStatus(...)` in the batch then
    inherits `env` unchanged — a single edit covers all concurrent probes). This is the
    site the inline `env:` pattern does NOT match; it is enumerated explicitly here and is
    the reason a literal `env:`-property search is INSUFFICIENT.
  - **L1488** — `fetchListResult` (list fetch; `cwd: t.workdir`): inline
    `env: resolveParamsEnv(t, run.params),` → `env: queueProviderEnv(run),`.
  - **L1801** — `runProvider` claim in `dispatchOne` (§g; `cwd: t.workdir`): inline
    `env: resolveParamsEnv(t, run.params),` → `env: queueProviderEnv(run),`.
  - **L1928** — `runProvider` claim in the adopt path (`cwd: t.workdir`): inline
    `env: resolveParamsEnv(t, run.params),` → `env: queueProviderEnv(run),`.

  `GHOSTTY_QUEUE_TEMPLATE_DIR` survives `sanitizeProviderEnv` because it is overlaid as
  `opts.env` AFTER the base-env strip and does not match the `GHOSTTY_AGENT_`/`GHOSTTY_MCP_`
  deny prefixes.
- **Agent split env — add `GHOSTTY_QUEUE_TEMPLATE_DIR` on BOTH paths** (dispatch spawn, ~L1689–1704):
  under the `.client` pty-host backend the spawn `env` field is DROPPED (see the
  `shellEnvPrefix` rationale, provider.ts L106–122), so the value must ALSO ride the
  command prefix like `GHOSTTY_ITEM_*`:
  ```ts
  const templateDirAssign = run.templateDir
    ? `GHOSTTY_QUEUE_TEMPLATE_DIR=${shellSingleQuote(run.templateDir)} `
    : "";
  const commandWithItemEnv = templateDirAssign + shellEnvPrefix(item) + t.agent.command;
  const base = {
    command: commandWithItemEnv,
    cwd: t.workdir,
    env: { ...itemEnv, ...(run.templateDir ? { GHOSTTY_QUEUE_TEMPLATE_DIR: run.templateDir } : {}) },
  };
  ```
  (`shellSingleQuote` is exported from provider.ts.) This covers `.exec` (via `env`) and
  `.client` (via the command prefix), matching the existing item-env dual delivery.

### 6.4 `queue/store.ts` (persist the resolved path)

- **`ActiveRunRecord`** (L805): add `templatePath?: string;` with a doc comment (contract
  item 6 — the resolved abs path so a restart re-resolves the SAME file even if a
  later-added dir shadows the basename).
- **`parseActiveRuns`** (L841): tolerantly carry it — `if (typeof r.templatePath ===
  "string" && r.templatePath.length > 0) rec.templatePath = r.templatePath;` (alongside
  the existing `params`/`maxItemsLive`/`concurrencyLive` handling).
- **`serializeActiveRuns`** round-trips it automatically (whole record is stringified).

### 6.5 `index.ts` (build + thread the search path)

- **Queue arming block (L1114–1156):** replace
  `const templatesDir = process.env.GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR ?? defaultTemplatesDir();`
  with `const searchPath = parseTemplatesDirs(process.env);`.
- Pass `searchPath` (not `templatesDir`) to `rehydrateActiveRuns(searchPath, stateDir)`
  (L1141-ish) and `makeFileRunFactory(searchPath, stateDir)` (L1153-ish). Import
  `parseTemplatesDirs` from `./queue/wiring.js`. Update the nearby comment that names the
  singular env var to name the plural + the singular back-compat.

---

## 7. Tests to add / update

### 7.1 Zig — `src/config/Config.zig`
- Update `test "agent-queue: parse and default"` (drop templates-dir scalar assertions).
- Add `test "agent-queue-templates-dir: RepeatableString parse"` — default empty, single,
  multiple (order preserved), empty-value reset, cval C-list view, formatEntry round-trip
  (see §4.1). Run with
  `zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=agent-queue-templates-dir`.

### 7.2 TS — `macos/agent-manager/src/queue/*.test.ts`
- **`templates.test.ts`** (`substituteTemplateDir`):
  - substitutes the token in `provider.list.command`, `provider.status.command`,
    `provider.graph.command`, `agent.command`, and a param `valuesCommand`.
  - substring replace (`"{templateDir}/list.py"` → `"<dir>/list.py"`), all occurrences.
  - a template WITHOUT the token is byte-identical (deep-equal) after substitution.
  - `provider.claim.command` is NOT substituted (locks the contract note).
  - `{key}` placeholders are untouched by the dir substitution.
- **`wiring.test.ts`**:
  - `parseTemplatesDirs`: plural split on `"\n"` dropping empty lines; singular fallback
    → one-element; both absent → `[defaultTemplatesDir(home)]`.
  - `resolveTemplatePath`: first-in-order dir containing `<b>.json` wins (build a temp
    two-dir tree, same basename in both, assert the first dir's path).
  - `loadTemplateAtPath`: sets `template.workdir` expanded AND substitutes
    `{templateDir}` = `dirname(path)` (assert a `{templateDir}` in a command resolved).
  - `makeFileRunFactory`: the produced run has `templatePath` = the resolved path and
    `templateDir` = its dirname.
  - `rehydrateActiveRuns`: with `rec.templatePath` set to dir A's file, and dir B (earlier
    in the search path) later gaining the same basename, the rehydrated run STILL loads dir
    A's file (determinism); with `templatePath` absent it falls back to first-wins
    resolution; a vanished path + unresolved basename drops the run.
- **`store.test.ts`**: `parseActiveRuns` carries `templatePath` (string only; dropped when
  non-string/empty); `serializeActiveRuns`→`parseActiveRuns` round-trips it.
- **`runner.test.ts`**: with a run whose `templateDir` is set (via `makeQueueRun({...,
  templatePath})`), a sweep's provider `exec` receives `opts.env.GHOSTTY_QUEUE_TEMPLATE_DIR
  === templateDir` (assert via a fake `exec`), and a dispatch's `spawnSplitCommand` args
  carry `GHOSTTY_QUEUE_TEMPLATE_DIR` BOTH in `env` and as an inline `GHOSTTY_QUEUE_TEMPLATE_DIR=…`
  prefix on `command` (assert via a fake client). A run with empty `templateDir` omits the
  key on both (back-compat, existing tests unaffected).
- Run with `npm test` in `macos/agent-manager` (tsc → `dist/**/*.test.js`).

### 7.3 Swift — `macos/Tests/…`
- **`Command Palette/QueuePaletteTests.swift`**:
  - `discoverTemplates(dirs:)` across two temp dirs merges by basename with
    **first-in-order wins** (dir A's `dup.json` beats dir B's).
  - a basename present in both dirs is flagged (`hasDuplicate == true`) and its
    `sourceDir` is dir A; a basename unique to one dir has `hasDuplicate == false`.
  - `effectiveSearchDirs(configured:)` prepends the default dir FIRST and dedups a
    repeated/equivalent path (order-preserving) — `effectiveSearchDirsPrependsDefaultAndDedups`.
  - `effectiveSearchDirsMatchesControllerTwin`: the palette's `effectiveSearchDirs` output
    is IDENTICAL to `AgentManagerController.effectiveTemplateSearchPath(configured:defaultDir:)`
    for the same input (locks the delegation so the palette listing can't desync from the env).
  - a duplicate entry's params/probe resolve against the WINNING `sourceDir` (put distinct
    `params` in dir A vs dir B; assert dir A's are read).
  - `substituteTemplateDir(_:dir:)` replaces ALL `{templateDir}` occurrences (substring),
    leaves a token-free argv unchanged, and leaves the token literal for an empty dir.
  - `templateProbe` substitutes `{templateDir}` in `list.command` and records the resolved
    `templateDir`; `templateParams` substitutes `{templateDir}` in a param `valuesCommand`.
- **`AgentManager/AgentManagerControllerTests.swift`** (mirror the existing
  `agentQueueEnv*` tests at L197–270, updated to the new signature):
  - enabled builds `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS` = default-first + configured,
    tilde-expanded, `"\n"`-joined, deduped; the legacy singular key is absent/stripped.
  - a `~`-configured dir is expanded (no leading `~` survives); an already-absolute dir
    passes through; a dir equal to the default is deduped (appears once).
  - disabled strips BOTH `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS` and the legacy singular.
  - a pure test of `effectiveTemplateSearchPath(configured:defaultDir:)` (order + dedup).
- **`Ghostty.Config` list getter**: no live-`ghostty_config_t` harness exists for getters
  today, so `agentQueueTemplatesDirs` is covered indirectly (Zig cval test + the palette
  and controller tests). If a config-fixture harness is added, assert the getter maps the
  string-list; otherwise note the indirect coverage in the test file header.

---

## 8. Docs to update (Docs phase — BLOCKING per CLAUDE.md)

- **`AGENT-QUEUE.md`**: new section **"Sharing queue templates across a repo"** covering:
  the search-list key semantics (default-first + configured, first-wins collision, dedup);
  the `{templateDir}` token + `GHOSTTY_QUEUE_TEMPLATE_DIR` env (both provider exec + agent
  split); the repo-vs-`.config` split; the `.gitignore` recipe; secrets stay machine-local.
  Update the `agent-queue-templates-dir` config-key doc + the palette discovery description
  (multi-dir + source badge). Update the wiring/tests list.
- **`CLAUDE.md`**: update the **Agent Queue Supervisor** bullet (templates-dir is now a
  search LIST; note `{templateDir}` + `GHOSTTY_QUEUE_TEMPLATE_DIR`); update the fork-only
  config-keys list to note `agent-queue-templates-dir` is a RepeatableString; extend the
  wiring list with the new TS/Swift functions.
- **`example/ghostty-ramon/config`**: keep in sync using NEUTRAL placeholders only, e.g. a
  COMMENTED line near the `agent-queue` block (around L121):
  ```
  # Share templates from a repo (in addition to the default queues dir, which is
  # ALWAYS searched first). Repeatable; first-in-order wins on a basename clash.
  # agent-queue-templates-dir = ~/git/your-project/ghostty-queues
  ```
  NEVER put a real project/company/person name or a real absolute `/Users/...` path into
  any tracked file (BLOCKING repo rule).

---

## 9. Hygiene (docs-only, no code)

- A shared repo bundle holds portable template JSON + sibling scripts referenced via
  `{templateDir}`. Secrets (API keys / `*.env`) stay machine-local — scripts read them
  from `~/.config` or a git-ignored local file, never from the repo.
- Recommended repo `.gitignore`: `__pycache__/`, `.DS_Store`, `.state/`, `*.env`.
- **State never lands in a repo dir.** `defaultStateDir()` is hardcoded to
  `~/.config/ghostty-ramon/agent-manager/queues/.state` and is INDEPENDENT of the templates
  search path — confirm this invariant is preserved (no code change) so per-run state
  (`active-runs.json`, per-run `*.state.json`) is never written next to a shared template.

---

## 10. Build / verify checklist (per CLAUDE.md iteration lifecycle)

1. Zig test: `zig build test -Demit-macos-app=false -Demit-xcframework=false
   -Dtest-filter=agent-queue-templates-dir` (+ the existing `agent-queue` test).
2. Rebuild lib WITH xcframework: `zig build -Demit-macos-app=false -Doptimize=ReleaseFast`
   (no new C export, but the config field changed → lib must be rebuilt so the app links a
   fresh xcframework). No `ghostty-host` change; no host restart.
3. Sidecar: `npm run build` + `npm test` in `macos/agent-manager` (rebuild `dist`).
4. Swift tests: `macos/build.nu --action test` (or targeted `-only-testing`).
5. App build: `macos/build.nu --configuration ReleaseLocal --action build` (bundles the
   fresh sidecar `dist`).
6. GUI-only + host-untouched → the step-6 install block MAY run without asking once merged
   to `ramon-fork` and rebuilt there.

**Scope of change:** GUI + sidecar + one Zig config field. NO host (`src/host/`,
`src/termio/`) change, NO protocol change, NO new C API. GUI relaunch + rebuilt sidecar
`dist` + lib/xcframework rebuild; no host restart / no session loss.
