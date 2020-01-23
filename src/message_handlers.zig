const std = @import("std");
const mem = std.mem;
const warn = std.debug.warn;
const c = @import("c.zig");
const irc = @import("client.zig");
const api = @import("api.zig");
const Config = @import("config.zig").Config;

pub const Context = struct {
    config: Config,
    requests: std.StringHashMap(api.Request),
};

pub const Handler = fn (ctx: Context, sender: ?[]const u8, text: ?[]const u8, buf: ?[]u8) anyerror!?[]const u8;

pub fn uptime(ctx: Context, sender: ?[]const u8, text: ?[]const u8, buf: ?[]u8) anyerror!?[]const u8 {
    // TODO: validate buffer is not null
    // var buf = _buf orelse return error.MissingBuffer;
    if (try get_cached("get_stream", "created_at", ctx, sender, text)) |created_at| {
        // TODO: parse time and return difference between now and then
        return try std.fmt.bufPrint(buf.?, "live since {}", .{created_at});
    }
    return "stream is not live"[0..];
}

pub fn bio(ctx: Context, sender: ?[]const u8, text: ?[]const u8, buf: ?[]u8) anyerror!?[]const u8 {
    if (try get_cached("get_users", "bio", ctx, sender, text)) |_bio| {
        return try std.fmt.bufPrint(buf.?, "{}", .{_bio});
    }
    return null;
}

pub fn name(ctx: Context, sender: ?[]const u8, text: ?[]const u8, buf: ?[]u8) anyerror!?[]const u8 {
    if (try get_cached("get_users", "name", ctx, sender, text)) |_name| {
        return try std.fmt.bufPrint(buf.?, "{}", .{_name});
    }
    return null;
}

fn get_cached(req_key: []const u8, cached_key: []const u8, ctx: Context, sender: ?[]const u8, text: ?[]const u8) anyerror!?[]const u8 {
    if (ctx.requests.get(req_key)) |request| {
        try request.value.fetch(ctx.requests);
        // request.value.print();
        const cachedkv = request.value.cached.get(cached_key) orelse return null;
        switch (cachedkv.value.value orelse return null) {
            .String => |s| return s,
            else => return error.UnsupportedJsonType,
        }
    }
    return null;
}
