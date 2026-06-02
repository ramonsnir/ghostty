//! This is the render state that is given to a renderer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Inspector = @import("../inspector/main.zig").Inspector;
const terminalpkg = @import("../terminal/main.zig");
const inputpkg = @import("../input.zig");
const renderer = @import("../renderer.zig");

/// The mutex that must be held while reading any of the data in the
/// members of this state. Note that the state itself is NOT protected
/// by the mutex and is NOT thread-safe, only the members values of the
/// state (i.e. the terminal, devmode, etc. values).
mutex: *std.Thread.Mutex,

/// The terminal data.
///
/// Under the `.exec` backend this is the live Terminal and is the source the
/// renderer's `updateFrame` reads to populate its local draw state via
/// `RenderState.update`. Always present.
terminal: *terminalpkg.Terminal,

/// Optional host-supplied draw-source mirror (Phase 2b / `.client` backend).
///
/// Under the `.client` backend the GUI process does not own a live Terminal;
/// instead a `termio.Client` decodes host frames into a `RenderState` mirror
/// (`Client.render_state`) held under the Client mutex. When this is non-null,
/// `updateFrame` populates its local draw state from this mirror (via
/// `RenderState.copyFrom`) INSTEAD of from `terminal`, and the host-side
/// writes / pin-dereferencing paths in `updateFrame` are gated off (see the
/// `state.mirror == null` guards there).
///
/// `null` under `.exec` — in which case `updateFrame` behaves exactly as it
/// did before Phase 2b (byte-for-byte). Slice 4 is what threads a non-null
/// mirror through here; today this is always null in Surface.zig.
///
/// SLICE-4-BLOCKING LOCK INVARIANT: `updateFrame` reads this mirror (via
/// `RenderState.copyFrom`) while holding `renderer_state.mutex`, but the
/// `termio.Client` WRITES the mirror under its own `Client.mutex` (a different
/// lock domain). That is a data race the moment a live mirror is wired in
/// Slice 4. It is dormant today ONLY because this field is always null
/// (`.exec`), so the copy path never runs. Slice 4 MUST reconcile the two lock
/// domains before selecting `.client` — e.g. have the Client write the mirror
/// under `renderer_state.mutex` (point both at one mutex), or have the renderer
/// acquire `Client.mutex` for the `copyFrom`. Do NOT wire a non-null mirror
/// until this is resolved.
mirror: ?*terminalpkg.RenderState = null,

/// The terminal inspector, if any. This will be null while the inspector
/// is not active and will be set when it is active.
inspector: ?*Inspector = null,

/// Dead key state. This will render the current dead key preedit text
/// over the cursor. This currently only ever renders a single codepoint.
/// Preedit can in theory be multiple codepoints long but that is left as
/// a future exercise.
preedit: ?Preedit = null,

/// Mouse state. This only contains state relevant to what renderers
/// need about the mouse.
mouse: Mouse = .{},

/// Whether `updateFrame` may take the pin-dereferencing render paths.
///
/// Two paths in the renderer's `updateFrame` index `row_data.items(.pin)`
/// and dereference `pin.node`: the OSC8 hover-link resolution
/// (`RenderState.linkCells`) and the search-highlight flatten
/// (`RenderState.updateHighlightsFlattened`). Under the `.client` backend the
/// mirror's pins are the deliberately-poisoned `invalid_pin` sentinel, so
/// dereferencing them is UB; those paths MUST be skipped.
///
/// This is the single source of truth for that gate: `updateFrame` calls it at
/// both gate sites (see `generic.zig`), and the wiring test in
/// `termio/client_difftest.zig` calls it to pin the *actual* predicate the
/// renderer evaluates (rather than re-deriving the boolean inline). If the
/// gate is ever inverted/removed at a call site, the shared predicate keeps
/// the test honest. `.exec` (mirror == null) returns true (today's behavior);
/// a `.client` mirror returns false.
///
/// NOTE: Phase 2b/3b restores search highlights host-side (shipped on the
/// GridFrame rows) and 3c restores OSC8 links host-side (host-computed
/// LinkFrame); both will replace these gated GUI-side paths.
pub fn usesLivePinPaths(self: *const @This()) bool {
    return self.mirror == null;
}

pub const Mouse = struct {
    /// The point on the viewport where the mouse currently is. We use
    /// viewport points to avoid the complexity of mapping the mouse to
    /// the renderer state.
    point: ?terminalpkg.point.Coordinate = null,

    /// The mods that are currently active for the last mouse event.
    /// This could really just be mods in general and we probably will
    /// move it out of mouse state at some point.
    mods: inputpkg.Mods = .{},
};

/// The pre-edit state. See Surface.preeditCallback for more information.
pub const Preedit = struct {
    /// The codepoints to render as preedit text.
    codepoints: []const Codepoint = &.{},

    /// A single codepoint to render as preedit text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };

    /// Deinit this preedit that was cre
    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }

    /// Allocate a copy of this preedit in the given allocator..
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{
            .codepoints = try alloc.dupe(Codepoint, self.codepoints),
        };
    }

    /// The width in cells of all codepoints in the preedit.
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| {
            result += if (cp.wide) 2 else 1;
        }

        return result;
    }

    /// Range returns the start and end x position of the preedit text
    /// along with any codepoint offset necessary to fit the preedit
    /// into the available space.
    pub fn range(
        self: *const Preedit,
        start: terminalpkg.size.CellCountInt,
        max: terminalpkg.size.CellCountInt,
    ) struct {
        start: terminalpkg.size.CellCountInt,
        end: terminalpkg.size.CellCountInt,
        cp_offset: usize,
    } {
        // If our width is greater than the number of cells we have
        // then we need to adjust our codepoint start to a point where
        // our width would be less than the number of cells we have.
        const w, const cp_offset = width: {
            // max is inclusive, so we need to add 1 to it.
            const max_width = max - start + 1;

            // Rebuild our width in reverse order. This is because we want
            // to offset by the end cells, not the start cells (if we have to).
            var w: terminalpkg.size.CellCountInt = 0;
            for (0..self.codepoints.len) |i| {
                const reverse_i = self.codepoints.len - i - 1;
                const cp = self.codepoints[reverse_i];
                w += if (cp.wide) 2 else 1;
                if (w > max_width) {
                    break :width .{ w, reverse_i };
                }
            }

            // Width fit in the max width so no offset necessary.
            break :width .{ w, 0 };
        };

        // If our preedit goes off the end of the screen, we adjust it so
        // that it shifts left.
        const end = if (w > 0) start + (w - 1) else start;
        const start_offset = if (end > max) end - max else 0;
        return .{
            .start = start -| start_offset,
            .end = end -| start_offset,
            .cp_offset = cp_offset,
        };
    }
};

const test_hangul_ga: u21 = 0xAC00; // U+AC00 HANGUL SYLLABLE GA

test "preedit range covers exact cell width" {
    const testing = std.testing;

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = 'a' }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 3), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }
}

test "preedit range shifts left at right edge" {
    const testing = std.testing;

    const p: Preedit = .{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    };
    const range = p.range(9, 9);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 8), range.start);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 9), range.end);
    try testing.expectEqual(@as(usize, 0), range.cp_offset);
}
