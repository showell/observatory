//! **THE OBSERVATORY, AS A HOST TAKES IT** (webbox's Phase B contract): its
//! `site` and `hosting`. Linux's main (main.zig) and zig-metal-unikernel's
//! kernel both host this.

const std = @import("std");
const webbox = @import("webbox");
const app = @import("app.zig");

pub const site = webbox.site.Site(app);

pub const hosting = struct {
    /// What a host calls it (metal's boot banner).
    pub const name = "the Observatory";
    pub const data_name = "the Observatory's polls";
    /// It reads nothing whole but its conf.
    pub const whole_read_max = 64 * 1024;
    pub const cache_largest_most = 64 * 1024;
    pub fn describeStart(r: app.StartReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const t = r.target;
        try w.print("polling {d}.{d}.{d}.{d}:{d} {s} every {d} s; its lines in {s}/polls.txt\n", .{ t.ip[0], t.ip[1], t.ip[2], t.ip[3], t.port, t.path, r.interval_s, r.data_dir });
    }
};
