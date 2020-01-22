const std = @import("std");
const mem = std.mem;
const warn = std.debug.warn;
const c = @import("c.zig");
const irc = @import("client.zig");
const api = @import("api.zig");
const Config = @import("config.zig").Config;

pub const Context = struct {
    config: Config,
    requests: api.Requests,
};

pub const Handler = fn (ctx: Context, sender: ?[]const u8, text: ?[]const u8, buf: ?[]u8) anyerror!?[]const u8;

pub fn uptime(ctx: Context, sender: ?[]const u8, text: ?[]const u8, buf: ?[]u8) anyerror!?[]const u8 {
    if (try process_command(ctx, sender, text, "get_stream", "created_at")) |result| {
        // TODO: parse time and return difference between now and then
        return try std.fmt.bufPrint(buf.?, "live since {}", .{result});
    }
    return "stream is not live"[0..];
}

pub fn bio(ctx: Context, sender: ?[]const u8, text: ?[]const u8, buf: ?[]u8) anyerror!?[]const u8 {
    if (try process_command(ctx, sender, text, "get_users", "bio")) |result| {
        return try std.fmt.bufPrint(buf.?, "{}", .{result});
    }
    return null;
}

pub fn name(ctx: Context, sender: ?[]const u8, text: ?[]const u8, buf: ?[]u8) anyerror!?[]const u8 {
    if (try process_command(ctx, sender, text, "get_users", "name")) |result| {
        return try std.fmt.bufPrint(buf.?, "{}", .{result});
    }
    return null;
}

fn process_command(ctx: Context, sender: ?[]const u8, text: ?[]const u8, req_key: []const u8, cached_key: []const u8) anyerror!?[]const u8 {
    if (ctx.requests.requests.get(req_key)) |request| {
        try request.value.fetch(ctx.requests.requests);
        // request.value.print();
        const cached = request.value.cached;
        if (cached.get(cached_key)) |cachedkv| {
            if (cachedkv.value.value) |value| {
                switch (value) {
                    .String => return value.String,
                    else => {},
                }
            }
        }
    }
    return null;
}
