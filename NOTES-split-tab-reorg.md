# Notes: Reorganizing splits & tabs (macOS) — feasibility + design

Scratch notes for a personal feature exploration. **Scope: macOS only.** Not
intended for upstream (at least not soon). Researched against `main` @ `3103ae883`.

## TL;DR feasibility

All four requested capabilities are **feasible**, and most of the hard part is
already built:

| Feature | Difficulty | Why |
|---|---|---|
| **Eject a split into its own tab** | Low–Med | Surface reparenting already exists; need a "new tab from tree" variant of an existing "new window from tree" path. |
| **Combine tabs into one (with a split)** | Med | Reparenting + closing the donor window/tab; one new pure tree op. |
| **Flip/mirror a split (swap L↔R)** | Low | One pure value-type tree transform + a tiny bit of wiring. |
| **Toggle split horizontal↔vertical** | Low | One pure value-type tree transform + a tiny bit of wiring. |

The split layout is an **immutable value-typed tree** (`SplitTree<SurfaceView>`),
so all the geometry operations are pure functions that are trivial to unit-test
without launching the app. The terminal panes (`SurfaceView`) are reference-typed
`NSView`s that can be freely moved between trees/windows — Ghostty already does
this for drag-and-drop. That's the key enabler for eject/combine/move.

---

## How the system works

### 1. The data model: `SplitTree`

`macos/Sources/Features/Splits/SplitTree.swift`

- A **value type** (`struct`) wrapping an immutable, indirect enum tree:
  - `Node.leaf(view: SurfaceView)` — a terminal pane.
  - `Node.split(Split)` where `Split` = `{ direction, ratio, left: Node, right: Node }`.
  - `Direction` is `.horizontal` (left|right) or `.vertical` (top/bottom).
  - Tree also tracks an optional `zoomed: Node`.
- All mutations return a **new tree** (copy-on-write style). Existing ops:
  - `inserting(view:at:direction:)` (`:125`) — split an existing leaf, insert a *new leaf* beside it.
  - `removing(_ node:)` (`:141`) — remove a node; sibling collapses up into the parent's place.
  - `replacing(node:with:)` (`:159`) — swap a node for another node.
  - `resizing(node:by:in:with:)` (`:259`) — adjust the nearest parent split's ratio.
  - `equalized()` (`:236`).
  - Navigation helpers: `path(to:)` (`:446`), `node(at:)` (`:480`), `find(id:)`, `focusTarget(for:from:)`, plus a `Spatial` projection for directional navigation/resize.
  - Memberwise `init(root:zoomed:)` and `init(view:)` are available in-module.
- Crucially: **leaves hold the same `SurfaceView` object by identity** (`==` on
  `.leaf` is `===`). Moving a pane = moving its `Node` reference between trees;
  no terminal/PTY teardown happens.

### 2. The controller owns the tree

`macos/Sources/Features/Terminal/BaseTerminalController.swift` (+ `TerminalController.swift` subclass)

- Holds `@Published var surfaceTree`. `replaceSurfaceTree(_:moveFocusTo:moveFocusFrom:undoAction:)`
  (`BaseTerminalController.swift:484`) is the single choke-point for swapping in a
  new tree; it also wires up **undo/redo** (every structural change is undoable).
- Existing structural ops on the controller:
  - `newSplit(at:direction:baseConfig:)` (`:236`) — makes a new `SurfaceView`, calls `tree.inserting(...)`.
  - `closeSurface(_:)` / `removeSurfaceNode(_:)` (`:402` / `:462`) — remove + refocus + undo.
  - `splitDidResize` / `splitDidDrop` (`:902` / `:911`) — handle SwiftUI drag/resize ops.
- **Reparenting already exists** (this is the big one):
  - `splitDidDrop(source:destination:zone:)` (`:911`) handles dragging a pane onto
    another pane. It covers **same-window** moves *and* **cross-window** moves: it
    searches all `NSApp.windows` for the controller owning the source surface,
    `sourceController.removeSurfaceNode(sourceNode)`, then inserts into the
    destination tree — all wrapped in one undo group (`:944`–`:988`).
  - `ghosttySurfaceDragEndedNoTarget(_:)` (`:753`) **ejects a pane into a brand-new
    window**: `surfaceTree.removing(node)` on the source, `SplitTree(view: target)`
    for the new window, then `TerminalController.newWindow(ghostty, tree:position:...)`.

  → Eject-to-new-window is *done*. Eject-to-*tab* is the same logic with a
  different "create destination" call. Combine is the inverse: graft one tree
  into another and close the donor.

### 3. Tabs = native macOS `NSWindow` tabs

`macos/Sources/Features/Terminal/TerminalController.swift`

- Each **tab is its own `TerminalController`/`NSWindow`**, grouped via AppKit
  tabbing (`addTabbedWindowSafely`, `window.tabGroup`). There is no custom tab
  data structure to fight with.
- Window/tab creation from an existing tree:
  - `TerminalController.init(ghostty, withSurfaceTree:)` (`:66`/`:79`) — builds a
    controller around a pre-existing tree.
  - `static func newWindow(_:tree:position:confirmUndo:inheritBackgroundOpacity:)`
    (`:340`) — new **window** from a tree. ✅ exists.
  - `static func newTab(_:from:withBaseConfig:)` (`:407`) — new **tab**, but only
    ever creates a *fresh single surface* (`init(..., withBaseConfig:)`). ❌ there
    is **no `newTab(tree:)`** — this is the one gap to fill for "eject to tab".

### 4. How an action reaches the controller (the full plumbing)

```
keypress / command palette
  → libghostty parses keybind         (src/input/Binding.zig: Action union)
  → Surface.performBindingAction()     (src/Surface.zig: switch over Action)
  → rt_app.performAction(...)          (apprt action: src/apprt/action.zig)
  → Ghostty.App.swift performAction switch on GHOSTTY_ACTION_*  (:493)
  → NotificationCenter.post(.ghosttyNewSplit / .didEqualizeSplits / ...)
  → BaseTerminalController @objc handler (registered :176–215)
  → mutate surfaceTree via replaceSurfaceTree(...)
```

- The **command palette** is *not* a separate system: it's auto-derived from the
  `Binding.Action`s listed in `src/input/command.zig` (`defaults`). The macOS
  palette reads them through `config.commandPaletteEntries`
  (`Ghostty.Config.swift:733`) and, when chosen, sends the action string back into
  libghostty via `ghostty_surface_binding_action` — i.e. it re-enters the same
  Zig path above.
- **Implication:** a *configurable keybind* or a *built-in command-palette entry*
  requires defining the action in Zig (3 layers) **and** handling it in Swift.

---

## Two implementation paths

### Path A — Canonical / cross-platform (more work)
Add the action through every layer:
1. `src/input/Binding.zig` — add to the `Action` union (e.g. `eject_split_to_tab`, `toggle_split_direction`, `flip_split`, `combine_tabs`).
2. `src/apprt/action.zig` — add a matching apprt `Action` variant (+ C enum in `include/ghostty.h` / `src/apprt/embedded.zig`).
3. `src/Surface.zig` `performBindingAction` — dispatch it to `rt_app.performAction`.
4. `src/input/command.zig` `defaults` — add a `Command{ .action, .title, .description }` so it shows in the palette.
5. `macos/Sources/Ghostty/Ghostty.App.swift` `performAction` switch — handle `GHOSTTY_ACTION_*`, post a `NotificationCenter` notification.
6. `BaseTerminalController` — register observer + `@objc` handler that mutates the tree.

Gets you: config-file keybinds (`keybind = cmd+shift+e=eject_split_to_tab`),
command-palette entries, and a shape that could be upstreamed later. GTK side can
be left unimplemented (no-op) for a macOS-only build.

### Path B — macOS-only shortcut (recommended for a personal one-off)
Skip Zig entirely. Wire the new ops as **menu items + `@IBAction`s** and/or
**Swift-injected command-palette entries**:
- Add `@IBAction func ejectSplitToTab(_:)` etc. on `TerminalController` (sibling to
  the existing `@IBAction func newTab(_:)` at `TerminalController.swift:1272`),
  give the menu items key equivalents in the MainMenu for keyboard shortcuts.
- For palette discoverability without Zig: the macOS palette's option list is
  assembled in Swift in `TerminalCommandPaletteView.commandOptions`
  (`TerminalCommandPalette.swift:59`). You can append custom `CommandOption`s whose
  callbacks invoke the controller methods directly.

Gets you: menu items, fixed keyboard shortcuts, and (optionally) palette entries —
all with no Zig rebuild. **Downside:** shortcuts aren't user-configurable via the
config file, and it won't upstream as-is.

> For "won't be merged for a long time," **Path B** is the fast route. The core
> tree work below is identical regardless of path.

---

## Feature-by-feature design

All four ultimately call `replaceSurfaceTree(...)` (or create a new
controller/window) with a tree produced by a **pure transform**. Add the
transforms to `SplitTree.swift` and unit-test them in isolation.

### A. Eject a split into its own tab
A "split" the user wants out = the **focused leaf**, OR an enclosing **subtree**
(to pull out a 2–4 pane group). Operate on a `Node` so both work.

Reuse the `ghosttySurfaceDragEndedNoTarget` recipe but target a tab:
1. `guard surfaceTree.isSplit` (don't eject the only pane).
2. `let node = surfaceTree.root!.node(view: focusedSurface)` (or a chosen subtree).
3. `let newTree = SplitTree(root: node, zoomed: nil)` — preserves multi-pane subtrees.
4. `replaceSurfaceTree(surfaceTree.removing(node), moveFocusFrom: oldFocus)`.
5. Create a **tab** from `newTree` — needs the new `newTab(tree:)` (see gap in §3).
   Factor the tab-group plumbing out of `newTab(_:from:withBaseConfig:)` so it can
   accept `init(ghostty, withSurfaceTree: newTree)` instead of a fresh surface.
6. Wrap 4–5 in one `undoManager` group (mirror `:774`–`:788`).

No new pure transform needed (`removing` + `init(root:)` suffice). The only real
code is the `newTab(tree:)` variant.

### B. Combine tabs into one tab with a split
Tabs are sibling `TerminalController`s in the same `window.tabGroup`.
Decide the UX first (a choice for you): combine **current + adjacent tab**, or
**all tabs in the window** (fold left-to-right). Per pair:
1. Pick `direction` (horizontal/vertical) and which side each tab goes.
2. New pure op on `SplitTree`:
   ```swift
   func combined(with other: SplitTree, direction: Direction, ratio: Double = 0.5,
                 otherOnRight: Bool = true) -> SplitTree
   // root = .split(direction, ratio, left: self.root, right: other.root)  (or swapped)
   ```
3. On the **keeper** controller: `replaceSurfaceTree(keeper.surfaceTree.combined(with: donor.surfaceTree, ...))`.
4. On the **donor** controller: set its tree empty *without* the close-confirmation
   (the panes were reparented, not killed), then `closeWindowImmediately()`. Be
   careful: `closeSurface`/`removeSurfaceNode` paths can prompt "process still
   running" — bypass that since nothing is actually closing.
5. One undo group spanning both controllers (mirror the cross-window drop at
   `:973`–`:988`).

Watch-outs: zoom state (`zoomed`) on either tab; window content sizing; focus
target after merge.

### C. Flip / mirror a split (swap left ↔ right)
Acts on the **nearest enclosing split** of the focused leaf (a leaf has no children
to swap), analogous to how `resizing` walks up to the parent split.
1. New pure ops:
   ```swift
   // SplitTree.Node
   func swappingChildren() -> Node   // .split(d,r,l,rt) -> .split(d, 1-r? or r, rt, l)
   // SplitTree
   func swappingChildren(of split: Node) throws -> Self  // uses path(to:)+replacingNode
   ```
   Note: when swapping children, also map `ratio -> 1 - ratio` so the visual
   boundary stays put (otherwise panes resize on flip).
2. Find the parent split: `path(to: .leaf(view: focused))`, drop the last
   component, `node(at: parentPath)`.
3. `replaceSurfaceTree(try surfaceTree.swappingChildren(of: parentSplit), undoAction: "Flip Split")`.

Combined with rotate (D) + the existing move/drop, this reaches arbitrary
recombinations as the user described.

### D. Toggle split direction (horizontal ↔ vertical)
Same targeting as C (nearest enclosing split):
1. New pure ops:
   ```swift
   func togglingDirection() -> Node   // flips .horizontal <-> .vertical, keeps children+ratio
   func togglingDirection(of split: Node) throws -> Self
   ```
2. `replaceSurfaceTree(try surfaceTree.togglingDirection(of: parentSplit), undoAction: "Toggle Split Direction")`.

Simplest of the four. (Optional: also offer "rotate" = toggle direction *and* swap,
which visually rotates a 2-pane split 90°.)

---

## Testing (one-off, local macOS)

### Build / run
```bash
# Only if you touch Zig (Path A): rebuild the lib first.
zig build -Demit-macos-app=false

# Build the macOS app (per macos/AGENTS.md — use build.nu, NOT zig build):
macos/build.nu --configuration Debug --action build
# → macos/build/Debug/Ghostty.app
open macos/build/Debug/Ghostty.app
```

### Unit tests for the pure transforms (fast, no app launch) — do this first
There's already a harness: `macos/Tests/Splits/SplitTreeTests.swift` uses
swift-testing (`@Test`) with a `MockView: NSView, Codable, Identifiable` and
helpers like `makeHorizontalSplit()`. Add tests there for the new ops:

- `combined(with:direction:)` — leaf counts, structure, ratio, zoom reset.
- `swappingChildren(of:)` — children swapped, `ratio == 1 - original`, idempotent ×2 == identity.
- `togglingDirection(of:)` — direction flipped, children/ratio preserved, ×2 == identity.
- Eject: `removing(node)` + `SplitTree(root: node)` yields two well-formed trees
  whose leaf sets partition the original.

Run them:
```bash
macos/build.nu --action test
# or filter in Xcode: open macos/Ghostty.xcodeproj, run GhosttyTests > SplitTreeTests
```
These are the highest-value tests because the geometry logic is exactly the part
that's easy to get subtly wrong, and it's all pure functions.

### Manual smoke testing (the reparenting / undo / focus parts)
Pure-function tests can't cover NSWindow tab-group behavior, focus, or undo. After
building, manually verify:
1. **Eject:** 2–4 panes in one tab → eject focused pane → it appears as a new tab,
   original tab collapses correctly, focus lands sensibly. Eject a *subtree* (if
   exposed) keeps its internal layout. ⌘Z restores.
2. **Combine:** two tabs → combine → single tab with a split holding both former
   layouts; donor tab/window closes *without* a "process running" prompt; no PTYs
   die (run `sleep 999` in a pane first to confirm it survives). ⌘Z restores.
3. **Flip:** split panes → flip → left/right (or top/bottom) swap; the divider stays
   in place (ratio inverted), content not resized. Double-flip == no-op.
4. **Toggle direction:** side-by-side → toggle → stacked, same two panes, same focus.
5. **Edge cases:** single-pane tab (eject = no-op), zoomed pane active during each
   op, fullscreen tab (native tabs disabled — `newTab` already guards this at
   `TerminalController.swift:421`), 4-pane nested layouts.

`HACKING.md` documents general build steps; `macos/AGENTS.md` is authoritative for
the macOS app build/test commands used above.

---

## Key files (reference)

| Concern | File:line |
|---|---|
| Split tree value type + all transforms | `macos/Sources/Features/Splits/SplitTree.swift` |
| Controller: tree ownership, undo choke-point | `BaseTerminalController.swift:484` (`replaceSurfaceTree`) |
| Existing reparenting (same/cross window) | `BaseTerminalController.swift:911` (`splitDidDrop`) |
| Existing "eject to new window" | `BaseTerminalController.swift:753` |
| New split (creates fresh surface) | `BaseTerminalController.swift:236` |
| Window-from-tree (model for tab-from-tree) | `TerminalController.swift:340` (`newWindow(tree:)`) |
| New tab (the gap — no tree variant) | `TerminalController.swift:407` (`newTab`) |
| Controller-from-tree initializer | `TerminalController.swift:66` (`withSurfaceTree`) |
| SwiftUI rendering of the tree + drop zones | `Features/Splits/TerminalSplitTreeView.swift` |
| Existing tests / mock harness | `macos/Tests/Splits/SplitTreeTests.swift` |
| (Path A) keybind action union | `src/input/Binding.zig` (`new_split` ~`:629`, `resize_split` ~`:656`, `equalize_splits` ~`:661`) |
| (Path A) apprt action + C enum | `src/apprt/action.zig`, `include/ghostty.h`, `src/apprt/embedded.zig` |
| (Path A) action dispatch | `src/Surface.zig` `performBindingAction` |
| (Path A) command palette defaults | `src/input/command.zig` (`defaults`) |
| (Path A→Swift) action → notification | `macos/Sources/Ghostty/Ghostty.App.swift:493` (`performAction`) |
| (Path B) Swift palette option assembly | `Features/Command Palette/TerminalCommandPalette.swift:59` |

## Open UX decisions (for you)
- Eject: eject just the focused leaf, or the whole enclosing subtree? (Support both.)
- Combine: current+adjacent tab, or fold all tabs in the window? Which direction/order?
- Flip/rotate/toggle: operate on the *nearest enclosing split* of the focused pane
  (recommended) vs. the root split.
