//! **WHAT A /version SAYS**, read from its JSON: the commit and when the
//! server started, both of which lynrummy.com's and Dog Park's give, and Dog
//! Park's counts when they are there. Anything else in it is passed by, so a
//! server that adds a field changes nothing here.

const std = @import("std");

pub const Version = struct {
    commit: []const u8,
    started_ms: u64,
    accounts: ?u64 = null,
    turns_held: ?u64 = null,
};

/// The fields, read with `alloc`; null for a body that is not one.
pub fn parse(alloc: std.mem.Allocator, body: []const u8) ?Version {
    const parsed = std.json.parseFromSliceLeaky(Version, alloc, body, .{ .ignore_unknown_fields = true }) catch return null;
    return parsed;
}

const testing = std.testing;

test "Dog Park's /version and lynrummy.com's are read alike; a body that is not one is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dog = parse(a, "{\"result\":\"success\",\"app\":\"dog-park\",\"commit\":\"fb3253d\",\"started_ms\":1789000000000,\"now_ms\":1789000060000,\"accounts\":3,\"accounts_most\":80,\"turns_held\":2,\"turns_most\":5}").?;
    try testing.expectEqualStrings("fb3253d", dog.commit);
    try testing.expectEqual(@as(u64, 1789000000000), dog.started_ms);
    try testing.expectEqual(@as(?u64, 3), dog.accounts);
    try testing.expectEqual(@as(?u64, 2), dog.turns_held);
    const chat = parse(a, "{\"result\":\"success\",\"version\":\"x\",\"commit\":\"12b41e85\",\"rejects\":{},\"mem\":{},\"login_throttle\":{\"refused\":0},\"now_ms\":5,\"started_ms\":4}").?;
    try testing.expectEqualStrings("12b41e85", chat.commit);
    try testing.expectEqual(@as(?u64, null), chat.accounts);
    try testing.expectEqual(@as(?Version, null), parse(a, "<html>hello</html>"));
    try testing.expectEqual(@as(?Version, null), parse(a, "{\"result\":\"success\"}"));
}
