
### Quick Start
```console
# - create an .env file which exports IRC_OAUTH, IRC_CLIENTID, IRC_NICKNAME,
#   IRC_CHANNEL and optionally API_CONFIG_FILE
# - create a config/api.json (API_CONFIG_FILE) file which defines api endpoints
# - create src/message_handlers.zig to process recevied messages
source .env
zig build run
```

### Testing
```console
zig build test
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
     const client = try initClient();
    try client.identify();
    try client.handle();
```


#### src/message_handlers.zig
Functions which match this signature will be called for PRIVMSGs which begin with '!'.
For example, '!name' would call the following handler.
```zig
pub fn name(ctx: Context, sender: ?[]const u8, text: ?[]const u8, buf: ?[]u8) anyerror!?[]const u8 {
    if (try get_cached("get_users", "name", ctx, sender, text)) |_name| {
        return try std.fmt.bufPrint(buf.?, "{}", .{_name});
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

