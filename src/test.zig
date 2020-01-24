// zig test src/test.zig -lc -lcurl -L/usr/lib/x86_64-linux-gnu -I/usr/include/x86_64-linux-gnu/ -isystem /usr/include/

test "all" {
    _ = @import("api.zig");
    _ = @import("message.zig");
    _ = @import("main.zig");
}
