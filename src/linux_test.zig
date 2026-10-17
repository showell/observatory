//! **THE POLL ON LINUX** (metal-vmm QUEUE 228.3): the app's own `between`,
//! its host's fetch webbox's Linux one (linux_fetch), against a server on
//! 127.0.0.1 that answers twice (a restart between) and then goes silent. The
//! schedule runs on a clock the test hands it, a minute a poll; only the
//! fetches take real time, so three polls cost well under a second.

const std = @import("std");
const linux = std.os.linux;
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const linux_fetch = @import("webbox_linux").linux_fetch;
const app = @import("app.zig");

const testing = std.testing;

/// Answers its first two clients with a /version, the second with a new
/// start, and holds the third silent until the test is done.
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

    fn serve(self: Server, io: Io) void {
        const answers = [_][]const u8{
            "{\"result\":\"success\",\"app\":\"dog-park\",\"commit\":\"abc1234\",\"started_ms\":111,\"now_ms\":5,\"accounts\":1,\"turns_held\":0}",
            "{\"result\":\"success\",\"app\":\"dog-park\",\"commit\":\"abc1234\",\"started_ms\":222,\"now_ms\":6,\"accounts\":0,\"turns_held\":0}",
        };
        for (0..3) |k| {
            const c: i32 = @intCast(linux.accept(self.fd, null, null));
            defer _ = linux.close(c);
            var buf: [1024]u8 = undefined;
            _ = linux.recvfrom(c, &buf, buf.len, 0, null, null);
            if (k == answers.len) {
                Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(500) }, io) catch {};
                continue;
            }
            var head: [128]u8 = undefined;
            const h = std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\n\r\n", .{answers[k].len}) catch unreachable;
            _ = linux.sendto(c, h.ptr, h.len, linux.MSG.NOSIGNAL, null, 0);
            _ = linux.sendto(c, answers[k].ptr, answers[k].len, linux.MSG.NOSIGNAL, null, 0);
        }
    }
};

const Rung = struct {
    var count: std.atomic.Value(u32) = .init(0);
    fn ring(_: Io) void {
        _ = count.fetchAdd(1, .acq_rel);
    }
};

test "the Observatory on Linux: two polls ok, the second a restart, then a silent server's idle deadline; a line each, on its disk" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const server = try Server.open();
    defer _ = linux.close(server.fd);
    const serving = try std.Thread.spawn(.{}, Server.serve, .{ server, io });
    defer serving.join();
    const conf = try std.fmt.allocPrint(a, "target = 127.0.0.1:{d} /version\ninterval_s = 60\nconnect_ms = 300\nidle_ms = 150\ntotal_ms = 1000\n", .{server.port});
    try tmp.dir.writeFile(io, .{ .sub_path = "observatory.conf", .data = conf });

    _ = try app.setup(io, a, .{ .data_dir = dir, .auth_dir = dir });
    webbox.host_fetch.provide(.{ .start = linux_fetch.start, .result = linux_fetch.result });
    const was = linux_fetch.on_end;
    defer linux_fetch.on_end = was;
    linux_fetch.on_end = .{ .io = io, .ring = Rung.ring };

    // Three polls a minute apart by the schedule's clock, each waited for
    // by its ring, then the call its end brings.
    const minute: i96 = 60 * std.time.ns_per_s;
    for (0..3) |k| {
        const now: webbox.site.Now = .{ .awake_ns = @as(i96, @intCast(k)) * minute + std.time.ns_per_s, .unix_s = 1_792_228_440 + @as(i64, @intCast(k)) * 60 };
        const before = Rung.count.load(.acquire);
        try testing.expectEqual(webbox.site.Wake{ .at = now.awake_ns + minute }, app.between(io, now));
        var waited: u32 = 0;
        while (Rung.count.load(.acquire) == before and waited < 400) : (waited += 1) {
            Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(5) }, io) catch {};
        }
        try testing.expect(Rung.count.load(.acquire) > before);
        // The end's call: the line, and nothing started before its time.
        _ = app.between(io, .{ .awake_ns = now.awake_ns + 40 * std.time.ns_per_ms, .unix_s = now.unix_s });
    }

    const polls = try tmp.dir.readFileAlloc(io, "polls.txt", a, .limited(64 * 1024));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, polls, "\n"), '\n');
    try testing.expectEqualStrings("2026-10-17T09:14:00Z ok 200 commit abc1234 started 111 accounts 1 turns 0 in 40 ms", lines.next().?);
    try testing.expectEqualStrings("2026-10-17T09:15:00Z ok 200 commit abc1234 started 222 (restarted) accounts 0 turns 0 in 40 ms", lines.next().?);
    try testing.expectEqualStrings("2026-10-17T09:16:00Z idle_deadline in 40 ms", lines.next().?);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());
}
