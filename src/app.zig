//! **THE OBSERVATORY, VERSION ONE** (metal-vmm QUEUE 228; the essay
//! `notes/the-observatory-v1.md`): a machine that wakes every `interval_s`,
//! asks one server for its `/version` through its host's fetch
//! (webbox's `host_fetch`), writes one line about it, and sleeps.
//!
//!     2026-10-17T09:14:00Z ok 200 commit fb3253d started 1789000000000 accounts 3 turns 2 in 41 ms
//!     2026-10-17T09:15:00Z connect_deadline in 150 ms
//!     2026-10-17T09:16:00Z ok 200 commit fb3253d started 1789000960000 (restarted) accounts 0 turns 0 in 38 ms
//!
//! The outcome word is the host's (host_fetch's, the kernel client's), so a
//! line reads the same on metal and on Linux. A line is appended to
//! `polls.txt` in its data and said on the host's console; the page `/` is the
//! newest lines and a count of each outcome since the start.
//!
//! **ITS CONF, `observatory.conf` IN ITS DATA**, a setting a line:
//!
//!     target = 10.100.0.3:80 /version
//!     interval_s = 60
//!     connect_ms = 1000
//!     idle_ms = 3000
//!     total_ms = 10000
//!
//! The target has no default: without one the start fails, rather than poll
//! something nobody chose. The rest default to what the lines above say: a
//! server on the private network answers in tens of ms, and one that does not
//! is said so well before the next poll.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const host_fetch = webbox.host_fetch;
const Schedule = @import("schedule.zig").Schedule;
const version = @import("version.zig");

pub const Conf = struct {
    target: host_fetch.Target,
    interval_s: u32 = 60,
    /// Each poll's bounds.
    deadlines: host_fetch.Deadlines = .{ .connect_ms = 1000, .idle_ms = 3000, .total_ms = 10_000 },
};

pub const ConfError = error{ NoTarget, BadTarget, BadInterval, BadDeadline, UnknownSetting };

var target_path: [host_fetch.path_most]u8 = undefined;

/// The conf's text, read: its path is copied into `target_path`.
pub fn parseConf(text: []const u8) ConfError!Conf {
    var target: ?host_fetch.Target = null;
    var c: Conf = .{ .target = undefined };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.UnknownSetting;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "target")) {
            target = targetOf(value) orelse return error.BadTarget;
        } else if (std.mem.eql(u8, key, "interval_s")) {
            c.interval_s = std.fmt.parseInt(u32, value, 10) catch return error.BadInterval;
            if (c.interval_s == 0) return error.BadInterval;
        } else if (std.mem.eql(u8, key, "connect_ms")) {
            c.deadlines.connect_ms = try msOf(value);
        } else if (std.mem.eql(u8, key, "idle_ms")) {
            c.deadlines.idle_ms = try msOf(value);
        } else if (std.mem.eql(u8, key, "total_ms")) {
            c.deadlines.total_ms = try msOf(value);
        } else return error.UnknownSetting;
    }
    c.target = target orelse return error.NoTarget;
    return c;
}

fn msOf(value: []const u8) ConfError!u32 {
    const n = std.fmt.parseInt(u32, value, 10) catch return error.BadDeadline;
    return if (n == 0) error.BadDeadline else n;
}

/// `10.100.0.3:80 /version`.
fn targetOf(v: []const u8) ?host_fetch.Target {
    const space = std.mem.indexOfScalar(u8, v, ' ') orelse return null;
    const where = v[0..space];
    const path = std.mem.trim(u8, v[space..], " \t");
    const colon = std.mem.indexOfScalar(u8, where, ':') orelse return null;
    var ip: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, where[0..colon], '.');
    for (&ip) |*b| b.* = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null or path.len == 0 or path[0] != '/' or path.len > target_path.len) return null;
    @memcpy(target_path[0..path.len], path);
    return .{ .ip = ip, .port = std.fmt.parseInt(u16, where[colon + 1 ..], 10) catch return null, .path = target_path[0..path.len] };
}

/// **ONE POLL'S LINE**: when it started, its outcome, and what the server
/// said, or how long it took to fail. `previous` is the start the last poll
/// read, so a new one says the server restarted.
pub fn formatLine(w: *std.Io.Writer, when: []const u8, r: host_fetch.Result, v: ?version.Version, previous: ?u64, took_ms: u64, late_ms: u64) !void {
    try w.print("{s} {t}", .{ when, r.outcome });
    if (r.outcome == .ok) {
        try w.print(" {d}", .{r.status});
        if (v) |got| {
            try w.print(" commit {s} started {d}", .{ got.commit, got.started_ms });
            if (previous) |p| if (p != got.started_ms) try w.writeAll(" (restarted)");
            if (got.accounts) |n| try w.print(" accounts {d}", .{n});
            if (got.turns_held) |n| try w.print(" turns {d}", .{n});
        } else try w.writeAll(" not a /version");
    } else if (r.status != 0) try w.print(" {d}", .{r.status});
    try w.print(" in {d} ms", .{took_ms});
    if (late_ms > 0) try w.print(" (late {d} ms)", .{late_ms});
}

// ── the running Observatory ────────────────────────────────────────────────

var conf: Conf = undefined;
var schedule: Schedule = .{ .period_ns = 60 * std.time.ns_per_s };
var data_root: []const u8 = "data";
var polls_path: []const u8 = "data/polls.txt";
/// The poll running: when it began, by both clocks, and how late.
var began_awake: i96 = 0;
var began_unix: i64 = 0;
var late_ns: i96 = 0;
/// The last start the server said, to see a restart.
var last_started: ?u64 = null;
/// How each poll ended since the start.
var counts: std.EnumArray(host_fetch.Outcome, u64) = .initFill(0);
var not_started: u64 = 0;

/// The newest lines, for the page: a ring of them.
const kept_lines = 100;
const line_most = 240;
var ring: [kept_lines][line_most]u8 = undefined;
var ring_lens: [kept_lines]usize = @splat(0);
var ring_next: usize = 0;
var ring_count: usize = 0;

/// For a poll's JSON and line: nothing outlives the call that uses it.
var scratch: [96 * 1024]u8 = undefined;

pub const StartReport = struct { target: host_fetch.Target, interval_s: u32, data_dir: []const u8 };

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    if (roots) |r| data_root = r.data_dir;
    try webbox.store.makeDir(io, base, data_root);
    polls_path = try std.fmt.allocPrint(base, "{s}/polls.txt", .{data_root});
    const conf_path = try std.fmt.allocPrint(base, "{s}/observatory.conf", .{data_root});
    const text = webbox.store.read(io, base, conf_path, .limited(4096)) catch |e| switch (e) {
        error.FileNotFound => return error.NoObservatoryConf,
        else => return e,
    };
    conf = try parseConf(text);
    schedule = .{ .period_ns = @as(i96, conf.interval_s) * std.time.ns_per_s };
    return .{ .target = conf.target, .interval_s = conf.interval_s, .data_dir = data_root };
}

pub fn between(io: Io, now: webbox.site.Now) webbox.site.Wake {
    if (host_fetch.result()) |r| {
        record(io, r, @intCast(@max(0, @divTrunc(now.awake_ns - began_awake, std.time.ns_per_ms))));
        schedule.ended();
    }
    const t = schedule.tick(now.awake_ns);
    if (t.start) {
        began_awake = now.awake_ns;
        began_unix = now.unix_s;
        late_ns = t.late_ns;
        host_fetch.start(conf.target, conf.deadlines) catch |e| {
            not_started += 1;
            note(io, "{s} not started: {t}", .{ whenOf(now.unix_s), e });
            schedule.ended();
        };
    }
    return t.wake;
}

fn record(io: Io, r: host_fetch.Result, took_ms: u64) void {
    counts.getPtr(r.outcome).* += 1;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const v = if (r.outcome == .ok) version.parse(fba.allocator(), r.body) else null;
    var buf: [line_most]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    formatLine(&w, &whenOf(began_unix), r, v, last_started, took_ms, @intCast(@divTrunc(late_ns, std.time.ns_per_ms))) catch {};
    if (v) |got| last_started = got.started_ms;
    keep(io, w.buffered());
}

fn note(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [line_most]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(fmt, args) catch {};
    keep(io, w.buffered());
}

/// A line: the ring, the file, the console.
fn keep(io: Io, line: []const u8) void {
    const n = @min(line.len, line_most);
    @memcpy(ring[ring_next][0..n], line[0..n]);
    ring_lens[ring_next] = n;
    ring_next = (ring_next + 1) % kept_lines;
    ring_count = @min(ring_count + 1, kept_lines);
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const with_newline = std.fmt.allocPrint(fba.allocator(), "{s}\n", .{line[0..n]}) catch return;
    _ = webbox.store.append(io, fba.allocator(), polls_path, with_newline) catch {};
    webbox.host_facts.say(line[0..n]);
}

/// `2026-10-17T09:14:00Z`, or `(no clock)` before the wall clock is set.
fn whenOf(unix: i64) [20]u8 {
    var out: [20]u8 = "(no clock)          ".*;
    if (unix <= 0) return out;
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch {};
    return out;
}

pub fn bodyLimit(_: []const u8) u64 {
    return 0;
}

pub fn routes(req: *std.http.Server.Request, _: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    const path = webbox.http.pathOf(try webbox.http.target(req, alloc));
    if (!std.mem.eql(u8, path, "/")) return webbox.http.notFound(req);
    if (req.head.method != .GET) return webbox.http.methodNotAllowed(req, .GET);
    var page: std.ArrayList(u8) = .empty;
    const t = conf.target;
    try page.print(alloc, "The Observatory: {d}.{d}.{d}.{d}:{d} {s} every {d} s\n\n", .{ t.ip[0], t.ip[1], t.ip[2], t.ip[3], t.port, t.path, conf.interval_s });
    var it = counts.iterator();
    while (it.next()) |e| if (e.value.* > 0) try page.print(alloc, "{t}: {d}\n", .{ e.key, e.value.* });
    if (not_started > 0) try page.print(alloc, "not started: {d}\n", .{not_started});
    try page.appendSlice(alloc, "\n");
    for (0..ring_count) |k| {
        const i = (ring_next + kept_lines - 1 - k) % kept_lines;
        try page.print(alloc, "{s}\n", .{ring[i][0..ring_lens[i]]});
    }
    try req.respond(page.items, .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the conf: a target and an interval; no target is refused, and so is anything unknown" {
    const c = try parseConf("target = 10.100.0.3:80 /version\ninterval_s = 60\n");
    try testing.expectEqual([4]u8{ 10, 100, 0, 3 }, c.target.ip);
    try testing.expectEqual(@as(u16, 80), c.target.port);
    try testing.expectEqualStrings("/version", c.target.path);
    try testing.expectEqual(@as(u32, 60), c.interval_s);
    try testing.expectEqual(@as(u32, 60), (try parseConf("# the default interval\ntarget = 10.0.2.15:80 /version")).interval_s);
    try testing.expectError(error.NoTarget, parseConf("interval_s = 60\n"));
    try testing.expectError(error.BadTarget, parseConf("target = 10.0.2:80 /version\n"));
    try testing.expectError(error.BadTarget, parseConf("target = 10.0.2.15:80 version\n"));
    try testing.expectError(error.BadInterval, parseConf("target = 10.0.2.15:80 /\ninterval_s = 0\n"));
    try testing.expectError(error.UnknownSetting, parseConf("target = 10.0.2.15:80 /\nintervel_s = 5\n"));
    try testing.expectEqual(@as(u32, 200), (try parseConf("target = 10.0.2.15:80 /\nidle_ms = 200\n")).deadlines.idle_ms);
    try testing.expectError(error.BadDeadline, parseConf("target = 10.0.2.15:80 /\ntotal_ms = 0\n"));
}

test "a poll's line: what the server said, a restart, a failure, lateness" {
    var buf: [line_most]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ok: host_fetch.Result = .{ .outcome = .ok, .status = 200, .body = "" };
    const v: version.Version = .{ .commit = "fb3253d", .started_ms = 1789000000000, .accounts = 3, .turns_held = 2 };
    try formatLine(&w, "2026-10-17T09:14:00Z", ok, v, 1789000000000, 41, 0);
    try testing.expectEqualStrings("2026-10-17T09:14:00Z ok 200 commit fb3253d started 1789000000000 accounts 3 turns 2 in 41 ms", w.buffered());
    w = .fixed(&buf);
    try formatLine(&w, "2026-10-17T09:16:00Z", ok, .{ .commit = "fb3253d", .started_ms = 1789000960000 }, 1789000000000, 38, 0);
    try testing.expectEqualStrings("2026-10-17T09:16:00Z ok 200 commit fb3253d started 1789000960000 (restarted) in 38 ms", w.buffered());
    w = .fixed(&buf);
    try formatLine(&w, "2026-10-17T09:15:00Z", .{ .outcome = .connect_deadline, .status = 0, .body = "" }, null, null, 1000, 0);
    try testing.expectEqualStrings("2026-10-17T09:15:00Z connect_deadline in 1000 ms", w.buffered());
    w = .fixed(&buf);
    try formatLine(&w, "2026-10-17T09:17:00Z", .{ .outcome = .bad_answer, .status = 503, .body = "" }, null, null, 12, 2000);
    try testing.expectEqualStrings("2026-10-17T09:17:00Z bad_answer 503 in 12 ms (late 2000 ms)", w.buffered());
    w = .fixed(&buf);
    try formatLine(&w, "2026-10-17T09:18:00Z", ok, null, null, 9, 0);
    try testing.expectEqualStrings("2026-10-17T09:18:00Z ok 200 not a /version in 9 ms", w.buffered());
}

test "a time is said in UTC, and a clock not yet set says so" {
    try testing.expectEqualStrings("2026-10-17T09:14:00Z", &whenOf(1792228440));
    try testing.expectEqualStrings("(no clock)          ", &whenOf(0));
}

test {
    _ = @import("schedule.zig");
    _ = @import("version.zig");
}
