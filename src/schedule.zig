//! **WHEN THE NEXT POLL IS DUE**, pure: the Observatory's clock, read only
//! from the times handed to it, so its tests are numbers.
//!
//! One poll at a time. A poll is due every `period`, scheduled from when it was
//! due, never from when it ran, so lateness never accumulates (webbox's
//! `periodAfter`). A poll still running when the next comes due holds it back:
//! the next starts when the running one ends, and says how late it is.

const std = @import("std");
const webbox = @import("webbox");
const Wake = webbox.site.Wake;

pub const Schedule = struct {
    period_ns: i96,
    /// When the next poll is due; null before the first, which is due at once.
    due: ?i96 = null,
    /// A poll is running (its fetch not yet ended).
    running: bool = false,

    pub const Tick = struct {
        /// Start a poll now.
        start: bool,
        /// How late it starts, after when it was due.
        late_ns: i96 = 0,
        /// When to be called again (a poll's end calls it sooner).
        wake: Wake,
    };

    /// At `now`: whether to start a poll, and when next to be called.
    pub fn tick(self: *Schedule, now: i96) Tick {
        // A poll running ends as news: the host calls again at its end.
        if (self.running) return .{ .start = false, .wake = .idle };
        const due = self.due orelse now;
        if (now < due) return .{ .start = false, .wake = .{ .at = due } };
        self.running = true;
        self.due = webbox.site.periodAfter(due, self.period_ns, now);
        return .{ .start = true, .late_ns = now - due, .wake = .{ .at = self.due.? } };
    }

    /// The running poll ended.
    pub fn ended(self: *Schedule) void {
        self.running = false;
    }
};

const testing = std.testing;
const s = std.time.ns_per_s;

test "the first poll is at once, then one every period, from when each was due" {
    var sch: Schedule = .{ .period_ns = 60 * s };
    const t0: i96 = 5 * s;
    const first = sch.tick(t0);
    try testing.expect(first.start);
    try testing.expectEqual(@as(i96, 0), first.late_ns);
    try testing.expectEqual(Wake{ .at = t0 + 60 * s }, first.wake);
    sch.ended();
    // Called early, as a host may: nothing, and the same wake.
    const early = sch.tick(t0 + 30 * s);
    try testing.expect(!early.start);
    try testing.expectEqual(Wake{ .at = t0 + 60 * s }, early.wake);
    // Woken 2 ms late: it starts, says so, and the next is still on the minute.
    const second = sch.tick(t0 + 60 * s + 2_000_000);
    try testing.expect(second.start);
    try testing.expectEqual(@as(i96, 2_000_000), second.late_ns);
    try testing.expectEqual(Wake{ .at = t0 + 120 * s }, second.wake);
}

test "one poll at a time: a poll running when the next is due holds it, and the next says how late it starts" {
    var sch: Schedule = .{ .period_ns = 60 * s };
    _ = sch.tick(0);
    // Still running at the next one's time: no second poll, and no wake but
    // the running one's end.
    const held = sch.tick(61 * s);
    try testing.expect(!held.start);
    try testing.expectEqual(Wake.idle, held.wake);
    sch.ended();
    const next = sch.tick(62 * s);
    try testing.expect(next.start);
    try testing.expectEqual(@as(i96, 2 * s), next.late_ns);
    try testing.expectEqual(Wake{ .at = 120 * s }, next.wake);
}

test "a poll missed whole is skipped, not run twice: the next is on the next boundary" {
    var sch: Schedule = .{ .period_ns = 60 * s };
    _ = sch.tick(0);
    sch.ended();
    // Asleep through two periods (a stalled host): one poll, then the
    // boundary after now.
    const late = sch.tick(150 * s);
    try testing.expect(late.start);
    try testing.expectEqual(@as(i96, 90 * s), late.late_ns);
    try testing.expectEqual(Wake{ .at = 180 * s }, late.wake);
}
