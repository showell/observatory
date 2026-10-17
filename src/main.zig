//! The Observatory as a Linux process: webbox's Linux host with the app.
//!
//! Run:  zig build run       (serves its page on http://localhost:9104;
//!                            needs observatory.conf in its data, ./data
//!                            from the checkout, or OBSERVATORY_CONFIG's)

const std = @import("std");
const webbox = @import("webbox");
const hosted = @import("hosted.zig");

pub const site = hosted.site;

pub fn main(init: std.process.Init.Minimal) !void {
    try @import("webbox_linux").linux_host.Server(site).run(init, .{
        .name = "observatory",
        .env = .{
            .port = "OBSERVATORY_PORT",
            .bind = "OBSERVATORY_BIND",
            .config = "OBSERVATORY_CONFIG",
            .trusted_proxy = "OBSERVATORY_TRUSTED_PROXY",
            .keepalive_ms = "OBSERVATORY_KEEPALIVE_MS",
        },
        .default_port = 9104,
        .default_trusted_proxy = "127.0.0.1",
        .default_auth_dir = "~/ObservatoryAuth",
        .routes_hint = "(/: the newest polls)",
        .free_space = unread,
    }, report);
}

/// No floor on the data volume's free space: one small file, appended to.
fn unread(_: *const std.process.Environ.Map) webbox.free_space.FreeSpace {
    return .unknown;
}

fn report(started: *const site.Started) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    hosted.hosting.describeStart(started.app, &w) catch @panic("the Observatory's start report is past its buffer");
    std.debug.print("observatory: {s}", .{w.buffered()});
}
