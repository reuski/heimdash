const std = @import("std");
const Io = std.Io;
const http = std.http;

pub const Adapter = enum {
    sonarr,
    radarr,
    prowlarr,
};

pub const Arr = struct {
    version: []const u8,
    queue_count: u64,
};

pub const Prowlarr = struct {
    version: []const u8,
    health_count: u64,
    indexer_count: u64,
};

pub const Value = union(enum) {
    unavailable,
    arr: Arr,
    prowlarr: Prowlarr,

    pub fn write(value: Value, w: *Io.Writer) !void {
        switch (value) {
            .unavailable => {},
            .arr => |item| try w.print("v{s} | queue {d}", .{ item.version, item.queue_count }),
            .prowlarr => |item| try w.print(
                "v{s} | indexers {d} | health {d}",
                .{ item.version, item.indexer_count, item.health_count },
            ),
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

pub fn adapterForKind(kind: []const u8) ?Adapter {
    if (std.ascii.eqlIgnoreCase(kind, "sonarr")) return .sonarr;
    if (std.ascii.eqlIgnoreCase(kind, "radarr")) return .radarr;
    if (std.ascii.eqlIgnoreCase(kind, "prowlarr")) return .prowlarr;
    return null;
}

pub fn systemStatusPath(adapter: Adapter) []const u8 {
    return switch (adapter) {
        .sonarr, .radarr => "/api/v3/system/status",
        .prowlarr => "/api/v1/system/status",
    };
}

pub fn arrQueueStatusPath(adapter: Adapter) ?[]const u8 {
    return switch (adapter) {
        .sonarr, .radarr => "/api/v3/queue/status",
        .prowlarr => null,
    };
}

pub fn prowlarrHealthPath() []const u8 {
    return "/api/v1/health";
}

pub fn prowlarrIndexerPath() []const u8 {
    return "/api/v1/indexer";
}

pub fn credentialHeaderValue(bytes: []const u8) ?[]const u8 {
    const value = std.mem.trim(u8, bytes, " \t\r\n");
    if (value.len == 0) return null;
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return null;
    return value;
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

test "adapterForKind maps supported kinds only" {
    try std.testing.expectEqual(Adapter.sonarr, adapterForKind("sonarr").?);
    try std.testing.expectEqual(Adapter.radarr, adapterForKind("Radarr").?);
    try std.testing.expectEqual(Adapter.prowlarr, adapterForKind("PROWLARR").?);
    try std.testing.expect(adapterForKind("jellyfin") == null);
}

test "paths follow supported service APIs" {
    try std.testing.expectEqualStrings("/api/v3/system/status", systemStatusPath(.sonarr));
    try std.testing.expectEqualStrings("/api/v3/queue/status", arrQueueStatusPath(.radarr).?);
    try std.testing.expectEqualStrings("/api/v1/system/status", systemStatusPath(.prowlarr));
    try std.testing.expectEqualStrings("/api/v1/health", prowlarrHealthPath());
    try std.testing.expectEqualStrings("/api/v1/indexer", prowlarrIndexerPath());
}

test "credentialHeaderValue trims files and rejects header-breaking content" {
    try std.testing.expectEqualStrings("secret", credentialHeaderValue(" secret\n").?);
    try std.testing.expect(credentialHeaderValue("\n") == null);
    try std.testing.expect(credentialHeaderValue("one\ntwo") == null);
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

test "Value writes compact summary lines" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try (Value{ .arr = .{ .version = "4.0.17.2952", .queue_count = 3 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("v4.0.17.2952 | queue 3", aw.written());

    aw.clearRetainingCapacity();
    try (Value{ .prowlarr = .{ .version = "1.33.3.5065", .health_count = 2, .indexer_count = 7 } }).write(&aw.writer);
    try std.testing.expectEqualStrings("v1.33.3.5065 | indexers 7 | health 2", aw.written());
}
