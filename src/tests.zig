//! Every test: the app's own, and the poll on Linux against local servers.

test {
    _ = @import("app.zig");
    _ = @import("linux_test.zig");
}
