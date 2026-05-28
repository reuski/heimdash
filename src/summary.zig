const std = @import("std");
const Io = std.Io;
const http = std.http;
const format = @import("format.zig");

pub const Adapter = enum {
    sonarr,
    radarr,
    prowlarr,
    jellyfin,
    adguard,
    qbittorrent,
    home_assistant,
};

pub fn requiresCredential(adapter: Adapter) bool {
    return switch (adapter) {
        .adguard => false,
        else => true,
    };
}

pub const Arr = struct {
    version: []const u8,
    queue_count: u64,
};

pub const Prowlarr = struct {
    version: []const u8,
    health_count: u64,
    indexer_count: u64,
};

pub const Jellyfin = struct {
    version: []const u8,
    active_sessions: u64,
};

pub const AdGuard = struct {
    protection_enabled: bool,
    query_count: u64,
    blocked_count: u64,
};

pub const Qbittorrent = struct {
    version: []const u8,
    download_speed: u64,
    upload_speed: u64,
};

pub const HomeAssistant = struct {
    entity_name: []const u8,
    entity_state: []const u8,
    entity_unit: ?[]const u8 = null,
};

pub const UserPassword = struct {
    username: []const u8,
    password: []const u8,
};

pub const Value = union(enum) {
    arr: Arr,
    prowlarr: Prowlarr,
    jellyfin: Jellyfin,
    adguard: AdGuard,
    qbittorrent: Qbittorrent,
    home_assistant: HomeAssistant,

    pub fn write(value: Value, w: *Io.Writer) !void {
        switch (value) {
            .arr => |item| try w.print("queue {d}", .{item.queue_count}),
            .prowlarr => |item| {
                try w.print("indexers {d}", .{item.indexer_count});
                if (item.health_count > 0) try w.print(" // alerts {d}", .{item.health_count});
            },
            .jellyfin => |item| try w.print("streams {d}", .{item.active_sessions}),
            .adguard => |item| if (item.protection_enabled) {
                try w.print("blocked {d} / {d}", .{ item.blocked_count, item.query_count });
            } else {
                try w.writeAll("protection off");
            },
            .qbittorrent => |item| {
                var down_buf: [32]u8 = undefined;
                var up_buf: [32]u8 = undefined;
                try writeRate(w, "↓", format.bytes(&down_buf, item.download_speed));
                try w.writeAll(" ");
                try writeRate(w, "↑", format.bytes(&up_buf, item.upload_speed));
            },
            .home_assistant => |item| {
                try w.print("{s} {s}", .{ item.entity_name, item.entity_state });
                if (item.entity_unit) |unit| try w.print(" {s}", .{unit});
            },
        }
    }
};

const ArrStatusJson = struct {
    version: []const u8,
};

const ArrQueueJson = struct {
    totalCount: u64,
};

const ProwlarrStatusJson = struct {
    version: []const u8,
};

const ProwlarrHealthJson = struct {};
const ProwlarrIndexerJson = struct {};

const JellyfinStatusJson = struct {
    Version: []const u8,
};

const JellyfinSessionJson = struct {
    IsActive: bool = true,
};

const AdGuardStatusJson = struct {
    protection_enabled: bool,
};

const AdGuardStatsJson = struct {
    num_dns_queries: u64,
    num_blocked_filtering: u64,
};

const QbittorrentTransferJson = struct {
    dl_info_speed: u64,
    up_info_speed: u64,
};

const HomeAssistantStatusJson = struct {
    message: []const u8,
};

const HomeAssistantAttributesJson = struct {
    friendly_name: ?[]const u8 = null,
    unit_of_measurement: ?[]const u8 = null,
};

const HomeAssistantEntityJson = struct {
    entity_id: []const u8,
    state: []const u8,
    attributes: HomeAssistantAttributesJson = .{},
};

pub fn adapterForKind(kind: []const u8) ?Adapter {
    if (std.ascii.eqlIgnoreCase(kind, "sonarr")) return .sonarr;
    if (std.ascii.eqlIgnoreCase(kind, "radarr")) return .radarr;
    if (std.ascii.eqlIgnoreCase(kind, "prowlarr")) return .prowlarr;
    if (std.ascii.eqlIgnoreCase(kind, "jellyfin")) return .jellyfin;
    if (std.ascii.eqlIgnoreCase(kind, "adguard")) return .adguard;
    if (std.ascii.eqlIgnoreCase(kind, "qbittorrent")) return .qbittorrent;
    if (std.ascii.eqlIgnoreCase(kind, "home_assistant")) return .home_assistant;
    return null;
}

pub fn systemStatusPath(adapter: Adapter) []const u8 {
    return switch (adapter) {
        .sonarr, .radarr => "/api/v3/system/status",
        .prowlarr => "/api/v1/system/status",
        .jellyfin => "/System/Info",
        .adguard => "/control/status",
        .qbittorrent => "/api/v2/app/version",
        .home_assistant => "/api/",
    };
}

pub fn arrQueueStatusPath(adapter: Adapter) ?[]const u8 {
    return switch (adapter) {
        .sonarr, .radarr => "/api/v3/queue/status",
        else => null,
    };
}

pub fn prowlarrHealthPath() []const u8 {
    return "/api/v1/health";
}

pub fn prowlarrIndexerPath() []const u8 {
    return "/api/v1/indexer";
}

pub fn jellyfinSessionsPath() []const u8 {
    return "/Sessions";
}

pub fn adguardStatsPath() []const u8 {
    return "/control/stats";
}

pub fn qbittorrentTransferPath() []const u8 {
    return "/api/v2/transfer/info";
}

pub fn homeAssistantStatePath(allocator: std.mem.Allocator, entity_id: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("/api/states/");
    try writeUriPathSegment(&aw.writer, entity_id);
    return try aw.toOwnedSlice();
}

pub fn credentialHeaderValue(bytes: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, bytes, " \t\r\n");
    if (value.len == 0) return null;
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return null;
    return value;
}

pub fn userPassword(bytes: []const u8) ?UserPassword {
    const value = credentialHeaderValue(bytes) orelse return null;
    const sep = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    const username = value[0..sep];
    const password = value[sep + 1 ..];
    if (username.len == 0 or password.len == 0) return null;
    return .{ .username = username, .password = password };
}

pub fn basicAuthorizationValue(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const value = credentialHeaderValue(bytes) orelse return error.InvalidCredential;
    if (userPassword(value) == null) return error.InvalidCredential;
    const prefix = "Basic ";
    const encoded_len = std.base64.standard.Encoder.calcSize(value.len);
    const out = try allocator.alloc(u8, prefix.len + encoded_len);
    @memcpy(out[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(out[prefix.len..], value);
    return out;
}

pub fn bearerAuthorizationValue(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const value = credentialHeaderValue(bytes) orelse return error.InvalidCredential;
    return try std.fmt.allocPrint(allocator, "Bearer {s}", .{value});
}

pub fn qbittorrentLoginBody(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const credentials = userPassword(bytes) orelse return error.InvalidCredential;
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("username=");
    try writeFormValue(&aw.writer, credentials.username);
    try aw.writer.writeAll("&password=");
    try writeFormValue(&aw.writer, credentials.password);
    return try aw.toOwnedSlice();
}

pub fn qbittorrentSessionCookie(set_cookie: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, set_cookie, " \t\r\n");
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return null;
    const name = value[0..eq];
    if (!std.mem.eql(u8, name, "SID") and !std.mem.startsWith(u8, name, "QBT_SID")) return null;
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const cookie = value[0..end];
    if (cookie.len <= eq + 1) return null;
    if (std.mem.indexOfAny(u8, cookie, " \t\r\n;") != null) return null;
    return cookie;
}

pub fn isAvailableHttpStatus(status: http.Status) bool {
    return status.class() == .success;
}

pub fn parseArr(allocator: std.mem.Allocator, status_json: []const u8, queue_json: []const u8) !Arr {
    const status = try std.json.parseFromSliceLeaky(ArrStatusJson, allocator, status_json, .{
        .ignore_unknown_fields = true,
    });
    const queue = try std.json.parseFromSliceLeaky(ArrQueueJson, allocator, queue_json, .{
        .ignore_unknown_fields = true,
    });
    if (status.version.len == 0) return error.MissingVersion;
    return .{ .version = try allocator.dupe(u8, status.version), .queue_count = queue.totalCount };
}

pub fn parseProwlarr(
    allocator: std.mem.Allocator,
    status_json: []const u8,
    health_json: []const u8,
    indexer_json: []const u8,
) !Prowlarr {
    const status = try std.json.parseFromSliceLeaky(ProwlarrStatusJson, allocator, status_json, .{
        .ignore_unknown_fields = true,
    });
    const health = try std.json.parseFromSliceLeaky([]const ProwlarrHealthJson, allocator, health_json, .{
        .ignore_unknown_fields = true,
    });
    const indexers = try std.json.parseFromSliceLeaky([]const ProwlarrIndexerJson, allocator, indexer_json, .{
        .ignore_unknown_fields = true,
    });
    if (status.version.len == 0) return error.MissingVersion;
    return .{
        .version = try allocator.dupe(u8, status.version),
        .health_count = health.len,
        .indexer_count = indexers.len,
    };
}

pub fn parseJellyfin(allocator: std.mem.Allocator, status_json: []const u8, sessions_json: []const u8) !Jellyfin {
    const status = try std.json.parseFromSliceLeaky(JellyfinStatusJson, allocator, status_json, .{
        .ignore_unknown_fields = true,
    });
    const sessions = try std.json.parseFromSliceLeaky([]const JellyfinSessionJson, allocator, sessions_json, .{
        .ignore_unknown_fields = true,
    });
    if (status.Version.len == 0) return error.MissingVersion;
    var active_sessions: u64 = 0;
    for (sessions) |session| {
        if (session.IsActive) active_sessions += 1;
    }
    return .{ .version = try allocator.dupe(u8, status.Version), .active_sessions = active_sessions };
}

pub fn parseAdGuard(allocator: std.mem.Allocator, status_json: []const u8, stats_json: []const u8) !AdGuard {
    const status = try std.json.parseFromSliceLeaky(AdGuardStatusJson, allocator, status_json, .{
        .ignore_unknown_fields = true,
    });
    const stats = try std.json.parseFromSliceLeaky(AdGuardStatsJson, allocator, stats_json, .{
        .ignore_unknown_fields = true,
    });
    return .{
        .protection_enabled = status.protection_enabled,
        .query_count = stats.num_dns_queries,
        .blocked_count = stats.num_blocked_filtering,
    };
}

pub fn parseQbittorrent(allocator: std.mem.Allocator, version_text: []const u8, transfer_json: []const u8) !Qbittorrent {
    const version = std.mem.trim(u8, version_text, " \t\r\n");
    if (version.len == 0) return error.MissingVersion;
    const transfer = try std.json.parseFromSliceLeaky(QbittorrentTransferJson, allocator, transfer_json, .{
        .ignore_unknown_fields = true,
    });
    return .{
        .version = try allocator.dupe(u8, version),
        .download_speed = transfer.dl_info_speed,
        .upload_speed = transfer.up_info_speed,
    };
}

pub fn parseHomeAssistant(allocator: std.mem.Allocator, status_json: []const u8, entity_json: []const u8) !HomeAssistant {
    const status = try std.json.parseFromSliceLeaky(HomeAssistantStatusJson, allocator, status_json, .{
        .ignore_unknown_fields = true,
    });
    const entity = try std.json.parseFromSliceLeaky(HomeAssistantEntityJson, allocator, entity_json, .{
        .ignore_unknown_fields = true,
    });
    if (status.message.len == 0) return error.MissingStatus;
    if (entity.entity_id.len == 0) return error.MissingEntity;
    if (entity.state.len == 0) return error.MissingEntityState;
    const name = if (entity.attributes.friendly_name) |friendly_name|
        if (friendly_name.len == 0) entity.entity_id else friendly_name
    else
        entity.entity_id;
    const unit = if (entity.attributes.unit_of_measurement) |value|
        if (value.len == 0) null else try allocator.dupe(u8, value)
    else
        null;
    return .{
        .entity_name = try allocator.dupe(u8, name),
        .entity_state = try allocator.dupe(u8, entity.state),
        .entity_unit = unit,
    };
}

fn writeRate(w: *Io.Writer, arrow: []const u8, speed: []const u8) !void {
    try w.writeAll(arrow);
    try w.writeAll("\u{00A0}");
    if (std.mem.indexOfScalar(u8, speed, ' ')) |idx| {
        try w.writeAll(speed[0..idx]);
        try w.writeAll("\u{00A0}");
        try w.writeAll(speed[idx + 1 ..]);
    } else {
        try w.writeAll(speed);
    }
    try w.writeAll("/s");
}

fn writeFormValue(w: *Io.Writer, value: []const u8) !void {
    for (value) |c| {
        if (c == ' ') {
            try w.writeByte('+');
        } else if (isFormUnreserved(c)) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

fn writeUriPathSegment(w: *Io.Writer, value: []const u8) !void {
    for (value) |c| {
        if (isUriPathSegmentUnreserved(c)) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

fn isFormUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '*' or c == '-' or c == '.' or c == '_';
}

fn isUriPathSegmentUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

test "adapterForKind maps supported kinds only" {
    try std.testing.expectEqual(Adapter.sonarr, adapterForKind("sonarr").?);
    try std.testing.expectEqual(Adapter.radarr, adapterForKind("Radarr").?);
    try std.testing.expectEqual(Adapter.prowlarr, adapterForKind("PROWLARR").?);
    try std.testing.expectEqual(Adapter.jellyfin, adapterForKind("jellyfin").?);
    try std.testing.expectEqual(Adapter.adguard, adapterForKind("ADGUARD").?);
    try std.testing.expectEqual(Adapter.qbittorrent, adapterForKind("qBittorrent").?);
    try std.testing.expectEqual(Adapter.home_assistant, adapterForKind("home_assistant").?);
    try std.testing.expect(adapterForKind("nextcloud") == null);
}

test "requiresCredential is false only for unauthenticated status endpoints" {
    try std.testing.expect(!requiresCredential(.adguard));
    try std.testing.expect(requiresCredential(.sonarr));
    try std.testing.expect(requiresCredential(.qbittorrent));
    try std.testing.expect(requiresCredential(.home_assistant));
}

test "paths follow supported service APIs" {
    try std.testing.expectEqualStrings("/api/v3/system/status", systemStatusPath(.sonarr));
    try std.testing.expectEqualStrings("/api/v3/queue/status", arrQueueStatusPath(.radarr).?);
    try std.testing.expectEqualStrings("/api/v1/system/status", systemStatusPath(.prowlarr));
    try std.testing.expectEqualStrings("/api/v1/health", prowlarrHealthPath());
    try std.testing.expectEqualStrings("/api/v1/indexer", prowlarrIndexerPath());
    try std.testing.expectEqualStrings("/System/Info", systemStatusPath(.jellyfin));
    try std.testing.expectEqualStrings("/Sessions", jellyfinSessionsPath());
    try std.testing.expectEqualStrings("/control/status", systemStatusPath(.adguard));
    try std.testing.expectEqualStrings("/control/stats", adguardStatsPath());
    try std.testing.expectEqualStrings("/api/v2/app/version", systemStatusPath(.qbittorrent));
    try std.testing.expectEqualStrings("/api/v2/transfer/info", qbittorrentTransferPath());
    try std.testing.expectEqualStrings("/api/", systemStatusPath(.home_assistant));

    const state_path = try homeAssistantStatePath(std.testing.allocator, "sensor.kitchen temperature");
    defer std.testing.allocator.free(state_path);
    try std.testing.expectEqualStrings("/api/states/sensor.kitchen%20temperature", state_path);
}

test "credential helpers trim files and reject header-breaking content" {
    try std.testing.expectEqualStrings("secret", credentialHeaderValue(" secret\n").?);
    try std.testing.expect(credentialHeaderValue("\n") == null);
    try std.testing.expect(credentialHeaderValue("one\ntwo") == null);
    const parsed = userPassword(" admin:s3cret\n").?;
    try std.testing.expectEqualStrings("admin", parsed.username);
    try std.testing.expectEqualStrings("s3cret", parsed.password);
    try std.testing.expect(userPassword("admin") == null);
    try std.testing.expect(userPassword(":s3cret") == null);
    try std.testing.expect(userPassword("admin:") == null);
}

test "auth value helpers derive request-only credentials" {
    const basic = try basicAuthorizationValue(std.testing.allocator, "admin:s3cret\n");
    defer {
        @memset(basic, 0);
        std.testing.allocator.free(basic);
    }
    try std.testing.expectEqualStrings("Basic YWRtaW46czNjcmV0", basic);

    const bearer = try bearerAuthorizationValue(std.testing.allocator, " token\n");
    defer {
        @memset(bearer, 0);
        std.testing.allocator.free(bearer);
    }
    try std.testing.expectEqualStrings("Bearer token", bearer);
}

test "qbittorrent login helpers encode form body and session cookie" {
    const body = try qbittorrentLoginBody(std.testing.allocator, "admin:pass word+");
    defer {
        @memset(body, 0);
        std.testing.allocator.free(body);
    }
    try std.testing.expectEqualStrings("username=admin&password=pass+word%2B", body);
    try std.testing.expectEqualStrings("SID=abc123", qbittorrentSessionCookie("SID=abc123; path=/").?);
    try std.testing.expectEqualStrings("QBT_SID_8080=abc123", qbittorrentSessionCookie("QBT_SID_8080=abc123; HttpOnly; path=/").?);
    try std.testing.expect(qbittorrentSessionCookie("session=abc") == null);
    try std.testing.expect(qbittorrentSessionCookie("SID=") == null);
    try std.testing.expect(qbittorrentSessionCookie("QBT_SID_8080=") == null);
}

test "isAvailableHttpStatus rejects auth failures" {
    try std.testing.expect(isAvailableHttpStatus(.ok));
    try std.testing.expect(!isAvailableHttpStatus(.unauthorized));
    try std.testing.expect(!isAvailableHttpStatus(.forbidden));
    try std.testing.expect(!isAvailableHttpStatus(.internal_server_error));
}

test "parseArr reads version and queue count" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseArr(
        arena_state.allocator(),
        "{ \"version\": \"4.0.17.2952\", \"appName\": \"Sonarr\" }",
        "{ \"totalCount\": 3, \"unknown\": true }",
    );
    try std.testing.expectEqualStrings("4.0.17.2952", item.version);
    try std.testing.expectEqual(@as(u64, 3), item.queue_count);
}

test "parseArr rejects missing fields and malformed json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.MissingField, parseArr(
        arena_state.allocator(),
        "{ \"appName\": \"Sonarr\" }",
        "{ \"totalCount\": 3 }",
    ));
    if (parseArr(arena_state.allocator(), "{", "{ \"totalCount\": 3 }")) |_| {
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}

test "parseProwlarr reads version, health count, and indexer count" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseProwlarr(
        arena_state.allocator(),
        "{ \"version\": \"1.33.3.5065\" }",
        "[ { \"source\": \"Indexer\" }, { \"source\": \"Application\" } ]",
        "[ { \"name\": \"one\" }, { \"name\": \"two\" }, { \"name\": \"three\" } ]",
    );
    try std.testing.expectEqualStrings("1.33.3.5065", item.version);
    try std.testing.expectEqual(@as(u64, 2), item.health_count);
    try std.testing.expectEqual(@as(u64, 3), item.indexer_count);
}

test "parseProwlarr rejects missing fields and malformed json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.MissingField, parseProwlarr(
        arena_state.allocator(),
        "{ \"appName\": \"Prowlarr\" }",
        "[]",
        "[]",
    ));
    if (parseProwlarr(arena_state.allocator(), "{ \"version\": \"1\" }", "{", "[]")) |_| {
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}

test "parseJellyfin reads version and active sessions" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseJellyfin(
        arena_state.allocator(),
        "{ \"Version\": \"10.10.7\", \"ServerName\": \"media\" }",
        "[ { \"UserName\": \"one\", \"IsActive\": true }, { \"UserName\": \"two\", \"IsActive\": false }, { \"UserName\": \"three\" } ]",
    );
    try std.testing.expectEqualStrings("10.10.7", item.version);
    try std.testing.expectEqual(@as(u64, 2), item.active_sessions);
}

test "parseJellyfin rejects missing fields and malformed json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.MissingField, parseJellyfin(
        arena_state.allocator(),
        "{ \"ServerName\": \"media\" }",
        "[]",
    ));
    if (parseJellyfin(arena_state.allocator(), "{ \"Version\": \"10\" }", "{")) |_| {
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}

test "parseAdGuard reads protection and query stats" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseAdGuard(
        arena_state.allocator(),
        "{ \"protection_enabled\": true, \"running\": true }",
        "{ \"num_dns_queries\": 1200, \"num_blocked_filtering\": 83 }",
    );
    try std.testing.expect(item.protection_enabled);
    try std.testing.expectEqual(@as(u64, 1200), item.query_count);
    try std.testing.expectEqual(@as(u64, 83), item.blocked_count);
}

test "parseAdGuard rejects missing fields and malformed json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.MissingField, parseAdGuard(
        arena_state.allocator(),
        "{ \"running\": true }",
        "{ \"num_dns_queries\": 1, \"num_blocked_filtering\": 0 }",
    ));
    if (parseAdGuard(arena_state.allocator(), "{ \"protection_enabled\": true }", "{")) |_| {
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}

test "parseQbittorrent reads version and transfer speeds" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseQbittorrent(
        arena_state.allocator(),
        "v5.0.3\n",
        "{ \"dl_info_speed\": 1048576, \"up_info_speed\": 2048, \"connection_status\": \"connected\" }",
    );
    try std.testing.expectEqualStrings("v5.0.3", item.version);
    try std.testing.expectEqual(@as(u64, 1048576), item.download_speed);
    try std.testing.expectEqual(@as(u64, 2048), item.upload_speed);
}

test "parseQbittorrent rejects missing fields and malformed json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.MissingVersion, parseQbittorrent(
        arena_state.allocator(),
        "\n",
        "{ \"dl_info_speed\": 1, \"up_info_speed\": 2 }",
    ));
    if (parseQbittorrent(arena_state.allocator(), "v5", "{")) |_| {
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}

test "parseHomeAssistant reads api status and selected entity" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseHomeAssistant(
        arena_state.allocator(),
        "{ \"message\": \"API running.\" }",
        "{ \"entity_id\": \"sensor.kitchen\", \"state\": \"21.4\", \"attributes\": { \"friendly_name\": \"Kitchen\", \"unit_of_measurement\": \"C\" } }",
    );
    try std.testing.expectEqualStrings("Kitchen", item.entity_name);
    try std.testing.expectEqualStrings("21.4", item.entity_state);
    try std.testing.expectEqualStrings("C", item.entity_unit.?);
}

test "parseHomeAssistant rejects missing fields and malformed json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.MissingField, parseHomeAssistant(
        arena_state.allocator(),
        "{ \"message\": \"API running.\" }",
        "{ \"entity_id\": \"sensor.kitchen\" }",
    ));
    if (parseHomeAssistant(arena_state.allocator(), "{ \"message\": \"API running.\" }", "{")) |_| {
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}

test "Value writes compact summary lines" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try (Value{ .arr = .{ .version = "4.0.17.2952", .queue_count = 3 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("queue 3", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .prowlarr = .{ .version = "1.33.3.5065", .health_count = 2, .indexer_count = 7 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("indexers 7 // alerts 2", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .prowlarr = .{ .version = "1.33.3.5065", .health_count = 0, .indexer_count = 7 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("indexers 7", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .jellyfin = .{ .version = "10.10.7", .active_sessions = 2 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("streams 2", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .adguard = .{ .protection_enabled = true, .query_count = 1200, .blocked_count = 83 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("blocked 83 / 1200", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .adguard = .{ .protection_enabled = false, .query_count = 1200, .blocked_count = 83 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("protection off", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .qbittorrent = .{ .version = "v5.0.3", .download_speed = 1048576, .upload_speed = 2048 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("↓\u{00A0}1.0\u{00A0}MiB/s ↑\u{00A0}2.0\u{00A0}KiB/s", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .home_assistant = .{ .entity_name = "Kitchen", .entity_state = "21.4", .entity_unit = "C" } }).write(&aw.writer);
    try std.testing.expectEqualStrings("Kitchen 21.4 C", aw.written());
}
