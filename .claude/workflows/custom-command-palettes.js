export const meta = {
  name: 'custom-command-palettes',
  description: 'Add user-configurable custom command palettes that send command-input text to the focused surface',
  whenToUse: 'Implement the "custom command palettes for command inputs" feature end-to-end on the ramon-fork: config schema, core action, apprt plumbing, macOS UI, build + tests + adversarial review.',
  phases: [
    { title: 'Understand', detail: 'parallel readers map the existing command-palette + input-send + config-parsing subsystems' },
    { title: 'Design', detail: 'independent design proposals, scored by a judge panel, synthesized into one spec' },
    { title: 'Implement-core', detail: 'Zig core: config schema, Command model, keybind action, apprt action + ghostty.h' },
    { title: 'Build-core', detail: 'rebuild the Zig lib + run targeted Zig tests (gate before the macOS layer)' },
    { title: 'Implement-macos', detail: 'macOS Swift: render custom palettes, route selection to surface input' },
    { title: 'Verify', detail: 'build the lib + macOS app, run Zig + Swift tests' },
    { title: 'Review', detail: 'adversarial review of the diff; verify each finding before reporting' },
  ],
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature under construction
//   "Custom command palettes for command inputs."
//   Ghostty already ships a built-in command palette (toggle_command_palette)
//   that lists *actions*. This feature lets a user DEFINE their own named
//   palettes in config, each holding a list of entries; selecting an entry
//   sends command-input TEXT to the focused surface (optionally with a trailing
//   newline to run it). Palettes are openable via a new keybind action, e.g.
//   `command_palette:<name>`, and surfaced in the macOS palette UI.
//
//   This is a fork feature: keep fork conventions (CLAUDE.md). Fork-only
//   keybinds live in ~/.config/ghostty-ramon/config so an official Ghostty
//   never errors on the new action. New action must roundtrip through
//   Binding.zig parse/format like the other fork actions.
// ─────────────────────────────────────────────────────────────────────────────

const SUBSYSTEM_MAP = {
  type: 'object',
  additionalProperties: false,
  required: ['subsystem', 'keyFiles', 'extensionPoints', 'risks'],
  properties: {
    subsystem: { type: 'string' },
    keyFiles: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['path', 'role', 'anchors'],
        properties: {
          path: { type: 'string' },
          role: { type: 'string', description: 'what this file does for the feature' },
          anchors: {
            type: 'array',
            description: 'concrete symbols / line refs an implementer must touch or imitate',
            items: { type: 'string' },
          },
        },
      },
    },
    extensionPoints: {
      type: 'array',
      description: 'exact places new code hooks in (struct to extend, enum to add a tag to, switch to extend, fn to call)',
      items: { type: 'string' },
    },
    risks: {
      type: 'array',
      description: 'gotchas the implementer must respect (parse/format roundtrip, fork config separation, memory ownership, IME/text-send path, etc.)',
      items: { type: 'string' },
    },
  },
}

const DESIGN_PROPOSAL = {
  type: 'object',
  additionalProperties: false,
  required: ['angle', 'configSyntax', 'coreActionShape', 'apprtShape', 'macosShape', 'tradeoffs', 'openQuestions'],
  properties: {
    angle: { type: 'string', description: 'the guiding bias of this proposal (e.g. minimal-core, config-rich, reuse-existing-palette)' },
    configSyntax: { type: 'string', description: 'concrete example config block defining a custom palette + entries, and how an entry maps to input text + a run/no-run flag' },
    coreActionShape: { type: 'string', description: 'new keybind action name(s), payload type, how it parses/formats, how it produces the Command list / apprt action' },
    apprtShape: { type: 'string', description: 'apprt action enum + ghostty.h C ABI changes needed to carry the custom palette to macOS' },
    macosShape: { type: 'string', description: 'how the Swift CommandPalette renders custom entries and how selection routes back to surface text input' },
    tradeoffs: { type: 'array', items: { type: 'string' } },
    openQuestions: { type: 'array', items: { type: 'string' } },
  },
}

const DESIGN_SCORE = {
  type: 'object',
  additionalProperties: false,
  required: ['proposalAngle', 'scores', 'total', 'verdict', 'bestIdeasToGraft'],
  properties: {
    proposalAngle: { type: 'string' },
    scores: {
      type: 'object',
      additionalProperties: false,
      required: ['fitsExistingArchitecture', 'simplicity', 'forkConventionSafety', 'userPower', 'implementationRisk'],
      properties: {
        fitsExistingArchitecture: { type: 'integer', minimum: 0, maximum: 5 },
        simplicity: { type: 'integer', minimum: 0, maximum: 5 },
        forkConventionSafety: { type: 'integer', minimum: 0, maximum: 5, description: 'roundtrip parse/format, fork config separation, no break to official Ghostty' },
        userPower: { type: 'integer', minimum: 0, maximum: 5 },
        implementationRisk: { type: 'integer', minimum: 0, maximum: 5, description: '5 = low risk' },
      },
    },
    total: { type: 'integer' },
    verdict: { type: 'string' },
    bestIdeasToGraft: { type: 'array', items: { type: 'string' }, description: 'ideas worth stealing from this proposal even if it does not win' },
  },
}

const IMPL_RESULT = {
  type: 'object',
  additionalProperties: false,
  required: ['summary', 'filesTouched', 'testsAddedOrChanged', 'followupsForNextStage', 'assumptions'],
  properties: {
    summary: { type: 'string' },
    filesTouched: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['path', 'change'],
        properties: { path: { type: 'string' }, change: { type: 'string' } },
      },
    },
    testsAddedOrChanged: { type: 'array', items: { type: 'string' } },
    followupsForNextStage: { type: 'array', items: { type: 'string' }, description: 'exactly what the next layer needs to know (new symbol names, ABI shape, action name)' },
    assumptions: { type: 'array', items: { type: 'string' } },
  },
}

const BUILD_RESULT = {
  type: 'object',
  additionalProperties: false,
  required: ['command', 'passed', 'summary', 'failures'],
  properties: {
    command: { type: 'string' },
    passed: { type: 'boolean' },
    summary: { type: 'string' },
    failures: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['where', 'message', 'suspectFile'],
        properties: { where: { type: 'string' }, message: { type: 'string' }, suspectFile: { type: 'string' } },
      },
    },
  },
}

const FINDINGS = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'file', 'line', 'severity', 'detail'],
        properties: {
          title: { type: 'string' },
          file: { type: 'string' },
          line: { type: 'integer' },
          severity: { type: 'string', enum: ['blocker', 'major', 'minor', 'nit'] },
          detail: { type: 'string' },
        },
      },
    },
  },
}

const VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['title', 'isReal', 'confidence', 'reasoning', 'suggestedFix'],
  properties: {
    title: { type: 'string' },
    isReal: { type: 'boolean' },
    confidence: { type: 'string', enum: ['low', 'medium', 'high'] },
    reasoning: { type: 'string' },
    suggestedFix: { type: 'string' },
  },
}

// Shared context every agent gets, so each starts oriented without re-deriving.
const CONTEXT = `
Repo: Ghostty terminal, personal macOS fork on branch \`ramon-fork\`. Read /Users/ramon/git/ghostty/CLAUDE.md and macos/AGENTS.md and AGENTS.md for conventions BEFORE acting.

Feature to build: "custom command palettes for command inputs" — let a user define named palettes in config, each a list of entries; choosing an entry sends command-input text to the focused surface (with an optional trailing newline to execute). Palettes open via a new keybind action and render in the existing command-palette UI.

Known wiring (verified to exist, confirm exact line numbers yourself):
- Core command model: src/input/command.zig (pub const Command at line ~18; toggle_command_palette referenced ~836).
- Keybind action parse/format + roundtrip: src/input/Binding.zig (Action enum; fork actions already added here — imitate them; remember the shift/case trigger gotcha documented in CLAUDE.md).
- Surface dispatch: src/Surface.zig (.toggle_command_palette performAction at ~5475; the text-input path that types into the pty lives here too).
- apprt action enum: src/apprt/action.zig and its C ABI mirror include/ghostty.h.
- Config schema: src/config/Config.zig; fork config separation via src/config/file_load.zig (forkXdgPath, loadDefaultFiles).
- macOS palette UI: macos/Sources/Features/Command Palette/CommandPalette.swift and TerminalCommandPalette.swift; bridging in macos/Sources/Ghostty/Ghostty.App.swift, Ghostty.Config.swift, GhosttyPackage.swift; trigger in BaseTerminalController.swift.

Fork rules that MUST hold:
- New keybind action must roundtrip through Binding.zig parse↔format exactly like new_tab:<dir> etc. (action == its type default serializes WITHOUT the :value suffix).
- The new action and config keys must NOT break an official Ghostty reading the shared ~/.config/ghostty/config — keep fork-only config loadable from ~/.config/ghostty-ramon/config.
- Build/test commands (run from repo root):
  - Zig lib rebuild: zig build -Demit-macos-app=false -Doptimize=ReleaseFast
  - Zig test: zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=<name>
  - macOS build: macos/build.nu --configuration ReleaseLocal --action build
  - Swift tests: macos/build.nu --action test
- SAFETY: never quit/launch anything named "Ghostty" by name; never touch /Applications/Ghostty.app; do NOT run the install block. Build only into macos/build/.
`

// ── Phase 1: Understand ───────────────────────────────────────────────────────
phase('Understand')
const READERS = [
  { key: 'core-command-palette', focus: 'How the EXISTING command palette works end to end: how src/input/command.zig builds the Command list, how toggle_command_palette flows through Surface.zig → apprt/action.zig → include/ghostty.h → macOS CommandPalette.swift, and how a selected entry currently triggers an action. This is the template to extend.' },
  { key: 'keybind-action', focus: 'How keybind actions are defined/parsed/formatted in src/input/Binding.zig, focusing on fork actions with a payload (new_tab:<dir>, pull_marked_split:<dir>) — exact parse/format roundtrip mechanics and the default-elides-suffix rule. Output the precise pattern a new `command_palette:<name>` (or chosen name) action must follow.' },
  { key: 'text-input-send', focus: 'The path that injects text into a surface/pty in src/Surface.zig (how typed text / paste / bound text reaches the pty), and whether a reusable action exists for "send this literal string (+optional newline)". This is how a selected palette entry must deliver its command input.' },
  { key: 'config-schema', focus: 'How structured/repeatable config is modeled in src/config/Config.zig (look for existing list/struct-valued config like keybind, or repeatable entries), plus the fork config separation in src/config/file_load.zig. Output the cleanest way to express "named palette -> list of {title, input-text, run?}" entries.' },
  { key: 'macos-ui', focus: 'macOS Command Palette UI: CommandPalette.swift / TerminalCommandPalette.swift data model + selection handling, and the Ghostty bridging layer (Ghostty.App.swift, Ghostty.Config.swift, GhosttyPackage.swift, BaseTerminalController.swift). Output how custom entries would be fed in and how selection routes back to send input to the surface.' },
]
const subsystemMaps = await parallel(READERS.map(r => () =>
  agent(
    `${CONTEXT}\n\nYou are a read-only code cartographer. Map this subsystem for an implementer who will add the feature. Be concrete: real file paths, real symbol names, real line numbers, and the exact extension points. Do NOT propose a full design and do NOT edit anything.\n\nSUBSYSTEM: ${r.key}\nFOCUS: ${r.focus}`,
    { label: `map:${r.key}`, phase: 'Understand', schema: SUBSYSTEM_MAP, agentType: 'Explore' },
  ),
)).then(xs => xs.filter(Boolean))

const mapDigest = subsystemMaps.map(m =>
  `### ${m.subsystem}\nFiles:\n${m.keyFiles.map(f => `- ${f.path} — ${f.role} [${f.anchors.join('; ')}]`).join('\n')}\nExtension points:\n${m.extensionPoints.map(e => `- ${e}`).join('\n')}\nRisks:\n${m.risks.map(e => `- ${e}`).join('\n')}`,
).join('\n\n')
log(`Mapped ${subsystemMaps.length} subsystems.`)

// ── Phase 2: Design (judge panel) ─────────────────────────────────────────────
phase('Design')
const ANGLES = [
  { key: 'minimal-core', bias: 'Smallest possible core change. Reuse the existing command palette plumbing and any existing text-send action; add the least new config and ABI surface. Prefer one new keybind action carrying a palette name.' },
  { key: 'config-rich', bias: 'Most expressive config: per-entry title, description, input text, run-on-select flag, maybe ordering; multiple named palettes. Accept more code for more user power.' },
  { key: 'reuse-action-list', bias: 'Treat custom entries as first-class Commands that emit existing actions (incl. a text-send action), so custom palettes and the built-in palette share one code path and the macOS UI needs minimal change.' },
]
const proposals = await parallel(ANGLES.map(a => () =>
  agent(
    `${CONTEXT}\n\nSUBSYSTEM MAP (ground truth from the readers):\n${mapDigest}\n\nDesign the feature with THIS bias: ${a.bias}\n\nProduce a concrete, buildable design: exact config syntax example, the core keybind action name + payload + parse/format plan, the apprt/ghostty.h ABI delta, and the macOS UI/selection-routing plan. Respect every fork rule (roundtrip, config separation, official-Ghostty compatibility). Call out tradeoffs and open questions honestly.`,
    { label: `design:${a.key}`, phase: 'Design', schema: DESIGN_PROPOSAL },
  ),
)).then(xs => xs.filter(Boolean))

// Score every proposal from independent judges (barrier: synthesis needs all scores + all proposals).
const scores = await parallel(proposals.map(p => () =>
  agent(
    `${CONTEXT}\n\nSUBSYSTEM MAP:\n${mapDigest}\n\nScore this design proposal for the fork. Be skeptical, especially about parse/format roundtrip, fork config separation, and ABI churn. Note ideas worth grafting even if it loses.\n\nPROPOSAL:\n${JSON.stringify(p, null, 2)}`,
    { label: `score:${p.angle}`, phase: 'Design', schema: DESIGN_SCORE },
  ),
)).then(xs => xs.filter(Boolean))

const spec = await agent(
  `${CONTEXT}\n\nSUBSYSTEM MAP:\n${mapDigest}\n\nPROPOSALS:\n${JSON.stringify(proposals, null, 2)}\n\nJUDGE SCORES:\n${JSON.stringify(scores, null, 2)}\n\nSynthesize ONE final implementation spec. Start from the highest-scoring proposal, graft the best ideas from the others, and resolve every open question with a concrete decision. Output a precise, sectioned spec an implementer can follow without further design: (1) exact config syntax + how it parses into Config.zig, (2) the new keybind action name, payload type, and parse/format roundtrip plan, (3) how a selected entry delivers command-input text (reuse vs new action) + the run-on-select newline behavior, (4) apprt/action.zig + include/ghostty.h ABI delta, (5) macOS UI + selection-routing plan, (6) the test plan (which Zig tests and Swift tests to add). Keep it implementable and fork-safe.`,
  { label: 'synthesize-spec', phase: 'Design' },
)
log('Final spec synthesized.')

// ── Phase 3: Implement core (Zig) ─────────────────────────────────────────────
// Core layers are interdependent (config -> action -> apprt -> ABI), so one
// implementer owns the whole Zig change to keep it coherent, with the spec + map
// as context. It also writes/updates the Zig tests.
phase('Implement-core')
const coreImpl = await agent(
  `${CONTEXT}\n\nFINAL SPEC:\n${spec}\n\nSUBSYSTEM MAP:\n${mapDigest}\n\nImplement the ZIG CORE half of the feature on the working tree (no commit). Touch only what the spec requires across: src/config/Config.zig (+ src/config/file_load.zig if needed), src/input/command.zig, src/input/Binding.zig, src/Surface.zig, src/apprt/action.zig, include/ghostty.h. Follow upstream Zig style and the fork's existing fork-action code as a template. Ensure the new keybind action roundtrips through parse↔format and add a Zig test for that roundtrip (and for config parsing of a custom palette). Do NOT build yet and do NOT touch any macOS Swift files — the next stages handle build + macOS. Report exactly what the macOS layer will need (action name, ABI struct/fn names, fields).`,
  { label: 'impl:zig-core', phase: 'Implement-core', schema: IMPL_RESULT },
)
log(`Core implemented: ${coreImpl?.summary ?? 'no result'}`)

// ── Phase 4: Build-core gate ──────────────────────────────────────────────────
// Rebuild the lib and run the new Zig tests BEFORE the macOS layer, so the C ABI
// header is known-good before Swift consumes it. One repair attempt if it fails.
phase('Build-core')
let coreBuild = await agent(
  `${CONTEXT}\n\nThe Zig core change is on the working tree. Build the lib and run the targeted Zig tests, then report results verbatim.\n\nRun, from /Users/ramon/git/ghostty:\n1. zig build -Demit-macos-app=false -Doptimize=ReleaseFast\n2. zig build test -Demit-macos-app=false -Demit-xcframework=false  (or with -Dtest-filter matching the new roundtrip/config tests)\n\nReport pass/fail and exact compiler/test errors with the suspect file. Do not fix anything; just report.`,
  { label: 'build:zig', phase: 'Build-core', schema: BUILD_RESULT },
)
if (coreBuild && !coreBuild.passed) {
  log('Core build/tests failed — attempting one repair pass.')
  await agent(
    `${CONTEXT}\n\nThe Zig core build/tests FAILED. Fix the working tree so both pass. Keep changes minimal and within the spec; do not touch macOS Swift.\n\nFailures:\n${JSON.stringify(coreBuild.failures, null, 2)}\n\nFINAL SPEC (for reference):\n${spec}`,
    { label: 'repair:zig-core', phase: 'Build-core' },
  )
  coreBuild = await agent(
    `${CONTEXT}\n\nRe-run after the repair, from /Users/ramon/git/ghostty:\n1. zig build -Demit-macos-app=false -Doptimize=ReleaseFast\n2. zig build test -Demit-macos-app=false -Demit-xcframework=false\nReport pass/fail and any remaining errors verbatim.`,
    { label: 'build:zig-recheck', phase: 'Build-core', schema: BUILD_RESULT },
  )
}

// ── Phase 5: Implement macOS (Swift) ──────────────────────────────────────────
phase('Implement-macos')
const macImpl = await agent(
  `${CONTEXT}\n\nFINAL SPEC:\n${spec}\n\nZIG CORE IS DONE. What the core exposes for you:\n${JSON.stringify(coreImpl?.followupsForNextStage ?? [], null, 2)}\n\nSUBSYSTEM MAP (macOS portion):\n${mapDigest}\n\nImplement the macOS SWIFT half on the working tree (no commit): read the custom-palette config through the bridging layer (Ghostty.Config.swift / Ghostty.App.swift / GhosttyPackage.swift), render custom entries in CommandPalette.swift / TerminalCommandPalette.swift, and route a selected entry to send its command-input text to the focused surface (honoring the run-on-select newline flag). Trigger the custom palette from the new keybind action via BaseTerminalController.swift, imitating how toggle_command_palette is handled. Match the surrounding Swift style. Add or extend a Swift test if the spec calls for one. Do NOT run the install block and do NOT quit/launch any app named Ghostty.`,
  { label: 'impl:swift', phase: 'Implement-macos', schema: IMPL_RESULT },
)
log(`macOS implemented: ${macImpl?.summary ?? 'no result'}`)

// ── Phase 6: Verify (full build + tests) ──────────────────────────────────────
phase('Verify')
const verifyTasks = [
  { key: 'zig', cmd: 'zig build -Demit-macos-app=false -Doptimize=ReleaseFast && zig build test -Demit-macos-app=false -Demit-xcframework=false', what: 'Rebuild the Zig lib and run the full Zig test suite.' },
  { key: 'macos', cmd: 'macos/build.nu --configuration ReleaseLocal --action build', what: 'Build the macOS app (ReleaseLocal). This compiles all the Swift changes against the new lib/header.' },
  { key: 'swift-tests', cmd: 'macos/build.nu --action test', what: 'Run the Swift test suite (incl. SplitTreeTests and any new palette tests).' },
]
const verifyResults = await parallel(verifyTasks.map(t => () =>
  agent(
    `${CONTEXT}\n\nRun this verification step from /Users/ramon/git/ghostty and report results verbatim (pass/fail + exact errors + suspect file). Do NOT attempt fixes; reporting only. Build only into macos/build/; never run the install block; never quit/launch an app named Ghostty.\n\nSTEP: ${t.what}\nCOMMAND: ${t.cmd}`,
    { label: `verify:${t.key}`, phase: 'Verify', schema: BUILD_RESULT },
  ),
)).then(xs => xs.filter(Boolean))
log(`Verify: ${verifyResults.filter(r => r.passed).length}/${verifyResults.length} green.`)

// ── Phase 7: Review (find → adversarially verify) ─────────────────────────────
phase('Review')
const DIMENSIONS = [
  { key: 'roundtrip-config', prompt: 'Correctness of the new config parsing AND the keybind action parse↔format roundtrip. Does the action serialize without the :value suffix when equal to its type default? Does a custom palette config parse cleanly, and does an official Ghostty NOT break on the shared config (fork separation honored)?' },
  { key: 'input-send', prompt: 'Correctness of delivering command-input text to the surface: escaping, encoding, the run-on-select newline behavior, focus/lifetime of the target surface, and what happens if no surface is focused or the palette name is unknown.' },
  { key: 'abi-bridge', prompt: 'C ABI consistency between src/apprt/action.zig and include/ghostty.h and the Swift consumer: struct layout, ownership/lifetime of any strings crossing the boundary, optionals/null handling, memory leaks.' },
  { key: 'macos-ui', prompt: 'macOS UI/state correctness: palette population from config, selection handling, retain cycles / use-after-free, and adherence to the fork safety rules (no app-named-Ghostty quit/launch, no install block).' },
]
const reviewed = await pipeline(
  DIMENSIONS,
  d => agent(
    `${CONTEXT}\n\nReview the CURRENT WORKING-TREE DIFF for the custom-command-palettes feature (use \`git diff\` and \`git status\`). Report only real issues in the new/changed code along this dimension. Include exact file + line.\n\nDIMENSION (${d.key}): ${d.prompt}`,
    { label: `review:${d.key}`, phase: 'Review', schema: FINDINGS },
  ),
  (review, dim) => parallel((review?.findings ?? []).map(f => () =>
    agent(
      `${CONTEXT}\n\nAdversarially verify this review finding against the actual working-tree code. Try to REFUTE it: read the cited file/line and surrounding code. Default to isReal=false unless you can confirm it with evidence. Provide a concrete suggested fix only if real.\n\nDIMENSION: ${dim.key}\nFINDING:\n${JSON.stringify(f, null, 2)}`,
      { label: `verify:${f.file}:${f.line}`, phase: 'Review', schema: VERDICT },
    ).then(v => ({ ...f, verdict: v })),
  )).then(xs => xs.filter(Boolean)),
)
const confirmed = reviewed.flat().filter(Boolean).filter(f => f.verdict?.isReal)

return {
  spec,
  coreImplementation: coreImpl,
  macosImplementation: macImpl,
  coreBuild,
  verify: verifyResults,
  confirmedFindings: confirmed,
  allGreen: verifyResults.every(r => r.passed) && (!coreBuild || coreBuild.passed),
  note: 'Working-tree changes only — nothing committed. Review confirmedFindings, then commit to ramon-fork manually. The installed Release fork was never touched.',
}
