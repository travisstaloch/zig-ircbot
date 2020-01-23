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
    cached: std.StringHashMap(CachedJValue),
    requires: ?std.StringHashMap(JsonKV),
    fetched_at: ?c.c.tm = null,

    pub const Type = enum(u2) {
        GET,
        PUT,
        POST,
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
                    requirekv.value.value = requestkv.value.cached.get(requirekv.value.key.String).?.value.value;
                }
            }
            try replaceText(std.heap.c_allocator, &self.url, requires);
            for (self.headers) |*hdr| try replaceText(std.heap.c_allocator, hdr, requires);
        }

        // check for ${} macro replacements in url and headers, post data eventually
        switch (self.typ) {
            .GET => {
                var tree = try c.curl_get(self.url, self.headers);
                defer tree.deinit();
                var itr = self.cached.iterator();
                while (itr.next()) |kv| {
                    const path = kv.value.path;
                    const js_val = try parseJsonPath(tree, path);
                    kv.value.value = js_val;
                    switch (js_val) {
                        .Object => self.fetched_at = c.get_time().*,
                        else => {},
                    }
                }
            },
            else => return error.NotImplemented,
        }
    }

    // look through cached, parsing and resolving the path as we go
    // ex: users[0]._id, a.b.c[10].d
    // resolve by visiting json structure
    fn parseJsonPath(tree: std.json.ValueTree, path: []const u8) !std.json.Value {
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
                        return json_value.Object.get(path_part).?.value;
                    }
                },
                else => {
                    return json_value;
                },
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

const assert = std.debug.assert;
test "parseJsonPath" {
    // fn parseJsonPath(self: *Request, tree: std.json.ValueTree, path: []const u8, kv: *std.StringHashMap(CachedJValue).KV) !void {
    var parser = std.json.Parser.init(std.heap.c_allocator, false);
    var tree = try parser.parse("{\"a\": {\"b\": [{\"c\": 42}, {\"d\": 43}]}}");
    const jc = try Request.parseJsonPath(tree, "a.b[0].c");
    // warn("jc {}\n", .{jc});
    assert(jc.Integer == 42);
    const jd = try Request.parseJsonPath(tree, "a.b[1].d");
    assert(jd.Integer == 43);
}

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
            var urlkv = req.Object.get("url") orelse return error.InvalidJsonMissingUrl;
            var url = (try std.mem.dupe(a, u8, urlkv.value.String))[0..:0];
            try replaceText(a, &url, config);

            const headerskv = req.Object.get("headers");
            const headers = if (headerskv) |hkv| (try a.alloc([:0]const u8, headerskv.?.value.Array.len)) else &[_][:0]const u8{};
            if (headerskv) |hs| {
                for (hs.value.Array.toSliceConst()) |hdr, i| {
                    headers[i] = (try std.mem.dupe(a, u8, hdr.String))[0..:0];
                    try replaceText(a, &headers[i], config);
                }
            }

            const _cached = req.Object.get("cached") orelse return error.InvalidJsonMissingCached;
            var cached = _cached.value.Object;
            var cmap = std.StringHashMap(CachedJValue).init(a);
            var citr = cached.iterator();
            while (citr.next()) |ckv| _ = try cmap.put(ckv.key, CachedJValue{ .path = ckv.value.String });

            const requires_opt = req.Object.get("requires");
            var rmap = if (requires_opt) |_requires| blk: {
                const requires = _requires.value.Object;
                var _rmap = std.StringHashMap(JsonKV).init(a);
                var ritr = requires.iterator();
                while (ritr.next()) |rkv| _ = try _rmap.put(rkv.key, .{ .key = rkv.value });
                break :blk _rmap;
            } else null;

            var buf: [20]u8 = undefined;
            const _reqtype = req.Object.get("type") orelse return error.InvalidJsonMissingType;
            var reqtype = _reqtype.?.value.String;
            for (reqtype) |ch, chi| buf[chi] = std.ascii.toUpper(ch);
            reqtype = buf[0..reqtype.len];
            const reqtype_enum = std.meta.stringToEnum(Request.Type, reqtype) orelse return error.InvalidJsonUnsupportedType;

            _ = try reqs.put(kv.key, Request{ .typ = reqtype_enum.?, .url = url, .headers = headers, .cached = cmap, .requires = rmap });
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

fn joinAndCleanup(a: *std.mem.Allocator, text_field: *[]const u8, starti: usize, endi: usize, value: []const u8) !void {
    var ptr = text_field.*;
    text_field.* = try std.mem.join(a, "", &[_][]const u8{
        text_field.*[0..starti],
        value,
        text_field.*[starti + endi + 1 ..],
        "\x00",
    });
    a.free(ptr);
}

pub fn replaceText(a: *std.mem.Allocator, text_field: *[]const u8, provider: var) !void {
    // look for ${field} in strings and replace with Config.field
    // TODO: support replacing multiple occurrences of field
    if (std.mem.indexOf(u8, text_field.*, "${")) |starti| {
        if (std.mem.indexOf(u8, text_field.*[starti..], "}")) |endi| {
            const key = text_field.*[starti + 2 .. starti + endi];
            if (@TypeOf(provider) == Config) {
                inline for (std.meta.fields(@TypeOf(provider))) |field| {
                    if (std.mem.eql(u8, field.name, key)) {
                        if (@field(provider, field.name)) |value| {
                            try joinAndCleanup(a, text_field, starti, endi, value);
                        }
                    }
                }
            } else { // hash map
                var ritr = provider.iterator();
                while (ritr.next()) |requirekv| {
                    if (std.mem.eql(u8, requirekv.value.key.String, key)) {
                        try joinAndCleanup(a, text_field, starti, endi, requirekv.value.value.?.String);
                    }
                }
            }
        }
    }
}
