const std = @import("std");
const warn = std.debug.warn;
const Config = @import("config.zig").Config;
const c = @import("c.zig");
const strtok = @import("message.zig").strtok;

pub const CachedJValue = struct {
    path: []const u8,
    // value: ?[]const u8 = null,
    value: ?std.json.Value = null,
};

// TODO: replace with hash map
pub const JsonKV = struct {
    key: std.json.Value,
    value: ?std.json.Value = null,
};

pub const Request = struct {
    typ: Type,
    url: [:0]const u8,
    headers: [][:0]const u8,
    cached: ?std.StringHashMap(CachedJValue),
    requires: ?std.StringHashMap(JsonKV),
    fetched_at: ?c.c.tm = null,

    pub const Type = enum(u2) {
        Get,
        Put,
        Post,
        Invalid,
    };

    // call fetch on all requires then do macro replacements
    // ex: require                              -> request
    //     get_stream.requires.get_users.userid -> get_users.cached.userid.value
    // TODO: use fetched_at to decide wether to fetch again
    pub fn fetch(self: *Request, requests: std.StringHashMap(Request)) anyerror!void {
        if (self.requires) |*requires| {
            var ritr = requires.iterator();
            while (ritr.next()) |requirekv| {
                if (requests.get(requirekv.key)) |requestkv| {
                    try requestkv.value.fetch(requests);
                    requirekv.value.value = requestkv.value.cached.?.get(requirekv.value.key.String).?.value.value;
                }
            }
            try replaceTextMap(std.heap.c_allocator, &self.url, requires);
            for (self.headers) |*hdr| try replaceTextMap(std.heap.c_allocator, hdr, requires);
        }

        // check for ${} macro replacements in url and headers, post data eventually
        if (self.cached) |*cached| {
            switch (self.typ) {
                .Get => {
                    var tree = try c.curl_get(self.url, self.headers);
                    defer tree.deinit();
                    // look through cached parsing and resolving the path as we go
                    // ex: users[0]._id
                    var itr = cached.iterator();
                    while (itr.next()) |kv| {
                        const target_name = kv.key;
                        const path = kv.value.path;
                        // warn("target_name {} path {}\n", .{ target_name, path });
                        var len: usize = 0;
                        var json_value = tree.root;
                        while (true) {
                            switch (json_value) {
                                .Object => {
                                    if (strtok(path[len..], '.')) |path_part| {
                                        len += path_part.len + 1;
                                        // array
                                        if (strtok(path_part, '[')) |arr_name| {
                                            if (strtok(path_part[arr_name.len + 1 ..], ']')) |arr_idx| {
                                                const idx = try std.fmt.parseInt(usize, arr_idx, 10);
                                                json_value = json_value.Object.get(arr_name).?.value.Array.at(idx);
                                            }
                                        } else { // object
                                            json_value = json_value.Object.get(path_part).?.value;
                                        }
                                    } else {
                                        const path_part = path[len..];
                                        // why does this work??
                                        kv.value.value = json_value.Object.get(path_part).?.value;
                                        // warn("{} {}\n", .{ path, json_value.Object.get(path_part).?.value });
                                        self.fetched_at = c.get_time().*;
                                        break;
                                    }
                                },
                                else => {
                                    kv.value.value = json_value;
                                    break;
                                },
                            }
                        }
                    }
                    // var ncitr = new_cached.iterator();
                    // while (ncitr.next()) |nckv| _ = try cached.put(nckv.key, nckv.value);
                },
                else => return error.NotImplemented,
            }
        }
    }

    fn print(self: Request) void {
        warn("\ntype {} url {} fetched_at {}\nheaders\n", .{ self.typ, self.url, self.fetched_at });
        for (self.headers) |h| warn("  {}\n", .{h});
        if (self.cached) |ts| {
            warn("cached\n", .{});
            var titr = ts.iterator();
            while (titr.next()) |tkv| warn("  {} {}\n", .{ tkv.key, tkv.value });
        }
        if (self.requires) |ps| {
            warn("requires\n", .{});
            var titr = ps.iterator();
            while (titr.next()) |tkv| warn("  {} {}\n", .{ tkv.key, tkv.value });
        }
    }
};

pub const Requests = struct {
    requests: std.StringHashMap(Request),

    /// load from json file which defines the api calls
    pub fn init(a: *std.mem.Allocator, config: Config) !Requests {
        var reqs = std.StringHashMap(Request).init(a);
        const f = try std.fs.File.openRead(config.api_config_file.?);
        defer f.close();
        const stream = &f.inStream().stream;
        var p = std.json.Parser.init(a, false);
        defer p.deinit();
        // @alloc
        var tree = try p.parse(try stream.readAllAlloc(a, 1024 * 1024));
        defer tree.deinit();
        var itr = tree.root.Object.iterator();
        while (itr.next()) |kv| {
            var req = kv.value;
            var url = req.Object.get("url").?.value.String[0..:0];
            try replaceText(a, &url, config);

            const headers = req.Object.get("headers").?.value.Array;
            const hs = try a.alloc([:0]const u8, headers.len);
            for (headers.toSliceConst()) |hdr, i| {
                hs[i] = hdr.String[0..:0];
                try replaceText(a, &hs[i], config);
            }
            const cached_opt = req.Object.get("cached");
            var _tmap = if (cached_opt) |_cached| blk: {
                const cached = _cached.value.Object;
                var tmap = std.StringHashMap(CachedJValue).init(a);
                var t_itr = cached.iterator();
                while (t_itr.next()) |tkv| _ = try tmap.put(tkv.key, CachedJValue{ .path = tkv.value.String });
                break :blk tmap;
            } else null;

            const requires_opt = req.Object.get("requires");
            var _pmap = if (requires_opt) |_requires| blk: {
                const requires = _requires.value.Object;
                var pmap = std.StringHashMap(JsonKV).init(a);
                var p_itr = requires.iterator();
                while (p_itr.next()) |pkv| _ = try pmap.put(pkv.key, .{ .key = pkv.value });
                break :blk pmap;
            } else null;

            var buf: [20]u8 = undefined;
            var typ = req.Object.get("type").?.value.String;
            for (typ) |ch, chi| buf[chi] = std.ascii.toLower(ch);
            typ = buf[0..typ.len];
            const typ_enum = if (std.mem.eql(u8, typ, "get")) Request.Type.Get else if (std.mem.eql(u8, typ, "post")) Request.Type.Post else if (std.mem.eql(u8, typ, "put")) Request.Type.Put else Request.Type.Invalid;

            _ = try reqs.put(kv.key, Request{ .typ = typ_enum, .url = url, .headers = hs, .cached = _tmap, .requires = _pmap });
        }
        return Requests{ .requests = reqs };
    }

    pub fn print(self: Requests) void {
        var itr = self.requests.iterator();
        while (itr.next()) |kv| {
            warn("\n{}", .{kv.key});
            kv.value.print();
        }
    }
};

pub fn replaceText(a: *std.mem.Allocator, text_field: *[]const u8, config: Config) !void {
    // look for ${field} in strings and replace with Config.field
    if (std.mem.indexOf(u8, text_field.*, "${")) |starti| {
        if (std.mem.indexOf(u8, text_field.*[starti..], "}")) |endi| {
            const key = text_field.*[starti + 2 .. starti + endi];
            // warn("found {}\n", .{target});
            inline for (std.meta.fields(@TypeOf(config))) |field| {
                if (std.mem.eql(u8, field.name, key)) {
                    if (@field(config, field.name)) |value| {
                        text_field.* = try std.mem.join(a, "", &[_][]const u8{
                            text_field.*[0..starti],
                            value,
                            text_field.*[starti + endi + 1 ..],
                            "\x00",
                        });
                    }
                }
            }
        }
    }
}

pub fn replaceTextMap(a: *std.mem.Allocator, text_field: *[]const u8, map: var) !void {
    // look for ${field} in strings and replace with map[key]
    if (std.mem.indexOf(u8, text_field.*, "${")) |starti| {
        if (std.mem.indexOf(u8, text_field.*[starti..], "}")) |endi| {
            const key = text_field.*[starti + 2 .. starti + endi];
            // warn("replaceTextMap key {}\n", .{key});
            // TODO: replace with hash map. lookup key in map
            var ritr = map.iterator();
            while (ritr.next()) |requirekv| {
                if (std.mem.eql(u8, requirekv.value.key.String, key)) {
                    const value = requirekv.value.value.?.String;
                    // warn("replaceTextMap value {}\n", .{value});
                    text_field.* = try std.mem.join(a, "", &[_][]const u8{
                        text_field.*[0..starti],
                        value,
                        text_field.*[starti + endi + 1 ..],
                        "\x00",
                    });
                }
            }
        }
    }
}
