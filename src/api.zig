const std = @import("std");
const warn = std.debug.warn;
const Config = @import("config.zig").Config;
const c = @import("c.zig");
const msg = @import("message.zig");
const strtok = msg.strtok;

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
    type: Type,
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

    pub fn deinit(self: Request) void {
        if (self.requires) |rqs| rqs.deinit();
        self.cached.deinit();
    }

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
                    const cachedkv = requestkv.value.cached.get(requirekv.value.key.String) orelse return error.JsonRequireNotCached;
                    // warn("cachedkv {}\n", .{cachedkv});
                    requirekv.value.value = cachedkv.value.value;
                }
            }

            // check for ${} macro replacements in url and headers
            // TODO: post data replacements
            try replaceText(std.heap.c_allocator, &self.url, requires);
            for (self.headers) |*hdr| try replaceText(std.heap.c_allocator, hdr, requires);
        }

        switch (self.type) {
            .GET => {
                var tree = try c.curl_get(self.url, self.headers);
                // warn("{}\n", .{tree.root.dump()});
                defer tree.deinit();
                var itr = self.cached.iterator();
                while (itr.next()) |kv| {
                    const path = kv.value.path;
                    const js_val = parseJsonPath(tree, path) catch |e| {
                        warn("request '{}' unable to parse json path '{}'.  Error: {}\n", .{ self.url, path, e });
                        continue;
                    };
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
                .Object => if (msg.strtoks(path[len..], &[_]?u8{ '.', null })) |path_part| {
                    len += path_part.len + 1;
                    // array
                    if (strtok(path_part, '[')) |arr_name| {
                        if (strtok(path_part[arr_name.len + 1 ..], ']')) |arr_idx| {
                            const idx = try std.fmt.parseInt(usize, arr_idx, 10);
                            const obj = json_value.Object.get(arr_name) orelse return error.JsonPathNotFound;
                            switch (obj.value) {
                                .Array => {
                                    if (idx >= obj.value.Array.len) return error.InvalidJsonArrayIndex;
                                    json_value = obj.value.Array.at(idx);
                                    continue;
                                },
                                else => return error.JsonPathNotFound,
                            }
                        }
                    } else { // object
                        const obj = json_value.Object.get(path_part) orelse return error.JsonPathNotFound;
                        json_value = obj.value;
                    }
                } else {
                    const obj = json_value.Object.get(path[len..]) orelse return error.JsonPathNotFound;
                    return obj.value;
                },
                else => return json_value,
            }
        }
    }

    fn print(self: Request) void {
        warn("\ntype {} url {} fetched_at {}\nheaders\n", .{ self.type, self.url, self.fetched_at });
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

test "parseJsonPath" {
    const assert = std.debug.assert;
    // fn parseJsonPath(self: *Request, tree: std.json.ValueTree, path: []const u8, kv: *std.StringHashMap(CachedJValue).KV) !void {
    var parser = std.json.Parser.init(std.heap.c_allocator, false);
    const json =
        \\ {"a": {"b": [{"c": 42}, {"d": 43}]}, "a2": [0, 11, 22]}
    ;
    var tree = try parser.parse(json);
    const jc = try Request.parseJsonPath(tree, "a.b[0].c");
    // warn("jc {}\n", .{jc});
    assert(jc.Integer == 42);
    const jd = try Request.parseJsonPath(tree, "a.b[1].d");
    assert(jd.Integer == 43);
    std.testing.expectError(error.JsonPathNotFound, Request.parseJsonPath(tree, "a.c"));
    std.testing.expectError(error.InvalidJsonArrayIndex, Request.parseJsonPath(tree, "a.b[2]"));
    const ja22 = try Request.parseJsonPath(tree, "a2[2]");
    assert(ja22.Integer == 22);
}

/// load from json file which defines the api calls
pub fn initRequests(a: *std.mem.Allocator, config: Config) !std.StringHashMap(Request) {
    var reqs = std.StringHashMap(Request).init(a);
    errdefer reqs.deinit();
    const f = try std.fs.File.openRead(config.api_config_file orelse return error.MissingApiConfigFile);
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
        const headers = if (headerskv) |hkv| (try a.alloc([:0]const u8, hkv.value.Array.len)) else &[_][:0]const u8{};
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
        var reqtype = _reqtype.value.String;
        for (reqtype) |ch, chi| buf[chi] = std.ascii.toUpper(ch);
        reqtype = buf[0..reqtype.len];
        const reqtype_enum = std.meta.stringToEnum(Request.Type, reqtype) orelse return error.InvalidJsonUnsupportedType;

        _ = try reqs.put(kv.key, Request{ .type = reqtype_enum, .url = url, .headers = headers, .cached = cmap, .requires = rmap });
    }
    return reqs;
}

pub fn printRequests(reqs: std.StringHashMap(Request)) void {
    var itr = reqs.iterator();
    while (itr.next()) |kv| {
        warn("\n{}", .{kv.key});
        kv.value.print();
    }
}

// insert value at text_field[starti..endi+1]
// reassigns text_field and frees old memory
fn insertText(a: *std.mem.Allocator, text_field: *[]const u8, starti: usize, endi: usize, value: []const u8) !void {
    var ptr = text_field.*;
    text_field.* = try std.mem.join(a, "", &[_][]const u8{
        text_field.*[0..starti],
        value,
        text_field.*[starti + endi + 1 ..],
        // "\x00",
    });
    a.free(ptr);
}

/// provider must be either a Config or StringHashMap()
pub fn replaceText(a: *std.mem.Allocator, text_field: *[]const u8, provider: var) !void {
    // look for ${field} in strings and replace with Config.field or
    // if called with a map, search provider for JsonKV.key == field and replace with JsonKV.value
    // TODO: support replacing multiple occurrences of field
    if (std.mem.indexOf(u8, text_field.*, "${")) |starti| {
        // warn("text_field.* {}\n", .{text_field.*});
        if (std.mem.indexOf(u8, text_field.*[starti..], "}")) |endi| {
            const key = text_field.*[starti + 2 .. starti + endi];
            if (@TypeOf(provider) == Config) {
                inline for (std.meta.fields(@TypeOf(provider))) |field| {
                    if (std.mem.eql(u8, field.name, key)) {
                        const _value = @field(provider, field.name);
                        // support optional Config fields
                        const ti = @typeInfo(@TypeOf(_value));
                        switch (ti) {
                            .Optional => if (_value) |value|
                                try insertText(a, text_field, starti, endi, value),
                            else => try insertText(a, text_field, starti, endi, _value),
                        }
                    }
                }
            } else { // hash map
                var ritr = provider.iterator();
                while (ritr.next()) |requirekv| {
                    if (!std.mem.eql(u8, requirekv.value.key.String, key)) continue;
                    const value = requirekv.value.value orelse continue;
                    try insertText(a, text_field, starti, endi, value.String);
                }
            }
        }
    }
}

test "replaceText" {
    const a = std.heap.c_allocator;
    var field = try std.mem.dupe(a, u8, "a ${channel} b");
    const config = Config{ .channel = "#channel_name", .server = "", .port = "", .nickname = "" };
    try replaceText(a, &field, config);
    const expected = "a #channel_name b";
    std.testing.expectEqualSlices(u8, field, expected);
}
