const std = @import("std");
const warn = std.debug.warn;
const os = std.os;

pub const c = @cImport({
    @cInclude("time.h");
    @cInclude("curl/curl.h");
});

pub fn get_socket(host: [*:0]const u8, port: [*:0]const u8) !c_int {
    var s: c_int = undefined;
    var hints: os.addrinfo = undefined;
    var res: *os.addrinfo = undefined;
    defer std.c.freeaddrinfo(res);

    const p = @ptrCast([*]u8, &hints);
    std.mem.set(u8, p[0..@sizeOf(os.addrinfo)], 0);

    hints.family = os.AF_UNSPEC;
    hints.socktype = os.SOCK_STREAM;
    hints.flags = std.c.AI_PASSIVE;
    var rc = std.c.getaddrinfo(host, port, &hints, &res);
    if (rc == std.c.EAI.FAIL) {
        warn("getaddrinfo error: {}\n", .{std.c.gai_strerror(rc)});
        return error.GetAddrError;
    }

    s = std.c.socket(@intCast(c_uint, res.family), @intCast(c_uint, res.socktype), @intCast(c_uint, res.protocol));
    if (s < 0) {
        warn("Couldn't get socket.\n", .{});
        return error.SocketError;
    }

    if (std.c.connect(s, res.addr.?, res.addrlen) < 0) {
        warn("Couldn't connect.\n", .{});
        return error.ConnectionError;
    }

    return s;
}

pub fn sck_send(s: c_int, data: [:0]const u8, size: usize) !usize {
    var written: usize = 0;
    while (written < size) {
        const rc = std.c.send(s, data.ptr + written, size - written, 0);
        if (rc <= 0)
            return error.InvalidSend;
        written += @intCast(usize, rc);
    }
    return written;
}

pub fn get_time() [*c]const c.tm {
    var t = c.time(null);
    return c.localtime(&t);
}

pub fn get_time_str(buf: []u8) usize {
    var tm = get_time();
    return c.strftime(@ptrCast([*c]u8, buf.ptr), buf.len, "%m-%y-%d %I:%M:%S", tm);
}

fn curl_write_fn(contents: *c_void, size: usize, nmemb: usize, userp: *align(@alignOf([]u8)) c_void) usize {
    const bytesize = size * nmemb;
    var memp = @ptrCast(*[]u8, userp);
    const contsp = @ptrCast([*]u8, contents);
    // std.debug.warn("contents {}\n", .{contsp[0..bytesize]});
    const mem = memp.*;
    var ptr = std.heap.c_allocator.realloc(mem, mem.len + bytesize) catch |e| {
        std.debug.warn("{}\n", .{e});
        return 0;
    };

    std.mem.copy(u8, ptr[mem.len .. mem.len + bytesize], contsp[0..bytesize]);
    memp.* = ptr;
    return bytesize;
}

pub fn curl_get(url: [:0]const u8, raw_headers: [][]const u8) !std.json.ValueTree {
    // std.debug.warn("curl_get: url {}\n", .{url});
    var res = c.curl_global_init(c.CURL_GLOBAL_ALL);
    var curl = c.curl_easy_init();
    defer {
        c.curl_easy_cleanup(curl);
        c.curl_global_cleanup();
    }

    if (curl == null) {
        return error.FailedInit;
    }
    var headers = @intToPtr([*]allowzero c.curl_slist, 0);
    var mem: []u8 = "";
    for (raw_headers) |rh| {
        var hdr_buf: [256]u8 = undefined;
        const h = try std.fmt.bufPrint(&hdr_buf, "{s}\x00", .{rh});
        headers = c.curl_slist_append(headers, h.ptr);
    }

    _ = c.curl_easy_setopt(curl, c.CURLoption.CURLOPT_URL, url.ptr);
    _ = c.curl_easy_setopt(curl, c.CURLoption.CURLOPT_WRITEFUNCTION, curl_write_fn);
    _ = c.curl_easy_setopt(curl, c.CURLoption.CURLOPT_WRITEDATA, &mem);
    _ = c.curl_easy_setopt(curl, c.CURLoption.CURLOPT_CUSTOMREQUEST, "GET");
    _ = c.curl_easy_setopt(curl, c.CURLoption.CURLOPT_HTTPHEADER, headers);
    // curl_easy_setopt(curl, CURLOPT_POSTFIELDS, "age=42&sex=male");

    res = c.curl_easy_perform(curl);

    // std.debug.warn("{} \n", .{mem.len});
    // std.debug.warn("{} \n", .{mem});
    var parser = std.json.Parser.init(std.heap.c_allocator, false);
    var json = try parser.parse(mem);
    defer {
        parser.deinit();
        // json.deinit();
    }
    return json;
}
