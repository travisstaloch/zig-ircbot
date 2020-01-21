
### Quick Start
```console
# - create an .env file which exports IRC_OAUTH, IRC_CLIENTID, IRC_NICKNAME,
#   IRC_CHANNEL and optionally API_CONFIG_FILE
# - create a config/api.json (API_CONFIG_FILE) file which defines api endpoints
# - create src/message_handlers.zig to process recevied messages
source .env
zig build run
```

#### config/api.json
```json
{
    "get_users": {
            "type": "Get",
            "url": "https://api.twitch.tv/kraken/users?login=${channel}",
            "headers": [
                "Accept: application/vnd.twitchtv.v5+json",
                "Client-ID: ${clientid}"
            ],
            "cached": {
                "userid": "users[0]._id",
                "name": "users[0].name"
            }
    }
}
```

#### src/main.zig
```zig
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
```

#### src/message_handlers.zig
```zig
pub fn name(ctx: Context, sender: ?[]const u8, text: ?[]const u8, buf: ?[]u8) anyerror!?[]const u8 {
    if (try process_command(ctx, sender, text, "get_users", "name")) |result| {
        return try std.fmt.bufPrint(buf.?, "{}", .{result});
    }
    return null;
}
```

### Reference Projects

C
> https://github.com/andrew-stclair/simple-irc-bot/

Rust
> https://github.com/aatxe/irc

### References
- https://dev.twitch.tv/docs/irc/guide/
- https://tools.ietf.org/html/rfc1459

