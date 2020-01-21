pub const Config = struct {
    server: ?[]const u8 = null,
    port: ?[]const u8 = null,
    channel: ?[]const u8 = null,
    nickname: ?[]const u8 = null,
    password: ?[]const u8 = null,
    clientid: ?[]const u8 = null,
    username: ?[]const u8 = null,
    real_name: ?[]const u8 = null,
    userid: ?[]const u8 = null,
    api_config_file: ?[]const u8 = "config/api.json",
};
