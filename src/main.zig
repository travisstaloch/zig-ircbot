// zig build-exe -lc -lcurl -L/usr/lib/x86_64-linux-gnu -I/usr/include/x86_64-linux-gnu/ -isystem /usr/include/ src/main.zig  && ./main

const std = @import("std");
const os = std.os;

const irc = @import("client.zig");
// const handlers = @import("message_handlers.zig");

pub fn main() anyerror!void {
    const client = try irc.Client.initFromConfig(.{
        .server = os.getenv("IRC_SERVER"),
        .port = os.getenv("IRC_PORT"),
        .nickname = os.getenv("IRC_NICKNAME"),
        .channel = os.getenv("IRC_CHANNEL"),
        .password = os.getenv("IRC_OAUTH"),
        .clientid = os.getenv("IRC_CLIENTID"),
        .api_config_file = os.getenv("API_CONFIG_FILE"),
    });
    try client.identify();
    try client.handle();
}
