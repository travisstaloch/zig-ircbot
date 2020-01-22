const std = @import("std");
const warn = std.debug.warn;
const mem = std.mem;
const c = @import("c.zig");
const msg = @import("message.zig");
const api = @import("api.zig");
const Config = @import("config.zig").Config;
const mhs = @import("message_handlers.zig");

pub const Client = struct {
    sock: c_int,
    config: Config,
    message_handlers: std.StringHashMap(mhs.Handler),

    const Self = @This();

    pub fn handle(self: Self) !void {
        var recv_buf: [2048]u8 = undefined;

        const reqs = try api.Requests.init(std.heap.c_allocator, self.config);
        var ctx = mhs.Context{ .config = self.config, .requests = reqs };

        // reqs.print();

        while (true) {
            const len = @intCast(usize, std.c.recv(self.sock, @ptrCast(*c_void, &recv_buf), recv_buf.len - 2, 0));
            if (len == 0) {
                warn("recv error. empty message. exiting. \n", .{});
                break;
            }
            var time_buf: [200]u8 = undefined;
            const time_len = c.get_time_str(time_buf[0..]);
            const received = recv_buf[0..len];
            warn("{}\n", .{time_buf[0..time_len]});
            warn("{}\n", .{received});

            var line_itr = mem.separate(received, "\r\n");
            while (line_itr.next()) |line| {
                if (line.len == 0) continue;
                // warn("line {}\n", .{line});
                const _m = msg.Message.parse(line);
                if (_m) |m| {
                    // warn("{}, .command_text = {}, .command = {}, .params = {}\n", .{ m.prefix, m.command_text, m.command, m.params });
                    if (m.command) |cmd| {
                        switch (cmd) {
                            .PING => _ = try self.sendFmtErr("PONG :{}\r\n", .{m.params}),
                            .PRIVMSG => try self.onPrivMsg(m, ctx),
                            else => warn("unhandled command {}\n", .{cmd}),
                        }
                    }
                } else {
                    warn("failed to parse '{}'\n", .{line});
                }
            }
        }
    }

    fn onPrivMsg(self: Client, m: msg.Message, ctx: mhs.Context) !void {
        if (m.params) |params| {
            const _sender = msg.strtok(params, ':');
            if (_sender) |sender| {
                const message_text = params[sender.len + 1 ..];
                // warn("sender {} text {}\n", .{ sender, message_text });
                if (message_text[0] == '!') {
                    const command_name = msg.strtoks(message_text[1..], &[_]?u8{ ' ', null });
                    if (self.message_handlers.get(command_name.?)) |handlerkv| {
                        var buf: [100]u8 = undefined;
                        if (try handlerkv.value(ctx, sender, message_text[command_name.?.len + 1 ..], &buf)) |handler_output| {
                            _ = try self.privmsg(handler_output[0..:0]);
                        }
                    }
                }
            }
        }
    }

    pub fn initFromConfig(cfg: Config) !Self {
        var map = std.StringHashMap(mhs.Handler).init(std.heap.c_allocator);
        inline for (std.meta.declarations(mhs)) |decl| {
            if (decl.is_pub) {
                switch (decl.data) {
                    .Fn => if (decl.data.Fn.fn_type == mhs.Handler) _ = try map.put(decl.name, @field(mhs, decl.name)),
                    else => {},
                }
            }
        }
        const server = cfg.server.?[0..:0];
        const port = cfg.port.?[0..:0];
        var result = Self{
            .sock = try c.get_socket(server, port),
            .config = cfg,
            .message_handlers = map,
        };
        return result;
    }

    // various send functions with/without format
    // *Err versions propogate errors
    //
    pub fn sendFmt(self: Self, comptime fmt: []const u8, values: var) void {
        _ = self.sendFmtErr(fmt, values) catch |e| warn("send failure. ERROR {}\n", .{e});
    }

    pub fn sendFmtErr(self: Self, comptime fmt: [:0]const u8, values: var) !void {
        _ = try sockSendFmt(self.sock, fmt, values);
    }

    pub fn send(self: Self, text: [:0]const u8) void {
        _ = sockSend(self.sock, text) catch |e| warn("send failure. ERROR {}\n", .{e});
    }

    pub fn sendErr(self: Self, text: [:0]const u8) !void {
        _ = try sockSend(self.sock, text);
    }

    pub fn privmsg(self: Self, text: []const u8) !void {
        _ = try self.sendFmtErr("PRIVMSG #{} :{} \r\n", .{ self.config.channel, text });
    }

    pub fn sockSendFmt(sock: c_int, comptime fmt: [:0]const u8, values: var) !usize {
        var buf: [80]u8 = undefined;
        var m = try std.fmt.bufPrint(&buf, fmt, values);
        var sent = try c.sck_send(sock, m[0..:0], m.len);
        return sent;
    }

    pub fn sockSend(sock: c_int, text: [:0]const u8) !usize {
        var sent = try c.sck_send(sock, text, text.len);
        return sent;
    }

    pub fn identify(self: Self) !void {
        _ = try self.sendFmtErr("CAP END \r\n", .{});
        _ = try self.sendFmtErr("PASS {} \r\n", .{self.config.password});
        _ = try self.sendFmtErr("NICK {} \r\n", .{self.config.nickname});
        _ = try self.sendFmtErr("USER {} * 0 {} \r\n", .{ self.config.username, self.config.real_name });
        _ = try self.sendFmtErr("JOIN #{} \r\n", .{self.config.channel});
    }
};
