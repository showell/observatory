//! **THE POLL ON LINUX** (metal-vmm QUEUE 228.3): the app's own `between`,
//! its host's fetch webbox's Linux one (linux_fetch), against a server on
//! 127.0.0.1 that answers twice (a restart between) and then holds its third
//! client silent until that client gives up. The schedule's clock is the
//! test's, a minute a poll; each poll's own time is the real time it took,
//! added to it, so a line's `in N ms` is what happened. Three polls cost well
//! under a second.

const std = @import("std");
const linux = std.os.linux;
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const host_fetch = webbox.host_fetch;
const linux_fetch = @import("webbox_linux").linux_fetch;
const app = @import("app.zig");

const testing = std.testing;

/// Answers its first two clients with a /version, the second with a new
/// start, and reads the third until it goes: silent, never answering.
const Server = struct {
    fd: i32,
    port: u16,

    fn open() !Server {
        const fd: i32 = @intCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
        var addr: linux.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
        if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.Bind;
        if (linux.errno(linux.listen(fd, 4)) != .SUCCESS) return error.Listen;
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        _ = linux.getsockname(fd, @ptrCast(&addr), &len);
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
    }

    fn serve(self: Server) void {
        const answers = [_][]const u8{
            "{\"result\":\"success\",\"app\":\"dog-park\",\"commit\":\"abc1234\",\"started_ms\":111,\"now_ms\":5,\"accounts\":1,\"turns_held\":0}",
            "{\"result\":\"success\",\"app\":\"dog-park\",\"commit\":\"abc1234\",\"started_ms\":222,\"now_ms\":6,\"accounts\":0,\"turns_held\":0}",
        };
        for (0..3) |k| {
            // The listening socket shut (the test ending early): no more.
            const rc = linux.accept(self.fd, null, null);
            if (linux.errno(rc) != .SUCCESS) return;
            const c: i32 = @intCast(rc);
            defer _ = linux.close(c);
            var buf: [1024]u8 = undefined;
            _ = linux.recvfrom(c, &buf, buf.len, 0, null, null);
            if (k == answers.len) {
                // Silent: read on until the client gives up and closes.
                while (true) {
                    const n = linux.recvfrom(c, &buf, buf.len, 0, null, null);
                    if (linux.errno(n) != .SUCCESS or n == 0) break;
                }
                continue;
            }
            var head: [128]u8 = undefined;
            const h = std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n", .{answers[k].len}) catch unreachable;
            _ = linux.sendto(c, h.ptr, h.len, linux.MSG.NOSIGNAL, null, 0);
            _ = linux.sendto(c, answers[k].ptr, answers[k].len, linux.MSG.NOSIGNAL, null, 0);
        }
    }

    /// Ends the server whatever it is waiting for, then waits for it.
    fn stop(self: Server, thread: std.Thread) void {
        _ = linux.shutdown(self.fd, linux.SHUT.RDWR);
        thread.join();
        _ = linux.close(self.fd);
    }
};

const Rung = struct {
    var count: std.atomic.Value(u32) = .init(0);
    fn ring(_: Io) void {
        _ = count.fetchAdd(1, .acq_rel);
    }
};

/// A data folder with `conf` as its observatory.conf, and the app set up on it.
fn setUp(io: Io, a: std.mem.Allocator, tmp: *std.testing.TmpDir, conf: []const u8) !void {
    try tmp.dir.writeFile(io, .{ .sub_path = "observatory.conf", .data = conf });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    _ = try app.setup(io, a, .{ .data_dir = dir, .auth_dir = dir });
}

fn lines(io: Io, a: std.mem.Allocator, tmp: *std.testing.TmpDir) !std.mem.SplitIterator(u8, .scalar) {
    const polls = try tmp.dir.readFileAlloc(io, "polls.txt", a, .limited(64 * 1024));
    return std.mem.splitScalar(u8, std.mem.trimEnd(u8, polls, "\n"), '\n');
}

/// `prefix`, then `in N ms` with N from `lo` to `hi`.
fn expectLine(line: ?[]const u8, prefix: []const u8, lo: u64, hi: u64) !void {
    const l = line orelse return error.NoLine;
    if (!std.mem.startsWith(u8, l, prefix)) {
        std.debug.print("line: {s}\nwant: {s} in N ms\n", .{ l, prefix });
        return error.TestUnexpectedResult;
    }
    const rest = l[prefix.len..];
    if (!std.mem.startsWith(u8, rest, " in ") or !std.mem.endsWith(u8, rest, " ms")) return error.TestUnexpectedResult;
    const ms = try std.fmt.parseInt(u64, rest[4 .. rest.len - 3], 10);
    if (ms < lo or ms > hi) {
        std.debug.print("line: {s}: {d} ms, want {d}-{d}\n", .{ l, ms, lo, hi });
        return error.TestUnexpectedResult;
    }
}

const minute: i96 = 60 * std.time.ns_per_s;

test "the Observatory on Linux: two polls ok, the second a restart, then a silent server's idle deadline; a line each, on its disk" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const server = try Server.open();
    const serving = try std.Thread.spawn(.{}, Server.serve, .{server});
    defer server.stop(serving);
    try setUp(io, a, &tmp, try std.fmt.allocPrint(a, "target = 127.0.0.1:{d} /version\ninterval_s = 60\nconnect_ms = 300\nidle_ms = 150\ntotal_ms = 1000\n", .{server.port}));
    const was = .{ host_fetch.fetcherNow(), linux_fetch.on_end };
    defer {
        host_fetch.provideOrNone(was[0]);
        linux_fetch.on_end = was[1];
    }
    host_fetch.provide(.{ .start = linux_fetch.start, .result = linux_fetch.result });
    linux_fetch.on_end = .{ .io = io, .ring = Rung.ring };

    // Three polls a minute apart by the schedule's clock, each waited for by
    // its ring; then the call its end brings, at the time it really took.
    for (0..3) |k| {
        const now: webbox.site.Now = .{ .awake_ns = @as(i96, @intCast(k)) * minute + std.time.ns_per_s, .unix_s = 1_792_228_440 + @as(i64, @intCast(k)) * 60 };
        const before = Rung.count.load(.acquire);
        const real_from = Io.Clock.now(.awake, io).nanoseconds;
        try testing.expectEqual(webbox.site.Wake{ .at = now.awake_ns + minute }, app.between(io, now));
        var waited: u32 = 0;
        while (Rung.count.load(.acquire) == before and waited < 400) : (waited += 1) {
            Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(5) }, io) catch {};
        }
        try testing.expect(Rung.count.load(.acquire) > before);
        const took = Io.Clock.now(.awake, io).nanoseconds - real_from;
        // The end's call: the line, and nothing started before its time.
        try testing.expectEqual(webbox.site.Wake{ .at = now.awake_ns + minute }, app.between(io, .{ .awake_ns = now.awake_ns + took, .unix_s = now.unix_s }));
    }

    var it = try lines(io, a, &tmp);
    try expectLine(it.next(), "2026-10-17T09:14:00Z ok 200 commit abc1234 started 111 accounts 1 turns 0", 0, 300);
    try expectLine(it.next(), "2026-10-17T09:15:00Z ok 200 commit abc1234 started 222 (restarted) accounts 0 turns 0", 0, 300);
    // Silent for its idle bound (150 ms): said so, not before.
    try expectLine(it.next(), "2026-10-17T09:16:00Z idle_deadline", 150, 1000);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

/// A host's fetch that refuses its first start, then answers at once.
const Refusing = struct {
    var starts: u32 = 0;
    var pending: bool = false;
    fn start(_: host_fetch.Target, _: host_fetch.Deadlines) host_fetch.StartError!void {
        starts += 1;
        if (starts == 1) return error.Busy;
        pending = true;
    }
    fn result() ?host_fetch.Result {
        if (!pending) return null;
        pending = false;
        return .{ .outcome = .ok, .status = 200, .body = "{\"commit\":\"abc1234\",\"started_ms\":7}" };
    }
};

test "a poll its host would not start is a line, and the next poll is still on its minute" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try setUp(io, a, &tmp, "target = 10.0.2.15:80 /version\n");
    const was = host_fetch.fetcherNow();
    defer host_fetch.provideOrNone(was);
    host_fetch.provide(.{ .start = Refusing.start, .result = Refusing.result });

    const t0: i96 = std.time.ns_per_s;
    try testing.expectEqual(webbox.site.Wake{ .at = t0 + minute }, app.between(io, .{ .awake_ns = t0, .unix_s = 1_792_228_440 }));
    try testing.expectEqual(webbox.site.Wake{ .at = t0 + 2 * minute }, app.between(io, .{ .awake_ns = t0 + minute, .unix_s = 1_792_228_500 }));
    _ = app.between(io, .{ .awake_ns = t0 + minute + 3 * std.time.ns_per_ms, .unix_s = 1_792_228_500 });
    var it = try lines(io, a, &tmp);
    try testing.expectEqualStrings("2026-10-17T09:14:00Z not-started Busy", it.next().?);
    try expectLine(it.next(), "2026-10-17T09:15:00Z ok 200 commit abc1234 started 7", 3, 3);
}
