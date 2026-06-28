const std = @import("std");
const Io = std.Io;
const http = std.http;
const net = std.Io.net;

const credential = @import("credential.zig");
const render = @import("render.zig");
const summary = @import("summary.zig");

const probe_timeout_seconds = 2;
const summary_timeout_seconds = 2;

pub const Service = struct {
    name: []const u8,
    url: []const u8,
    check: ?[]const u8 = null,
    api: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    credential: ?[]const u8 = null,
    entity: ?[]const u8 = null,
    stamp: ?[]const u8 = null,
};

pub fn cards(arena: std.mem.Allocator, services: []const Service) ![]const render.ServiceCard {
    const result = try arena.alloc(render.ServiceCard, services.len);
    for (services, 0..) |svc, i| result[i] = .{ .name = svc.name, .url = svc.url };
    return result;
}

pub fn collect(
    arena: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    services: []const Service,
    credentials_directory: ?[]const u8,
) !render.Services {
    const states = try arena.alloc(render.ServiceReachability, services.len);
    const summaries = try arena.alloc(render.ServiceSummary, services.len);
    const raw = try arena.alloc(render.ServiceSummary, services.len);

    const scratch = try arena.alloc(std.heap.ArenaAllocator, services.len);
    for (scratch) |*state| state.* = .init(gpa);
    defer for (scratch) |*state| state.deinit();

    var group: Io.Group = .init;
    for (services, 0..) |svc, i|
        group.async(io, collectOne, .{ scratch[i].allocator(), io, gpa, credentials_directory, svc, &states[i], &raw[i] });
    group.await(io) catch {};

    for (raw, 0..) |item, i| summaries[i] = .{ .text = try arena.dupe(u8, item.text) };

    return .{ .items = try cards(arena, services), .states = states, .summaries = summaries };
}

fn collectOne(
    arena: std.mem.Allocator,
    io: Io,
    gpa: std.mem.Allocator,
    credentials_directory: ?[]const u8,
    svc: Service,
    state_out: *render.ServiceReachability,
    summary_out: *render.ServiceSummary,
) void {
    state_out.* = probeService(gpa, io, svc);
    summary_out.* = serviceSummary(arena, io, gpa, credentials_directory, svc);
}

fn probeService(gpa: std.mem.Allocator, io: Io, svc: Service) render.ServiceReachability {
    if (serviceAdapter(svc) == .mumble)
        return within(io, probe_timeout_seconds, probeMumble, .{ io, svc.check orelse svc.api orelse svc.url }) orelse .down;
    return within(io, probe_timeout_seconds, probeUrl, .{ gpa, io, svc.check orelse svc.url }) orelse .down;
}

fn serviceAdapter(svc: Service) ?summary.Adapter {
    return summary.adapterForKind(svc.kind orelse return null);
}

fn probeMumble(io: Io, endpoint_url: []const u8) render.ServiceReachability {
    _ = mumblePing(io, endpoint_url) catch return .down;
    return .up;
}

fn mumblePing(io: Io, endpoint_url: []const u8) !summary.Mumble {
    const endpoint = try summary.udpEndpoint(endpoint_url);
    const address = try net.IpAddress.resolve(io, endpoint.host, endpoint.port);
    const bind_address: net.IpAddress = switch (address) {
        .ip4 => .{ .ip4 = .unspecified(0) },
        .ip6 => .{ .ip6 = .unspecified(0) },
    };
    const socket = try bind_address.bind(io, .{ .mode = .dgram });
    defer socket.close(io);

    var ident_bytes: [8]u8 = undefined;
    io.random(&ident_bytes);
    const ident = std.mem.readInt(u64, &ident_bytes, .big);
    const request = summary.mumblePingRequest(ident);
    try socket.send(io, &address, &request);

    var buffer: [64]u8 = undefined;
    const message = try socket.receive(io, &buffer);
    return summary.parseMumblePing(message.data, ident);
}

fn atticValue(io: Io, stamp_path: []const u8) !summary.Attic {
    var file = try Io.Dir.openFileAbsolute(io, stamp_path, .{});
    defer file.close(io);
    var fr = file.reader(io, &.{});
    var buf: [32]u8 = undefined;
    const n = try fr.interface.readSliceShort(&buf);
    const primed = summary.parseStampSeconds(buf[0..n]) orelse return error.SummaryUnavailable;
    const now: u64 = @intCast(@max(Io.Timestamp.now(io, .real).toSeconds(), 0));
    return .{ .primed_age_seconds = if (now > primed) now - primed else 0 };
}

fn probeUrl(gpa: std.mem.Allocator, io: Io, url: []const u8) render.ServiceReachability {
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
    }) catch return .down;

    return if (isReachableStatus(result.status)) .up else .down;
}

fn isReachableStatus(status: http.Status) bool {
    return switch (status) {
        .unauthorized, .forbidden, .not_found => true,
        else => switch (status.class()) {
            .success, .redirect => true,
            else => false,
        },
    };
}

fn serviceSummary(arena: std.mem.Allocator, io: Io, gpa: std.mem.Allocator, credentials_directory: ?[]const u8, svc: Service) render.ServiceSummary {
    const adapter = summary.adapterForKind(svc.kind orelse return .{}) orelse return .{};
    if (adapter == .home_assistant and svc.entity == null) return .{};
    if (adapter == .attic and svc.stamp == null) return .{};
    const credential_value: ?[]const u8 = if (svc.credential) |name| value: {
        const credential_bytes = readCredentialBytes(arena, io, credentials_directory, name) catch return .{};
        break :value summary.credentialHeaderValue(credential_bytes) orelse return .{};
    } else null;
    if (summary.requiresCredential(adapter) and credential_value == null) return .{};
    return within(io, summary_timeout_seconds, summaryText, .{ arena, gpa, io, adapter, svc.api orelse svc.url, credential_value, svc.entity, svc.stamp }) orelse .{};
}

fn readCredentialBytes(arena: std.mem.Allocator, io: Io, credentials_directory: ?[]const u8, name: []const u8) ![]const u8 {
    const directory = credentials_directory orelse return error.CredentialUnavailable;
    const credential_path = credential.path(arena, directory, name) catch return error.CredentialUnavailable;
    return Io.Dir.cwd().readFileAlloc(io, credential_path, arena, .limited(64 * 1024)) catch return error.CredentialUnavailable;
}

fn summaryText(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: Io, adapter: summary.Adapter, base_url: []const u8, credential_value: ?[]const u8, entity: ?[]const u8, stamp: ?[]const u8) render.ServiceSummary {
    var parse_arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer parse_arena_state.deinit();

    const value = fetchSummaryValue(gpa, parse_arena_state.allocator(), io, adapter, base_url, credential_value, entity, stamp) catch return .{};
    var aw: Io.Writer.Allocating = .init(arena);
    value.write(&aw.writer) catch return .{};
    return .{ .text = aw.written() };
}

const RequestAuth = struct {
    authorization: ?[]u8 = null,
    cookie: ?[]u8 = null,
    header_buf: [1]http.Header = undefined,
    header_count: usize = 0,

    fn init(
        gpa: std.mem.Allocator,
        client: *http.Client,
        base_url: []const u8,
        adapter: summary.Adapter,
        credential_value: ?[]const u8,
    ) !RequestAuth {
        switch (summary.authMethod(adapter)) {
            .none, .subsonic => return .{},
            .api_key => return withHeader("X-Api-Key", credential_value orelse return error.SummaryUnavailable),
            .emby_token => return withHeader("X-Emby-Token", credential_value orelse return error.SummaryUnavailable),
            .bearer => return .{
                .authorization = try summary.bearerAuthorizationValue(gpa, credential_value orelse return error.SummaryUnavailable),
            },
            .basic => return .{
                .authorization = try summary.basicAuthorizationValue(gpa, credential_value orelse return error.SummaryUnavailable),
            },
            .basic_optional => {
                const cred = credential_value orelse return .{};
                return .{ .authorization = try summary.basicAuthorizationValue(gpa, cred) };
            },
            .session_cookie => {
                const cred = credential_value orelse return error.SummaryUnavailable;
                const cookie = try fetchVaultwardenCookie(client, gpa, base_url, cred);
                var auth = withHeader("Cookie", cookie);
                auth.cookie = cookie;
                return auth;
            },
        }
    }

    fn withHeader(name: []const u8, value: []const u8) RequestAuth {
        var auth: RequestAuth = .{ .header_count = 1 };
        auth.header_buf[0] = .{ .name = name, .value = value };
        return auth;
    }

    fn headers(auth: *const RequestAuth) []const http.Header {
        return auth.header_buf[0..auth.header_count];
    }

    fn deinit(auth: *RequestAuth, gpa: std.mem.Allocator) void {
        for ([_]?[]u8{ auth.authorization, auth.cookie }) |secret| if (secret) |value| {
            @memset(value, 0);
            gpa.free(value);
        };
    }
};

fn fetchSummaryValue(gpa: std.mem.Allocator, parse_arena: std.mem.Allocator, io: Io, adapter: summary.Adapter, base_url: []const u8, credential_value: ?[]const u8, entity: ?[]const u8, stamp: ?[]const u8) !summary.Value {
    if (adapter == .mumble) return .{ .mumble = try mumblePing(io, base_url) };
    if (adapter == .attic) {
        const stamp_path = stamp orelse return error.SummaryUnavailable;
        return .{ .attic = try atticValue(io, stamp_path) };
    }

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var auth: RequestAuth = try .init(gpa, &client, base_url, adapter, credential_value);
    defer auth.deinit(gpa);

    switch (adapter) {
        .sonarr, .radarr, .lidarr => {
            const status_json = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(status_json);
            const queue_json = try fetchSummaryBody(&client, gpa, base_url, summary.arrQueueStatusPath(adapter).?, &auth);
            defer gpa.free(queue_json);
            return .{ .arr = try summary.parseArr(parse_arena, status_json, queue_json) };
        },
        .prowlarr => {
            const status_json = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(status_json);
            const health_json = try fetchSummaryBody(&client, gpa, base_url, summary.prowlarrHealthPath(), &auth);
            defer gpa.free(health_json);
            const indexer_json = try fetchSummaryBody(&client, gpa, base_url, summary.prowlarrIndexerPath(), &auth);
            defer gpa.free(indexer_json);
            return .{ .prowlarr = try summary.parseProwlarr(parse_arena, status_json, health_json, indexer_json) };
        },
        .jellyfin => {
            const status_json = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(status_json);
            const counts_json = try fetchSummaryBody(&client, gpa, base_url, summary.jellyfinItemCountsPath(), &auth);
            defer gpa.free(counts_json);
            return .{ .jellyfin = try summary.parseJellyfin(parse_arena, status_json, counts_json) };
        },
        .adguard => {
            const status_json = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(status_json);
            const stats_json = try fetchSummaryBody(&client, gpa, base_url, summary.adguardStatsPath(), &auth);
            defer gpa.free(stats_json);
            return .{ .adguard = try summary.parseAdGuard(parse_arena, status_json, stats_json) };
        },
        .qbittorrent => {
            const version_text = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(version_text);
            const transfer_json = try fetchSummaryBody(&client, gpa, base_url, summary.qbittorrentTransferPath(), &auth);
            defer gpa.free(transfer_json);
            return .{ .qbittorrent = try summary.parseQbittorrent(parse_arena, version_text, transfer_json) };
        },
        .home_assistant => {
            const entity_id = entity orelse return error.SummaryUnavailable;
            const entity_path = try summary.homeAssistantStatePath(gpa, entity_id);
            defer gpa.free(entity_path);
            const entity_json = try fetchSummaryBody(&client, gpa, base_url, entity_path, &auth);
            defer gpa.free(entity_json);
            return .{ .home_assistant = try summary.parseHomeAssistant(parse_arena, entity_json) };
        },
        .audiobookshelf => {
            const libraries_json = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(libraries_json);
            const library_ids = try summary.parseAudiobookshelfBookLibraries(parse_arena, libraries_json);

            var book_count: u64 = 0;
            var duration_seconds: u64 = 0;
            for (library_ids) |library_id| {
                const stats_path = try summary.audiobookshelfStatsPath(gpa, library_id);
                defer gpa.free(stats_path);
                const stats_json = try fetchSummaryBody(&client, gpa, base_url, stats_path, &auth);
                defer gpa.free(stats_json);
                const stats = try summary.parseAudiobookshelfStats(parse_arena, stats_json);
                book_count += stats.items;
                duration_seconds += stats.duration_seconds;
            }
            return .{ .audiobookshelf = .{ .book_count = book_count, .duration_seconds = duration_seconds } };
        },
        .vaultwarden => {
            const users_json = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(users_json);
            return .{ .vaultwarden = try summary.parseVaultwarden(parse_arena, users_json) };
        },
        .maintainerr => {
            const metrics_json = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(metrics_json);
            return .{ .maintainerr = try summary.parseMaintainerr(parse_arena, metrics_json) };
        },
        .valheim => {
            const status_json = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(status_json);
            return .{ .valheim = try summary.parseValheim(parse_arena, status_json) };
        },
        .calibre => {
            const feed_xml = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(feed_xml);
            return .{ .calibre = try summary.parseCalibre(feed_xml) };
        },
        .navidrome => {
            const cred = credential_value orelse return error.SummaryUnavailable;
            var salt_bytes: [8]u8 = undefined;
            io.random(&salt_bytes);
            const salt = std.fmt.bytesToHex(salt_bytes, .lower);
            const query = try summary.navidromeAuthQuery(gpa, cred, &salt);
            defer gpa.free(query);
            const path = try std.fmt.allocPrint(gpa, "{s}?{s}", .{ summary.systemStatusPath(adapter).?, query });
            defer gpa.free(path);
            const status_json = try fetchSummaryBody(&client, gpa, base_url, path, &auth);
            defer gpa.free(status_json);
            return .{ .navidrome = try summary.parseNavidrome(parse_arena, status_json) };
        },
        .skaldi => {
            const health_json = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(health_json);
            return .{ .skaldi = try summary.parseSkaldi(parse_arena, health_json) };
        },
        .tome => {
            const overview_json = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(overview_json);
            return .{ .tome = try summary.parseTome(parse_arena, overview_json) };
        },
        .ntfy => {
            const body = try fetchSummaryBody(&client, gpa, base_url, summary.systemStatusPath(adapter).?, &auth);
            defer gpa.free(body);
            return .{ .ntfy = summary.parseNtfy(parse_arena, body) };
        },
        .mumble => unreachable,
        .attic => unreachable,
    }
}

fn fetchSummaryBody(client: *http.Client, gpa: std.mem.Allocator, base_url: []const u8, path: []const u8, auth: *const RequestAuth) ![]u8 {
    const url = try endpointUrl(gpa, base_url, path);
    defer gpa.free(url);

    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .redirect_behavior = .unhandled,
        .keep_alive = true,
        .headers = .{ .authorization = if (auth.authorization) |value| .{ .override = value } else .default },
        .extra_headers = auth.headers(),
    });

    if (!summary.isAvailableHttpStatus(result.status)) return error.SummaryUnavailable;
    return try aw.toOwnedSlice();
}

fn fetchVaultwardenCookie(client: *http.Client, gpa: std.mem.Allocator, base_url: []const u8, credential_value: []const u8) ![]u8 {
    const url = try endpointUrl(gpa, base_url, summary.vaultwardenLoginPath());
    defer gpa.free(url);
    const body = try summary.vaultwardenLoginBody(gpa, credential_value);
    defer {
        @memset(body, 0);
        gpa.free(body);
    }

    const uri = try std.Uri.parse(url);
    const referer = std.mem.trimEnd(u8, base_url, "/");
    const headers = [_]http.Header{.{ .name = "Referer", .value = referer }};
    var req = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .extra_headers = &headers,
    });
    defer req.deinit();

    try req.sendBodyComplete(body);
    var response = try req.receiveHead(&.{});

    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "set-cookie")) continue;
        const cookie = summary.vaultwardenSessionCookie(header.value) orelse continue;
        return try gpa.dupe(u8, cookie);
    }
    return error.SummaryUnavailable;
}

fn endpointUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    const root = std.mem.trimEnd(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ root, path });
}

fn within(io: Io, seconds: i64, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) ?@typeInfo(@TypeOf(func)).@"fn".return_type.? {
    const Result = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    const Race = union(enum) { value: Result, expired: void };
    var buffer: [2]Race = undefined;
    var race: Io.Select(Race) = .init(io, &buffer);
    defer race.cancelDiscard();

    race.concurrent(.value, func, args) catch return @call(.auto, func, args);
    race.concurrent(.expired, expire, .{ io, seconds }) catch {};

    return switch (race.await() catch return null) {
        .value => |value| value,
        .expired => null,
    };
}

fn expire(io: Io, seconds: i64) void {
    Io.sleep(io, .fromSeconds(seconds), .awake) catch {};
}
