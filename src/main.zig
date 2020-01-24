// zig build-exe -lc -lcurl -L/usr/lib/x86_64-linux-gnu -I/usr/include/x86_64-linux-gnu/ -isystem /usr/include/ src/main.zig  && ./main

const std = @import("std");
const os = std.os;

const irc = @import("client.zig");

fn initClient() !irc.Client {
    return try irc.Client.initFromConfig(.{
        .server = os.getenv("IRC_SERVER") orelse return error.MissingEnv,
        .port = os.getenv("IRC_PORT") orelse return error.MissingEnv,
        .nickname = os.getenv("IRC_NICKNAME") orelse return error.MissingEnv,
        .channel = os.getenv("IRC_CHANNEL") orelse return error.MissingEnv,
        .password = os.getenv("IRC_OAUTH"),
        .clientid = os.getenv("IRC_CLIENTID"),
        .api_config_file = os.getenv("API_CONFIG_FILE"),
    });
}

pub fn main() anyerror!void {
    const client = try initClient();
    try client.identify();
    try client.handle();
}

// zig test src/main.zig -lc -lcurl -L/usr/lib/x86_64-linux-gnu -I/usr/include/x86_64-linux-gnu/ -isystem /usr/include/

test "simple stress test" {
    const client = try initClient();
    defer client.deinit();
    try client.identify();
    const api = @import("api.zig");
    const mhs = @import("message_handlers.zig");
    const reqs = try api.initRequests(std.heap.c_allocator, client.config);
    const welcome =
        \\:tmi.twitch.tv 001 nickname :Welcome, GLHF!
        \\:tmi.twitch.tv 002 nickname :Your host is tmi.twitch.tv
        \\:tmi.twitch.tv 003 nickname :This server is rather new
        \\:tmi.twitch.tv 004 nickname :-
        \\:tmi.twitch.tv 375 nickname :-
        \\:tmi.twitch.tv 372 nickname :You are in a maze of twisty passages, all alike.
        \\:tmi.twitch.tv 376 nickname :>
        \\:nickname!nickname@nickname.tmi.twitch.tv JOIN #channel
        \\:nickname.tmi.twitch.tv 353 nickname = #channel :nickname
        \\:nickname.tmi.twitch.tv 366 nickname #channel :End of /NAMES list
        \\:channel!channel@channel.tmi.twitch.tv PRIVMSG #channel :hello chat
        \\PING :tmi.twitch.tv
        \\:channel!channel@channel.tmi.twitch.tv PRIVMSG #channel :!name
        \\:channel!channel@channel.tmi.twitch.tv PRIVMSG #channel :!logo
        \\:channel!channel@channel.tmi.twitch.tv PRIVMSG #channel :!uptime
    ;
    var ctx = mhs.Context{ .config = client.config, .requests = reqs };
    var i: usize = 0;
    while (i < 100) : (i += 1)
        try client.handleReceived(welcome, ctx);
}
