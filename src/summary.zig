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
    audiobookshelf,
    vaultwarden,
    maintainerr,
    valheim,
    calibre,
};

pub fn requiresCredential(adapter: Adapter) bool {
    return switch (adapter) {
        .adguard, .maintainerr, .valheim => false,
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
    movie_count: u64,
    series_count: u64,
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
    temperature: ?f64 = null,
    temperature_unit: ?[]const u8 = null,
};

pub const Audiobookshelf = struct {
    book_count: u64,
    duration_seconds: u64,
};

pub const AudiobookshelfStats = struct {
    items: u64,
    duration_seconds: u64,
};

pub const Vaultwarden = struct {
    user_count: u64,
};

pub const Maintainerr = struct {
    reclaimable_count: u64,
    reclaimable_bytes: u64,
    handled_count: u64,
};

pub const Valheim = struct {
    online: bool,
    players: u8,
    max_players: u8,
};

pub const Calibre = struct {
    book_count: u64,
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
    audiobookshelf: Audiobookshelf,
    vaultwarden: Vaultwarden,
    maintainerr: Maintainerr,
    valheim: Valheim,
    calibre: Calibre,

    pub fn write(value: Value, w: *Io.Writer) !void {
        switch (value) {
            .arr => |item| try w.print("queue {d}", .{item.queue_count}),
            .prowlarr => |item| {
                try w.print("{d} idx", .{item.indexer_count});
                if (item.health_count > 0) try w.print(" {d}!", .{item.health_count});
            },
            .jellyfin => |item| try w.print("{d} mov {d} tv", .{ item.movie_count, item.series_count }),
            .adguard => |item| if (item.protection_enabled) {
                try w.print("blocked {d}%", .{blockedPercent(item.blocked_count, item.query_count)});
            } else {
                try w.writeAll("protection off");
            },
            .qbittorrent => |item| try format.transferSpeeds(w, item.download_speed, item.upload_speed),
            .home_assistant => |item| if (item.temperature) |temperature| {
                try w.print("{d:.0}", .{temperature});
                if (item.temperature_unit) |unit| try w.writeAll(unit);
                try w.print(" {s}", .{item.entity_state});
            } else {
                try w.print("{s} {s}", .{ item.entity_name, item.entity_state });
                if (item.entity_unit) |unit| try w.print(" {s}", .{unit});
            },
            .audiobookshelf => |item| {
                try w.print("{d} books", .{item.book_count});
                if (item.duration_seconds > 0) try w.print(" {d}h", .{item.duration_seconds / 3600});
            },
            .vaultwarden => |item| try w.print("{d} users", .{item.user_count}),
            .maintainerr => |item| if (item.reclaimable_bytes > 0) {
                var bytes_buf: [32]u8 = undefined;
                try w.print("\u{267B} {s}", .{format.bytes(&bytes_buf, item.reclaimable_bytes)});
            } else {
                try w.print("\u{267B} {d} items", .{item.reclaimable_count});
            },
            .valheim => |item| if (!item.online) {
                try w.writeAll("offline");
            } else if (item.max_players > 0) {
                try w.print("{d}/{d} online", .{ item.players, item.max_players });
            } else {
                try w.print("{d} online", .{item.players});
            },
            .calibre => |item| try w.print("{d} books", .{item.book_count}),
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

const JellyfinCountsJson = struct {
    MovieCount: u64 = 0,
    SeriesCount: u64 = 0,
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

const HomeAssistantAttributesJson = struct {
    friendly_name: ?[]const u8 = null,
    unit_of_measurement: ?[]const u8 = null,
    temperature: ?f64 = null,
    temperature_unit: ?[]const u8 = null,
};

const HomeAssistantEntityJson = struct {
    entity_id: []const u8,
    state: []const u8,
    attributes: HomeAssistantAttributesJson = .{},
};

const AudiobookshelfLibraryJson = struct {
    id: []const u8 = "",
    mediaType: []const u8 = "",
};

const AudiobookshelfLibrariesJson = struct {
    libraries: []const AudiobookshelfLibraryJson = &.{},
};

const AudiobookshelfStatsJson = struct {
    totalItems: u64 = 0,
    totalDuration: f64 = 0,
};

const VaultwardenUserJson = struct {};

const MaintainerrCleanupTotalsJson = struct {
    itemsHandled: u64 = 0,
    moviesHandled: u64 = 0,
    showsHandled: u64 = 0,
    seasonsHandled: u64 = 0,
    episodesHandled: u64 = 0,
};

const MaintainerrCollectionSummaryJson = struct {
    reclaimableCollectionCount: u64 = 0,
    reclaimableMovieCount: u64 = 0,
    reclaimableShowCount: u64 = 0,
    reclaimableSeasonCount: u64 = 0,
    reclaimableEpisodeCount: u64 = 0,
    movieSizeBytes: u64 = 0,
    showSizeBytes: u64 = 0,
    seasonSizeBytes: u64 = 0,
    episodeSizeBytes: u64 = 0,
};

const MaintainerrStorageMetricsJson = struct {
    cleanupTotals: MaintainerrCleanupTotalsJson = .{},
    collectionSummary: MaintainerrCollectionSummaryJson = .{},
};

const ValheimStatusJson = struct {
    online: bool = false,
    players: u8 = 0,
    max_players: u8 = 0,
};

const CalibreStatsJson = struct {
    books: u64 = 0,
};

pub fn adapterForKind(kind: []const u8) ?Adapter {
    if (std.ascii.eqlIgnoreCase(kind, "sonarr")) return .sonarr;
    if (std.ascii.eqlIgnoreCase(kind, "radarr")) return .radarr;
    if (std.ascii.eqlIgnoreCase(kind, "prowlarr")) return .prowlarr;
    if (std.ascii.eqlIgnoreCase(kind, "jellyfin")) return .jellyfin;
    if (std.ascii.eqlIgnoreCase(kind, "adguard")) return .adguard;
    if (std.ascii.eqlIgnoreCase(kind, "qbittorrent")) return .qbittorrent;
    if (std.ascii.eqlIgnoreCase(kind, "home_assistant")) return .home_assistant;
    if (std.ascii.eqlIgnoreCase(kind, "audiobookshelf")) return .audiobookshelf;
    if (std.ascii.eqlIgnoreCase(kind, "vaultwarden")) return .vaultwarden;
    if (std.ascii.eqlIgnoreCase(kind, "maintainerr")) return .maintainerr;
    if (std.ascii.eqlIgnoreCase(kind, "valheim")) return .valheim;
    if (std.ascii.eqlIgnoreCase(kind, "calibre")) return .calibre;
    return null;
}

pub fn systemStatusPath(adapter: Adapter) ?[]const u8 {
    return switch (adapter) {
        .sonarr, .radarr => "/api/v3/system/status",
        .prowlarr => "/api/v1/system/status",
        .jellyfin => "/System/Info",
        .adguard => "/control/status",
        .qbittorrent => "/api/v2/app/version",
        .home_assistant => null,
        .audiobookshelf => "/api/libraries",
        .vaultwarden => "/admin/users",
        .maintainerr => "/api/storage-metrics",
        .valheim => "/status",
        .calibre => "/opds/stats",
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

pub fn jellyfinItemCountsPath() []const u8 {
    return "/Items/Counts";
}

fn blockedPercent(blocked: u64, queries: u64) u64 {
    if (queries == 0) return 0;
    return (blocked * 100 + queries / 2) / queries;
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

pub fn audiobookshelfStatsPath(allocator: std.mem.Allocator, library_id: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("/api/libraries/");
    try writeUriPathSegment(&aw.writer, library_id);
    try aw.writer.writeAll("/stats");
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

pub fn vaultwardenLoginPath() []const u8 {
    return "/admin";
}

pub fn vaultwardenLoginBody(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const token = credentialHeaderValue(bytes) orelse return error.InvalidCredential;
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("token=");
    try writeFormValue(&aw.writer, token);
    return try aw.toOwnedSlice();
}

pub fn vaultwardenSessionCookie(set_cookie: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, set_cookie, " \t\r\n");
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return null;
    if (!std.mem.eql(u8, value[0..eq], "VW_ADMIN")) return null;
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

pub fn parseJellyfin(allocator: std.mem.Allocator, status_json: []const u8, counts_json: []const u8) !Jellyfin {
    const status = try std.json.parseFromSliceLeaky(JellyfinStatusJson, allocator, status_json, .{
        .ignore_unknown_fields = true,
    });
    const counts = try std.json.parseFromSliceLeaky(JellyfinCountsJson, allocator, counts_json, .{
        .ignore_unknown_fields = true,
    });
    if (status.Version.len == 0) return error.MissingVersion;
    return .{
        .version = try allocator.dupe(u8, status.Version),
        .movie_count = counts.MovieCount,
        .series_count = counts.SeriesCount,
    };
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

pub fn parseHomeAssistant(allocator: std.mem.Allocator, entity_json: []const u8) !HomeAssistant {
    const entity = try std.json.parseFromSliceLeaky(HomeAssistantEntityJson, allocator, entity_json, .{
        .ignore_unknown_fields = true,
    });
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
    const temperature_unit = if (entity.attributes.temperature_unit) |value|
        if (value.len == 0) null else try allocator.dupe(u8, value)
    else
        null;
    return .{
        .entity_name = try allocator.dupe(u8, name),
        .entity_state = try allocator.dupe(u8, entity.state),
        .entity_unit = unit,
        .temperature = entity.attributes.temperature,
        .temperature_unit = temperature_unit,
    };
}

pub fn parseAudiobookshelfBookLibraries(allocator: std.mem.Allocator, libraries_json: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSliceLeaky(AudiobookshelfLibrariesJson, allocator, libraries_json, .{
        .ignore_unknown_fields = true,
    });
    var count: usize = 0;
    for (parsed.libraries) |library| {
        if (std.mem.eql(u8, library.mediaType, "book")) count += 1;
    }
    const ids = try allocator.alloc([]const u8, count);
    var i: usize = 0;
    for (parsed.libraries) |library| {
        if (!std.mem.eql(u8, library.mediaType, "book")) continue;
        if (library.id.len == 0) return error.MissingLibraryId;
        ids[i] = try allocator.dupe(u8, library.id);
        i += 1;
    }
    return ids[0..i];
}

pub fn parseAudiobookshelfStats(allocator: std.mem.Allocator, stats_json: []const u8) !AudiobookshelfStats {
    const stats = try std.json.parseFromSliceLeaky(AudiobookshelfStatsJson, allocator, stats_json, .{
        .ignore_unknown_fields = true,
    });
    const duration_seconds: u64 = if (stats.totalDuration > 0) @intFromFloat(stats.totalDuration) else 0;
    return .{ .items = stats.totalItems, .duration_seconds = duration_seconds };
}

pub fn parseVaultwarden(allocator: std.mem.Allocator, users_json: []const u8) !Vaultwarden {
    const users = try std.json.parseFromSliceLeaky([]const VaultwardenUserJson, allocator, users_json, .{
        .ignore_unknown_fields = true,
    });
    return .{ .user_count = users.len };
}

pub fn parseMaintainerr(allocator: std.mem.Allocator, metrics_json: []const u8) !Maintainerr {
    const metrics = try std.json.parseFromSliceLeaky(MaintainerrStorageMetricsJson, allocator, metrics_json, .{
        .ignore_unknown_fields = true,
    });
    const summary = metrics.collectionSummary;
    const totals = metrics.cleanupTotals;
    const reclaimable_type_count =
        summary.reclaimableMovieCount + summary.reclaimableShowCount + summary.reclaimableSeasonCount + summary.reclaimableEpisodeCount;
    return .{
        .reclaimable_count = if (summary.reclaimableCollectionCount > 0) summary.reclaimableCollectionCount else reclaimable_type_count,
        .reclaimable_bytes = summary.movieSizeBytes + summary.showSizeBytes + summary.seasonSizeBytes + summary.episodeSizeBytes,
        .handled_count = if (totals.itemsHandled > 0) totals.itemsHandled else totals.moviesHandled + totals.showsHandled + totals.seasonsHandled + totals.episodesHandled,
    };
}

pub fn parseValheim(allocator: std.mem.Allocator, status_json: []const u8) !Valheim {
    const status = try std.json.parseFromSliceLeaky(ValheimStatusJson, allocator, status_json, .{
        .ignore_unknown_fields = true,
    });
    return .{ .online = status.online, .players = status.players, .max_players = status.max_players };
}

pub fn parseCalibre(allocator: std.mem.Allocator, stats_json: []const u8) !Calibre {
    const stats = try std.json.parseFromSliceLeaky(CalibreStatsJson, allocator, stats_json, .{
        .ignore_unknown_fields = true,
    });
    return .{ .book_count = stats.books };
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
    try std.testing.expectEqual(Adapter.audiobookshelf, adapterForKind("Audiobookshelf").?);
    try std.testing.expectEqual(Adapter.vaultwarden, adapterForKind("Vaultwarden").?);
    try std.testing.expectEqual(Adapter.maintainerr, adapterForKind("Maintainerr").?);
    try std.testing.expectEqual(Adapter.valheim, adapterForKind("Valheim").?);
    try std.testing.expectEqual(Adapter.calibre, adapterForKind("calibre").?);
    try std.testing.expect(adapterForKind("nextcloud") == null);
}

test "requiresCredential is false only for unauthenticated summary endpoints" {
    try std.testing.expect(!requiresCredential(.adguard));
    try std.testing.expect(!requiresCredential(.maintainerr));
    try std.testing.expect(!requiresCredential(.valheim));
    try std.testing.expect(requiresCredential(.calibre));
    try std.testing.expect(requiresCredential(.sonarr));
    try std.testing.expect(requiresCredential(.qbittorrent));
    try std.testing.expect(requiresCredential(.home_assistant));
    try std.testing.expect(requiresCredential(.vaultwarden));
}

test "paths follow supported service APIs" {
    try std.testing.expectEqualStrings("/api/v3/system/status", systemStatusPath(.sonarr).?);
    try std.testing.expectEqualStrings("/api/v3/queue/status", arrQueueStatusPath(.radarr).?);
    try std.testing.expectEqualStrings("/api/v1/system/status", systemStatusPath(.prowlarr).?);
    try std.testing.expectEqualStrings("/api/v1/health", prowlarrHealthPath());
    try std.testing.expectEqualStrings("/api/v1/indexer", prowlarrIndexerPath());
    try std.testing.expectEqualStrings("/System/Info", systemStatusPath(.jellyfin).?);
    try std.testing.expectEqualStrings("/Items/Counts", jellyfinItemCountsPath());
    try std.testing.expectEqualStrings("/control/status", systemStatusPath(.adguard).?);
    try std.testing.expectEqualStrings("/control/stats", adguardStatsPath());
    try std.testing.expectEqualStrings("/api/v2/app/version", systemStatusPath(.qbittorrent).?);
    try std.testing.expectEqualStrings("/api/v2/transfer/info", qbittorrentTransferPath());
    try std.testing.expect(systemStatusPath(.home_assistant) == null);

    const state_path = try homeAssistantStatePath(std.testing.allocator, "sensor.kitchen temperature");
    defer std.testing.allocator.free(state_path);
    try std.testing.expectEqualStrings("/api/states/sensor.kitchen%20temperature", state_path);

    try std.testing.expectEqualStrings("/api/libraries", systemStatusPath(.audiobookshelf).?);
    const stats_path = try audiobookshelfStatsPath(std.testing.allocator, "lib_c1u6t4p45c35rf0nzd");
    defer std.testing.allocator.free(stats_path);
    try std.testing.expectEqualStrings("/api/libraries/lib_c1u6t4p45c35rf0nzd/stats", stats_path);

    try std.testing.expectEqualStrings("/admin/users", systemStatusPath(.vaultwarden).?);
    try std.testing.expectEqualStrings("/admin", vaultwardenLoginPath());
    try std.testing.expectEqualStrings("/api/storage-metrics", systemStatusPath(.maintainerr).?);
    try std.testing.expectEqualStrings("/status", systemStatusPath(.valheim).?);
    try std.testing.expectEqualStrings("/opds/stats", systemStatusPath(.calibre).?);
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

test "vaultwarden login helpers encode token form and admin cookie" {
    const body = try vaultwardenLoginBody(std.testing.allocator, " s3cret token+\n");
    defer {
        @memset(body, 0);
        std.testing.allocator.free(body);
    }
    try std.testing.expectEqualStrings("token=s3cret+token%2B", body);
    try std.testing.expectEqualStrings("VW_ADMIN=abc.def.ghi", vaultwardenSessionCookie("VW_ADMIN=abc.def.ghi; Path=/; HttpOnly").?);
    try std.testing.expect(vaultwardenSessionCookie("session=abc") == null);
    try std.testing.expect(vaultwardenSessionCookie("VW_ADMIN=") == null);
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

test "parseJellyfin reads version and library counts" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseJellyfin(
        arena_state.allocator(),
        "{ \"Version\": \"10.10.7\", \"ServerName\": \"media\" }",
        "{ \"MovieCount\": 320, \"SeriesCount\": 45, \"EpisodeCount\": 1280 }",
    );
    try std.testing.expectEqualStrings("10.10.7", item.version);
    try std.testing.expectEqual(@as(u64, 320), item.movie_count);
    try std.testing.expectEqual(@as(u64, 45), item.series_count);
}

test "parseJellyfin rejects missing fields and malformed json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.MissingField, parseJellyfin(
        arena_state.allocator(),
        "{ \"ServerName\": \"media\" }",
        "{ \"MovieCount\": 320, \"SeriesCount\": 45 }",
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

test "parseHomeAssistant reads selected entity" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseHomeAssistant(
        arena_state.allocator(),
        "{ \"entity_id\": \"sensor.kitchen\", \"state\": \"21.4\", \"attributes\": { \"friendly_name\": \"Kitchen\", \"unit_of_measurement\": \"C\" } }",
    );
    try std.testing.expectEqualStrings("Kitchen", item.entity_name);
    try std.testing.expectEqualStrings("21.4", item.entity_state);
    try std.testing.expectEqualStrings("C", item.entity_unit.?);
    try std.testing.expect(item.temperature == null);
}

test "parseHomeAssistant reads weather temperature and condition" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseHomeAssistant(
        arena_state.allocator(),
        "{ \"entity_id\": \"weather.forecast_home\", \"state\": \"cloudy\", \"attributes\": { \"friendly_name\": \"Forecast Home\", \"temperature\": 11.6, \"temperature_unit\": \"\u{00B0}C\" } }",
    );
    try std.testing.expectEqualStrings("cloudy", item.entity_state);
    try std.testing.expectEqual(@as(f64, 11.6), item.temperature.?);
    try std.testing.expectEqualStrings("\u{00B0}C", item.temperature_unit.?);
}

test "parseHomeAssistant rejects missing fields and malformed json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectError(error.MissingField, parseHomeAssistant(
        arena_state.allocator(),
        "{ \"entity_id\": \"sensor.kitchen\" }",
    ));
    if (parseHomeAssistant(arena_state.allocator(), "{")) |_| {
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}

test "parseAudiobookshelfBookLibraries selects book libraries only" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const ids = try parseAudiobookshelfBookLibraries(
        arena_state.allocator(),
        "{ \"libraries\": [ { \"id\": \"lib_a\", \"mediaType\": \"book\" }, { \"id\": \"lib_b\", \"mediaType\": \"podcast\" }, { \"id\": \"lib_c\", \"mediaType\": \"book\" } ] }",
    );
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("lib_a", ids[0]);
    try std.testing.expectEqualStrings("lib_c", ids[1]);
}

test "parseAudiobookshelfBookLibraries tolerates empty library list and malformed json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const ids = try parseAudiobookshelfBookLibraries(arena_state.allocator(), "{ \"libraries\": [] }");
    try std.testing.expectEqual(@as(usize, 0), ids.len);
    if (parseAudiobookshelfBookLibraries(arena_state.allocator(), "{")) |_| {
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}

test "parseAudiobookshelfStats reads item count and duration seconds" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const stats = try parseAudiobookshelfStats(
        arena_state.allocator(),
        "{ \"totalItems\": 42, \"totalAuthors\": 30, \"totalDuration\": 12000.946, \"totalSize\": 268990279 }",
    );
    try std.testing.expectEqual(@as(u64, 42), stats.items);
    try std.testing.expectEqual(@as(u64, 12000), stats.duration_seconds);
}

test "parseVaultwarden counts the admin user list" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseVaultwarden(
        arena_state.allocator(),
        "[ { \"Email\": \"a@example.com\" }, { \"Email\": \"b@example.com\" }, { \"Email\": \"c@example.com\" } ]",
    );
    try std.testing.expectEqual(@as(u64, 3), item.user_count);

    const empty = try parseVaultwarden(arena_state.allocator(), "[]");
    try std.testing.expectEqual(@as(u64, 0), empty.user_count);
    if (parseVaultwarden(arena_state.allocator(), "{")) |_| {
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}

test "parseMaintainerr reads storage metrics" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseMaintainerr(
        arena_state.allocator(),
        "{ \"cleanupTotals\": { \"itemsHandled\": 12 }, \"collectionSummary\": { \"reclaimableMovieCount\": 2, \"reclaimableShowCount\": 1, \"movieSizeBytes\": 1073741824, \"showSizeBytes\": 2147483648 } }",
    );
    try std.testing.expectEqual(@as(u64, 3), item.reclaimable_count);
    try std.testing.expectEqual(@as(u64, 3221225472), item.reclaimable_bytes);
    try std.testing.expectEqual(@as(u64, 12), item.handled_count);

    const empty = try parseMaintainerr(arena_state.allocator(), "{}");
    try std.testing.expectEqual(@as(u64, 0), empty.reclaimable_count);
    try std.testing.expectEqual(@as(u64, 0), empty.reclaimable_bytes);
    try std.testing.expectEqual(@as(u64, 0), empty.handled_count);
    if (parseMaintainerr(arena_state.allocator(), "{")) |_| {
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}

test "parseValheim reads online state and player counts" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseValheim(
        arena_state.allocator(),
        "{ \"name\": \"Lintukoto\", \"online\": true, \"players\": 2, \"max_players\": 10, \"map\": \"Lintukoto\" }",
    );
    try std.testing.expect(item.online);
    try std.testing.expectEqual(@as(u8, 2), item.players);
    try std.testing.expectEqual(@as(u8, 10), item.max_players);

    const offline = try parseValheim(arena_state.allocator(), "{ \"online\": false }");
    try std.testing.expect(!offline.online);
    if (parseValheim(arena_state.allocator(), "{")) |_| {
        return error.ExpectedMalformedJsonFailure;
    } else |_| {}
}

test "parseCalibre reads book count" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const item = try parseCalibre(
        arena_state.allocator(),
        "{ \"books\": 128, \"authors\": 73, \"categories\": 12, \"series\": 9 }",
    );
    try std.testing.expectEqual(@as(u64, 128), item.book_count);

    const empty = try parseCalibre(arena_state.allocator(), "{}");
    try std.testing.expectEqual(@as(u64, 0), empty.book_count);
    if (parseCalibre(arena_state.allocator(), "{")) |_| {
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
    try std.testing.expectEqualStrings("7 idx 2!", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .prowlarr = .{ .version = "1.33.3.5065", .health_count = 0, .indexer_count = 7 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("7 idx", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .jellyfin = .{ .version = "10.10.7", .movie_count = 320, .series_count = 45 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("320 mov 45 tv", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .adguard = .{ .protection_enabled = true, .query_count = 1200, .blocked_count = 83 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("blocked 7%", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .adguard = .{ .protection_enabled = false, .query_count = 1200, .blocked_count = 83 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("protection off", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .qbittorrent = .{ .version = "v5.0.3", .download_speed = 1048576, .upload_speed = 2048 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("\u{25BC} 1.0M/s \u{25B2} 2.0K/s", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .home_assistant = .{ .entity_name = "Kitchen", .entity_state = "21.4", .entity_unit = "C" } }).write(&aw.writer);
    try std.testing.expectEqualStrings("Kitchen 21.4 C", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .home_assistant = .{ .entity_name = "Forecast Home", .entity_state = "cloudy", .temperature = 11.6, .temperature_unit = "\u{00B0}C" } }).write(&aw.writer);
    try std.testing.expectEqualStrings("12\u{00B0}C cloudy", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .audiobookshelf = .{ .book_count = 42, .duration_seconds = 12000 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("42 books 3h", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .audiobookshelf = .{ .book_count = 0, .duration_seconds = 0 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("0 books", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .vaultwarden = .{ .user_count = 3 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("3 users", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .maintainerr = .{ .reclaimable_count = 3, .reclaimable_bytes = 3221225472, .handled_count = 12 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("\u{267B} 3.0 GiB", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .maintainerr = .{ .reclaimable_count = 5, .reclaimable_bytes = 0, .handled_count = 0 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("\u{267B} 5 items", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .valheim = .{ .online = true, .players = 2, .max_players = 10 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("2/10 online", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .valheim = .{ .online = true, .players = 0, .max_players = 0 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("0 online", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .valheim = .{ .online = false, .players = 0, .max_players = 0 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("offline", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .calibre = .{ .book_count = 128 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("128 books", aw.written());
}
