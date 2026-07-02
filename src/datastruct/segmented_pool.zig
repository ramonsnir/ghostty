const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A data structure where you can get stable (never copied) pointers to
/// a type that automatically grows if necessary. The values can be "put back"
/// but are expected to be put back IN ORDER.
///
/// This is implemented specifically for libuv/libxev write requests, since the
/// write requests must have a stable pointer and are guaranteed to be processed
/// in order for a single stream.
///
/// Internals: slot liveness is tracked EXPLICITLY rather than with ring
/// arithmetic. The backing `std.SegmentedList(T, prealloc)` provides the stable
/// element pointers (its existing elements never move on grow). A parallel index
/// ring (`idx`, also a `SegmentedList(usize, prealloc)` so the first `prealloc`
/// entries need no heap) holds a permutation of every slot index `0..list.len`,
/// arranged as a circular FIFO:
///
///   * `head` is the ring position of the OLDEST outstanding (vended) slot.
///   * Reading the ring circularly from `head`, the first `(list.len - available)`
///     entries are the outstanding slots in vend order (oldest first), and the
///     next `available` entries are the free slots.
///   * `get()` vends the FRONT free slot (index at ring position
///     `(head + outstanding) % len`), turning it into the newest outstanding slot.
///   * `put()` frees the OLDEST outstanding slot (index at ring position `head`)
///     and advances `head`, so the freed slot moves to the BACK of the free region.
///
/// Because a slot is only ever vended while it is genuinely in the free region,
/// a live (outstanding) slot can NEVER be handed out again, regardless of when a
/// grow happened — which is the invariant a plain ring cursor (`i % len`) broke
/// when `grow` doubled the modulus while slots were still outstanding.
///
/// `get()` and `put()` never allocate. Only `getGrow`/`grow` may allocate; they
/// keep the index ring's capacity in lockstep with the value list so `get`/`put`
/// always have room. The initial `prealloc` free indices are seeded lazily
/// (without allocation) on first use, using only the inline `prealloc` storage of
/// the index ring.
///
/// This is NOT thread safe.
pub fn SegmentedPool(comptime T: type, comptime prealloc: usize) type {
    return struct {
        const Self = @This();

        /// Backing storage for the vended values. Its elements have stable
        /// pointers across grows (SegmentedList never moves existing elements).
        list: std.SegmentedList(T, prealloc) = .{ .len = prealloc },

        /// Index ring: a permutation of `0..list.len`. See the doc comment above
        /// for the layout. `.len` is kept equal to `list.len` so `idx.at(i)` is
        /// always in bounds. Seeded on first use (see `ensureSeeded`).
        idx: std.SegmentedList(usize, prealloc) = .{},

        /// Ring position of the oldest outstanding slot.
        head: usize = 0,

        /// Number of currently-free slots.
        available: usize = prealloc,

        /// True once the index ring has been populated with the identity
        /// permutation for the initial `prealloc` slots. Deferred so a default
        /// `.{}` pool needs no allocation until first `get`/`put`.
        seeded: bool = false,

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.list.deinit(alloc);
            self.idx.deinit(alloc);
            self.* = undefined;
        }

        /// Populate the index ring with the identity permutation 0..prealloc.
        /// This is the only place `get`/`put` "touch" the ring's length, and it
        /// requires NO allocation because SegmentedList reserves `prealloc`
        /// inline slots up front (setting `.len = prealloc` and writing via
        /// `at()` within that region never allocates).
        fn ensureSeeded(self: *Self) void {
            if (self.seeded) return;
            self.idx.len = prealloc;
            var i: usize = 0;
            while (i < prealloc) : (i += 1) self.idx.at(i).* = i;
            self.seeded = true;
        }

        /// Get the next available value out of the list. This will not
        /// grow the list.
        pub fn get(self: *Self) !*T {
            // Error to not have any
            if (self.available == 0) return error.OutOfValues;
            self.ensureSeeded();

            const len = self.list.len;
            const outstanding = len - self.available;
            // The front of the free region.
            const ring_pos = @mod(self.head + outstanding, len);
            const slot = self.idx.at(ring_pos).*;

            // One fewer free slot; it is now the newest outstanding slot,
            // sitting directly after the previous outstanding tail.
            self.available -= 1;
            return self.list.at(slot);
        }

        /// Get the next available value out of the list and grow the list
        /// if necessary.
        pub fn getGrow(self: *Self, alloc: Allocator) !*T {
            if (self.available == 0) try self.grow(alloc);
            return try self.get();
        }

        fn grow(self: *Self, alloc: Allocator) !void {
            // grow is only ever called with available == 0, so every slot is
            // outstanding and the ring is full. Seed first so the transfer below
            // reads a valid permutation even on the very first use.
            self.ensureSeeded();
            assert(self.available == 0);

            const old_len = self.list.len;
            const new_len = old_len * 2;

            // Grow the value storage. Existing element pointers stay stable.
            try self.list.growCapacity(alloc, new_len);

            // Grow the index ring's capacity to hold new_len entries.
            try self.idx.growCapacity(alloc, new_len);

            // Snapshot the outstanding slots in FIFO order (oldest first). We
            // read the old ring before overwriting positions 0..old_len below.
            // Allocation is fine here (grow may allocate); get/put never reach
            // this path.
            const snapshot = try alloc.alloc(usize, old_len);
            defer alloc.free(snapshot);
            {
                var k: usize = 0;
                while (k < old_len) : (k += 1) {
                    snapshot[k] = self.idx.at(@mod(self.head + k, old_len)).*;
                }
            }

            // Renormalize the ring to head = 0: outstanding slots occupy
            // positions 0..old_len in FIFO order, and the freshly-created slot
            // indices old_len..new_len become the free region that follows.
            self.idx.len = new_len;
            {
                var k: usize = 0;
                while (k < old_len) : (k += 1) self.idx.at(k).* = snapshot[k];
                var slot: usize = old_len;
                while (slot < new_len) : (slot += 1) self.idx.at(slot).* = slot;
            }

            self.list.len = new_len;
            self.head = 0;
            self.available = old_len; // the new_len - old_len fresh slots
        }

        /// Put a value back. The value put back is expected to be the
        /// oldest-outstanding one (strict FIFO of get). Frees the slot at the
        /// head of the outstanding region.
        pub fn put(self: *Self) void {
            const len = self.list.len;
            assert(self.available < len); // debug trap on over-put

            // Runtime guard: a `put()` with nothing outstanding (available ==
            // len) would corrupt the ring — advancing `head` past the
            // outstanding window and pushing `available` above `len`. Callers
            // pair get/put 1:1 (each write completion fires exactly one put),
            // so this is unreachable in practice, but the assert above is
            // `inlineAssert` (compiled out in the ReleaseFast host), so guard at
            // runtime too: make a hypothetical over-put a safe no-op instead of
            // silent partition corruption.
            if (self.available >= len) return;

            self.ensureSeeded();

            // The oldest outstanding slot is at ring position `head`. Advancing
            // head + bumping available moves that slot to the BACK of the free
            // region (the layout invariant is preserved; see the doc comment).
            self.head = @mod(self.head + 1, len);
            self.available += 1;
        }
    };
}

test "SegmentedPool" {
    var list: SegmentedPool(u8, 2) = .{};
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), list.available);

    // Get to capacity
    const v1 = try list.get();
    const v2 = try list.get();
    try testing.expect(v1 != v2);
    try testing.expectError(error.OutOfValues, list.get());

    // Test writing for later
    v1.* = 42;

    // Put a value back. `put` frees the OLDEST outstanding slot, which is v1
    // (vended first). The next `get` vends the FRONT of the free region — and
    // since v1 was the only free slot, it comes back. (Under the free-list
    // design a put'd slot goes to the BACK of the free region, but with a single
    // free slot front == back, so this still returns v1, and the stable pointer
    // + retained value are what actually matter.)
    list.put();
    const temp = try list.get();
    try testing.expect(v1 == temp);
    try testing.expect(temp.* == 42);
    try testing.expectError(error.OutOfValues, list.get());

    // Grow. v3 is a fresh slot, distinct from both outstanding v1 and v2.
    const v3 = try list.getGrow(testing.allocator);
    try testing.expect(v1 != v3 and v2 != v3);
    _ = try list.get();
    try testing.expectError(error.OutOfValues, list.get());

    // Put a value back, then re-vend. JUSTIFICATION for changing this from the
    // old `v1 == try list.get()`: the old ring code did not track true vend-order
    // FIFO, so its assertion happened to name v1. Under the free-list design the
    // freed slot is the OLDEST OUTSTANDING one (strict FIFO of get). At this
    // point the outstanding order is [v2, v1(re-vended), v3, v4] — v2 became the
    // oldest once v1 was put back and re-gotten above — so `put` frees v2 and the
    // next `get` returns it. The load-bearing guarantees (a stable pointer comes
    // back, and it is a previously-vended one, never a live-aliased slot) still
    // hold; only the identity of *which* FIFO slot returns changed.
    list.put();
    try testing.expect(v2 == try list.get());
    try testing.expectError(error.OutOfValues, list.get());
}

test "SegmentedPool fuzz: no live aliasing across grows" {
    // Adversarial randomized test. Runs a long random sequence of getGrow/put
    // and asserts the core safety properties that the OLD ring code violated
    // after a grow-while-outstanding:
    //   (a) a getGrow-returned pointer is never equal to a currently-outstanding
    //       pointer (no live aliasing),
    //   (b) available + outstanding == list.len (count invariant),
    //   (c) a token written into a slot at vend time is still intact when that
    //       slot is later put/re-read (a live slot is never clobbered).
    const N_variants = [_]usize{ 2, 4, 8 };
    inline for (N_variants) |N| {
        const Pool = SegmentedPool(u64, N);
        var pool: Pool = .{};
        defer pool.deinit(testing.allocator);

        // Fixed seed (NOT wall-clock) for determinism.
        var prng = std.Random.DefaultPrng.init(0x5EED_0000 + @as(u64, N));
        const rand = prng.random();

        // Shadow model: outstanding slots as a FIFO of (pointer, token). The
        // pool frees the OLDEST-vended on put, so our model does the same.
        const Entry = struct { ptr: *u64, token: u64 };
        var outstanding = std.ArrayList(Entry){};
        defer outstanding.deinit(testing.allocator);

        var next_token: u64 = 1;
        const iters: usize = 220_000;
        var it: usize = 0;
        while (it < iters) : (it += 1) {
            // Randomly choose to acquire or release. Bias slightly toward
            // acquire so we spend time deep past prealloc (forcing grows), but
            // still release enough to exercise the free path.
            const do_get = outstanding.items.len == 0 or rand.boolean();
            if (do_get) {
                const ptr = try pool.getGrow(testing.allocator);

                // (a) No live aliasing: the freshly vended pointer must not be
                // any currently-outstanding pointer.
                for (outstanding.items) |e| {
                    try testing.expect(e.ptr != ptr);
                }

                // (c) integrity: stamp a unique token; verify prior tokens after.
                const token = next_token;
                next_token += 1;
                ptr.* = token;
                try outstanding.append(testing.allocator, .{ .ptr = ptr, .token = token });
            } else {
                // Release the OLDEST outstanding (FIFO), mirroring the pool.
                const oldest = outstanding.orderedRemove(0);
                // Its token must be intact right before we hand the slot back —
                // proves nothing clobbered this live slot while it was out.
                try testing.expectEqual(oldest.token, oldest.ptr.*);
                pool.put();
            }

            // (c continued): every still-outstanding slot retains its token.
            for (outstanding.items) |e| {
                try testing.expectEqual(e.token, e.ptr.*);
            }

            // (b) count invariant.
            try testing.expectEqual(
                pool.list.len,
                pool.available + outstanding.items.len,
            );
        }
    }
}

test "SegmentedPool deterministic grow-while-outstanding repro" {
    // Mirrors the real trigger (a large paste chunked into many small writes):
    // an interleaved put+get DESYNCS the internal cursor from a clean multiple
    // of `len`, THEN a getGrow past capacity happens while a slot is still
    // outstanding, and further vends make a naive `i % len` ring WRAP onto the
    // still-outstanding slot.
    //
    // The op sequence below — get, put, get, get, getGrow, put, get, get — is
    // the SHORTEST such sequence for prealloc=2 (found by exhaustive search) and
    // is verified to make the OLD ring code re-vend an outstanding slot on the
    // final get: after the grow `i == 2, len == 4`; the ops walk `i` to 4 and
    // `4 % 4 == 0` hands back slot 0, which was vended at step 4 and never put
    // back. The free-list design never re-vends a live slot, so the final get
    // here returns a pointer distinct from every outstanding one.
    const alloc = testing.allocator;
    var pool: SegmentedPool(u64, 2) = .{};
    defer pool.deinit(alloc);

    // Shadow FIFO of outstanding pointers (put frees the oldest).
    var live = std.ArrayList(*u64){};
    defer live.deinit(alloc);

    // step 1: get
    try live.append(alloc, try pool.get());
    // step 2: put (frees oldest)
    _ = live.orderedRemove(0);
    pool.put();
    // step 3: get
    try live.append(alloc, try pool.get());
    // step 4: get  (pool now exhausted; this slot stays outstanding to the end)
    try live.append(alloc, try pool.get());
    // step 5: getGrow (available == 0 → grow, then vend a fresh slot)
    try live.append(alloc, try pool.getGrow(alloc));
    // step 6: put (frees oldest outstanding)
    _ = live.orderedRemove(0);
    pool.put();
    // step 7: get
    try live.append(alloc, try pool.get());
    // step 8: get — THE WRAP POINT. Old ring returns the step-4 slot (still
    // live); the fix must return something distinct from all live pointers.
    const p = try pool.get();
    for (live.items) |q| try testing.expect(q != p);

    // And the returned slot is genuinely a free one (stable-pointer reuse): it
    // must be one previously vended, just not a currently-outstanding one.
    try live.append(alloc, p);

    // Count invariant after the whole sequence.
    try testing.expectEqual(pool.list.len, pool.available + live.items.len);
}
