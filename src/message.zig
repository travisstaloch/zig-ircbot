const std = @import("std");
const warn = std.debug.warn;

pub const CommandType = enum(u8) {
    PASS,
    NICK,
    USER,
    SERVER,
    OPER,
    QUIT,
    SQUIT,
    JOIN,
    PART,
    MODE,
    TOPIC,
    NAMES,
    LIST,
    INVITE,
    KICK,
    VERSION,
    STATS,
    LINKS,
    TIME,
    CONNECT,
    TRACE,
    ADMIN,
    INFO,
    PRIVMSG,
    NOTICE,
    WHO,
    WHOIS,
    WHOWAS,
    KILL,
    PING,
    PONG,
    ERROR,
    AWAY,
    REHASH,
    RESTART,
    SUMMON,
    USERS,
    WALLOPS,
    USERHOST,
    ISON,
};

// <message>  ::= [':' <prefix> <SPACE> ] <command> <params> <crlf>
// <prefix>   ::= <servername> | <nick> [ '!' <user> ] [ '@' <host> ]
// <command>  ::= <letter> { <letter> } | <number> <number> <number>
// <SPACE>    ::= ' ' { ' ' }
// <params>   ::= <SPACE> [ ':' <trailing> | <middle> <params> ]
// <middle>   ::= <Any *non-empty* sequence of octets not including SPACE
//                or NUL or CR or LF, the first of which may not be ':'>
// <trailing> ::= <Any, possibly *empty*, sequence of octets not including
//                  NUL or CR or LF>
// <crlf>     ::= CR LF
pub const Message = struct {
    prefix: ?struct {
        servername: ?[]const u8 = null,
        nick: ?[]const u8 = null,
        user: ?[]const u8 = null,
        host: ?[]const u8 = null,
    } = null,
    command_text: ?[]const u8 = null,
    command: ?CommandType = null,
    params: ?[]const u8 = null,

    pub fn parse(input: []const u8) ?Message {
        if (input.len == 0) return null;
        var m = Message{};
        var len: usize = 0;

        if (input[0] == ':') {
            // parse prefix
            m.prefix = .{};
            len += 1;
            const _prefix = strtok(input[len..], ' ');
            if (_prefix) |prefix| {
                const _nick = strtok(prefix, '!');
                if (_nick) |nick| {
                    m.prefix.?.nick = nick;
                    len += nick.len + 1;
                    const _user = strtok(input[len..], '@');
                    if (_user) |user| {
                        m.prefix.?.user = user;
                        len += user.len + 1;
                        const _host = strtok(input[len..], ' ');
                        if (_host) |host| {
                            m.prefix.?.host = host;
                            len += host.len + 1;
                        }
                    }
                } else {
                    m.prefix.?.servername = prefix;
                    len += prefix.len + 1;
                }
            }
        }
        // parse command, params
        const _command_text = strtok(input[len..], ' ');
        if (_command_text) |command_text| {
            m.command_text = command_text;
            m.command = std.meta.stringToEnum(CommandType, command_text);
            len += command_text.len + 1;
            m.params = input[len..];
            len += m.params.?.len;
        }
        return m;
    }
};

pub fn strtok(_in: []const u8, _delim: ?u8) ?[]const u8 {
    if (_delim == null) return _in;

    var start: []const u8 = undefined;
    var in = _in.ptr;
    const startp = @ptrToInt(in);
    var inp = startp;
    start.ptr = in;
    while (inp < startp + _in.len) : (inp += 1) {
        in = @intToPtr([*]const u8, inp);
        // warn("in[0]{c}\n", .{in[0]});
        if (_delim) |delim| {
            if (in[0] == delim) {
                start.len = inp - @ptrToInt(start.ptr);
                return start;
            }
        }
    }
    return null;
}

pub fn strtoks(_in: []const u8, _delims: []?u8) ?[]const u8 {
    for (_delims) |delim|
        if (strtok(_in, delim)) |res| return res;
    return null;
}

const assert = std.debug.assert;
test "parse PRIVMSG" {
    const _m = Message.parse(":nick!~user@host PRIVMSG #channel :message (could contain the word PRIVMSG)");
    assert(_m != null);
    const m = _m.?;
    assert(std.mem.eql(u8, m.prefix.?.nick.?, "nick"));
    assert(std.mem.eql(u8, m.command_text.?, "PRIVMSG"));
    assert(m.command.? == .PRIVMSG);
    assert(std.mem.eql(u8, m.prefix.?.user.?, "~user"));
    assert(std.mem.eql(u8, m.prefix.?.host.?, "host"));
}

test "strtok" {
    const nick = strtok(":nick!"[1..], '!');
    assert(std.mem.eql(u8, nick.?, "nick"));
}

test "welcome messages" {
    const input =
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
    ;
    var itr = std.mem.separate(input, "\n");
    while (itr.next()) |in| {
        const m = Message.parse(in);
        assert(m != null);
        if (m.?.command != null and m.?.command.? != .PING) {
            assert(m.?.prefix != null);
            assert(m.?.prefix.?.host != null);
        }
        // std.debug.warn("{}, .command_text = {}, .command = {}, .params = {}\n", .{ m.?.prefix, m.?.command_text, m.?.command, m.?.params });
    }
}
