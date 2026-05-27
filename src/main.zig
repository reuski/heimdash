const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const http = std.http;

const health = @import("health.zig");
const format = @import("format.zig");
const credential = @import("credential.zig");
const summary = @import("summary.zig");
const render = @import("render.zig");

const index_html = @embedFile("index.html");
const style_css = @embedFile("style.css");
const datastar_js = @embedFile("datastar.js");

const Service = struct {
    name: []const u8,
    url: []const u8,
    check: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    credential: ?[]const u8 = null,
    entity: ?[]const u8 = null,
};

const Config = struct {
    listen: []const u8,
    mounts: []const []const u8,
    services: []const Service,
    thresholds: health.Config = .{},
};

const probe_timeout_seconds = 2;
const summary_timeout_seconds = 2;

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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const config_path = parseConfigArg(args) orelse
        std.process.fatal("usage: heimdash --config <path.json>", .{});

    const config_bytes = Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(1 << 20)) catch |err|
        std.process.fatal("failed to read {s}: {t}", .{ config_path, err });

    const cfg = std.json.parseFromSliceLeaky(Config, arena, config_bytes, .{ .ignore_unknown_fields = true }) catch |err|
        std.process.fatal("invalid config {s}: {t}", .{ config_path, err });

    const credentials_directory = init.environ_map.get("CREDENTIALS_DIRECTORY");

    const listen_addr = net.IpAddress.parseLiteral(cfg.listen) catch |err|
        std.process.fatal("invalid listen {s}: {t}", .{ cfg.listen, err });

    var server = listen_addr.listen(io, .{ .reuse_address = true }) catch |err|
        std.process.fatal("failed to bind {f}: {t}", .{ listen_addr, err });
    defer server.deinit(io);

    std.log.info("heimdash listening on http://{f}", .{listen_addr});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("accept failed: {t}", .{err});
            continue;
        };
        const thread = std.Thread.spawn(.{}, serveConnectionThread, .{ io, gpa, &cfg, credentials_directory, stream }) catch |err| {
            var s = stream;
            s.close(io);
            std.log.err("thread spawn failed: {t}", .{err});
            continue;
        };
        thread.detach();
    }
}

fn parseConfigArg(args: []const [:0]const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn serveConnectionThread(io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8, stream: net.Stream) void {
    serveConnection(io, gpa, cfg, credentials_directory, stream) catch |err|
        std.log.err("connection error: {t}", .{err});
}

fn serveConnection(io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8, stream: net.Stream) !void {
    defer {
        var s = stream;
        s.close(io);
    }

    var request_arena: std.heap.ArenaAllocator = .init(gpa);
    defer request_arena.deinit();

    var recv_buf: [4096]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &recv_buf);
    var stream_writer = stream.writer(io, &send_buf);
    var conn: http.Server = .init(&stream_reader.interface, &stream_writer.interface);

    var request = conn.receiveHead() catch return;
    try route(&request, &request_arena, io, gpa, cfg, credentials_directory);
}

fn route(req: *http.Server.Request, request_arena: *std.heap.ArenaAllocator, io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8) !void {
    const arena = request_arena.allocator();
    const path = requestPath(req.head.target);
    if (std.mem.eql(u8, path, "/")) return servePage(req, arena, io, cfg);
    if (std.mem.eql(u8, path, "/stream")) return serveStream(req, request_arena, io, gpa, cfg, credentials_directory);
    if (std.mem.eql(u8, path, "/style.css")) return serveAsset(req, style_css, "text/css; charset=utf-8");
    if (std.mem.eql(u8, path, "/datastar.js")) return serveAsset(req, datastar_js, "application/javascript; charset=utf-8");
    try req.respond("not found\n", .{
        .status = .not_found,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    });
}

fn requestPath(target: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..query];
}

const asset_cache: http.Header = .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" };
const sse_headers = [_]http.Header{
    .{ .name = "content-type", .value = "text/event-stream" },
    .{ .name = "cache-control", .value = "no-store" },
};

const stream_tick_seconds = 15;
const stream_metrics_every_ticks = 2;
const stream_services_every_ticks = 4;

fn serveAsset(req: *http.Server.Request, body: []const u8, ctype: []const u8) !void {
    try req.respond(body, .{
        .keep_alive = false,
        .extra_headers = &.{ .{ .name = "content-type", .value = ctype }, asset_cache },
    });
}

fn servePage(req: *http.Server.Request, arena: std.mem.Allocator, io: Io, cfg: *const Config) !void {
    var hostname_buf: [256]u8 = undefined;
    const hostname = readHostname(io, &hostname_buf) catch "unknown";

    var uptime_buf: [64]u8 = undefined;
    const uptime_text = format.uptime(&uptime_buf, readUptime(io) catch 0);

    const metric_data = try collectMetrics(arena, io, cfg);
    const service_items = try serviceCards(arena, cfg.services);
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    try render.page(&aw.writer, index_html, .{
        .hostname = hostname,
        .uptime = uptime_text,
        .metrics = metric_data,
        .services = .{ .items = service_items },
    });
    try req.respond(aw.written(), .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}

fn serveStream(req: *http.Server.Request, request_arena: *std.heap.ArenaAllocator, io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8) !void {
    const method = req.head.method;
    var body_buf: [16 * 1024]u8 = undefined;
    var body = try req.respondStreaming(&body_buf, .{
        .respond_options = .{
            .extra_headers = &sse_headers,
        },
    });
    if (method == .HEAD) return body.end();

    runStream(&body, request_arena, io, gpa, cfg, credentials_directory) catch |err|
        if (err != error.WriteFailed) return err;
}

fn runStream(body: *http.BodyWriter, request_arena: *std.heap.ArenaAllocator, io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8) !void {
    try writeHeartbeat(body);
    try writeStreamMetrics(body, request_arena, io, cfg);
    try writeStreamServices(body, request_arena, io, gpa, cfg, credentials_directory);

    var ticks: u64 = 0;
    while (true) {
        Io.sleep(io, .fromSeconds(stream_tick_seconds), .awake) catch return;
        ticks += 1;
        try writeHeartbeat(body);
        if (ticks % stream_metrics_every_ticks == 0) try writeStreamMetrics(body, request_arena, io, cfg);
        if (ticks % stream_services_every_ticks == 0) try writeStreamServices(body, request_arena, io, gpa, cfg, credentials_directory);
    }
}

fn writeStreamMetrics(body: *http.BodyWriter, request_arena: *std.heap.ArenaAllocator, io: Io, cfg: *const Config) !void {
    defer _ = request_arena.reset(.free_all);
    const metric_data = try collectMetrics(request_arena.allocator(), io, cfg);
    try writeMetricsEvent(&body.writer, metric_data);
    try flushStream(body);
}

fn writeStreamServices(body: *http.BodyWriter, request_arena: *std.heap.ArenaAllocator, io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8) !void {
    defer _ = request_arena.reset(.free_all);
    const service_data = try collectServices(request_arena.allocator(), io, gpa, cfg, credentials_directory);
    try writeServicesEvent(&body.writer, service_data);
    try flushStream(body);
}

fn writeHeartbeat(body: *http.BodyWriter) !void {
    try body.writer.writeAll(": heartbeat\n\n");
    try flushStream(body);
}

fn flushStream(body: *http.BodyWriter) !void {
    try body.writer.flush();
    try body.flush();
}

fn writeMetricsEvent(w: *Io.Writer, metric_data: render.Metrics) !void {
    try w.writeAll("event: datastar-patch-elements\ndata: elements ");
    try render.metrics(w, metric_data);
    try w.writeAll("\n\n");
}

fn writeServicesEvent(w: *Io.Writer, service_data: render.Services) !void {
    try w.writeAll("event: datastar-patch-elements\ndata: elements ");
    try render.services(w, service_data);
    try w.writeAll("\n\n");
}

fn collectServices(arena: std.mem.Allocator, io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8) !render.Services {
    const states = try arena.alloc(render.ServiceReachability, cfg.services.len);
    const summaries = try arena.alloc(render.ServiceSummary, cfg.services.len);
    for (cfg.services, 0..) |svc, i| {
        states[i] = probeService(gpa, io, svc);
        summaries[i] = serviceSummary(arena, io, gpa, credentials_directory, svc);
    }
    return .{
        .items = try serviceCards(arena, cfg.services),
        .states = states,
        .summaries = summaries,
    };
}

fn serviceCards(arena: std.mem.Allocator, services: []const Service) ![]const render.ServiceCard {
    const cards = try arena.alloc(render.ServiceCard, services.len);
    for (services, 0..) |svc, i| cards[i] = .{ .name = svc.name, .url = svc.url };
    return cards;
}

fn serviceSummary(arena: std.mem.Allocator, io: Io, gpa: std.mem.Allocator, credentials_directory: ?[]const u8, svc: Service) render.ServiceSummary {
    const adapter = summary.adapterForKind(svc.kind orelse return .{}) orelse return .{};
    if (adapter == .home_assistant and svc.entity == null) return .{};
    const credential_value: ?[]const u8 = if (svc.credential) |name| value: {
        const credential_bytes = readCredentialBytes(arena, io, credentials_directory, name) catch return .{};
        break :value summary.credentialHeaderValue(credential_bytes) orelse return .{};
    } else null;
    if (summary.requiresCredential(adapter) and credential_value == null) return .{};
    return within(io, summary_timeout_seconds, summaryText, .{ arena, gpa, io, adapter, svc.url, credential_value, svc.entity }) orelse .{};
}

fn readCredentialBytes(arena: std.mem.Allocator, io: Io, credentials_directory: ?[]const u8, name: []const u8) ![]const u8 {
    const directory = credentials_directory orelse return error.CredentialUnavailable;
    const credential_path = credential.path(arena, directory, name) catch return error.CredentialUnavailable;
    return Io.Dir.cwd().readFileAlloc(io, credential_path, arena, .limited(64 * 1024)) catch return error.CredentialUnavailable;
}

fn summaryText(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: Io, adapter: summary.Adapter, base_url: []const u8, credential_value: ?[]const u8, entity: ?[]const u8) render.ServiceSummary {
    var parse_arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer parse_arena_state.deinit();
    const parse_arena = parse_arena_state.allocator();

    const value = fetchSummaryValue(gpa, parse_arena, io, adapter, base_url, credential_value, entity) catch return .{};
    var aw: Io.Writer.Allocating = .init(arena);
    value.write(&aw.writer) catch return .{};
    return .{ .text = aw.written() };
}

fn fetchSummaryValue(gpa: std.mem.Allocator, parse_arena: std.mem.Allocator, io: Io, adapter: summary.Adapter, base_url: []const u8, credential_value: ?[]const u8, entity: ?[]const u8) !summary.Value {
    switch (adapter) {
        .sonarr, .radarr => {
            const cred = credential_value orelse return error.SummaryUnavailable;
            const headers = [_]http.Header{.{ .name = "X-Api-Key", .value = cred }};
            const status_json = try fetchSummaryBody(gpa, io, base_url, summary.systemStatusPath(adapter), &headers, null);
            defer gpa.free(status_json);
            const queue_json = try fetchSummaryBody(gpa, io, base_url, summary.arrQueueStatusPath(adapter).?, &headers, null);
            defer gpa.free(queue_json);
            return .{ .arr = try summary.parseArr(parse_arena, status_json, queue_json) };
        },
        .prowlarr => {
            const cred = credential_value orelse return error.SummaryUnavailable;
            const headers = [_]http.Header{.{ .name = "X-Api-Key", .value = cred }};
            const status_json = try fetchSummaryBody(gpa, io, base_url, summary.systemStatusPath(adapter), &headers, null);
            defer gpa.free(status_json);
            const health_json = try fetchSummaryBody(gpa, io, base_url, summary.prowlarrHealthPath(), &headers, null);
            defer gpa.free(health_json);
            const indexer_json = try fetchSummaryBody(gpa, io, base_url, summary.prowlarrIndexerPath(), &headers, null);
            defer gpa.free(indexer_json);
            return .{ .prowlarr = try summary.parseProwlarr(parse_arena, status_json, health_json, indexer_json) };
        },
        .jellyfin => {
            const cred = credential_value orelse return error.SummaryUnavailable;
            const headers = [_]http.Header{.{ .name = "X-Emby-Token", .value = cred }};
            const status_json = try fetchSummaryBody(gpa, io, base_url, summary.systemStatusPath(adapter), &headers, null);
            defer gpa.free(status_json);
            const sessions_json = try fetchSummaryBody(gpa, io, base_url, summary.jellyfinSessionsPath(), &headers, null);
            defer gpa.free(sessions_json);
            return .{ .jellyfin = try summary.parseJellyfin(parse_arena, status_json, sessions_json) };
        },
        .adguard => {
            const authorization: ?[]u8 = if (credential_value) |cred|
                try summary.basicAuthorizationValue(gpa, cred)
            else
                null;
            defer if (authorization) |value| {
                @memset(value, 0);
                gpa.free(value);
            };
            const status_json = try fetchSummaryBody(gpa, io, base_url, summary.systemStatusPath(adapter), &.{}, authorization);
            defer gpa.free(status_json);
            const stats_json = try fetchSummaryBody(gpa, io, base_url, summary.adguardStatsPath(), &.{}, authorization);
            defer gpa.free(stats_json);
            return .{ .adguard = try summary.parseAdGuard(parse_arena, status_json, stats_json) };
        },
        .qbittorrent => {
            const cred = credential_value orelse return error.SummaryUnavailable;
            const cookie = try fetchQbittorrentCookie(gpa, io, base_url, cred);
            defer {
                @memset(cookie, 0);
                gpa.free(cookie);
            }
            const headers = [_]http.Header{.{ .name = "Cookie", .value = cookie }};
            const version_text = try fetchSummaryBody(gpa, io, base_url, summary.systemStatusPath(adapter), &headers, null);
            defer gpa.free(version_text);
            const transfer_json = try fetchSummaryBody(gpa, io, base_url, summary.qbittorrentTransferPath(), &headers, null);
            defer gpa.free(transfer_json);
            return .{ .qbittorrent = try summary.parseQbittorrent(parse_arena, version_text, transfer_json) };
        },
        .home_assistant => {
            const cred = credential_value orelse return error.SummaryUnavailable;
            const entity_id = entity orelse return error.SummaryUnavailable;
            const authorization = try summary.bearerAuthorizationValue(gpa, cred);
            defer {
                @memset(authorization, 0);
                gpa.free(authorization);
            }
            const status_json = try fetchSummaryBody(gpa, io, base_url, summary.systemStatusPath(adapter), &.{}, authorization);
            defer gpa.free(status_json);
            const entity_path = try summary.homeAssistantStatePath(gpa, entity_id);
            defer gpa.free(entity_path);
            const entity_json = try fetchSummaryBody(gpa, io, base_url, entity_path, &.{}, authorization);
            defer gpa.free(entity_json);
            return .{ .home_assistant = try summary.parseHomeAssistant(parse_arena, status_json, entity_json) };
        },
    }
}

fn fetchSummaryBody(gpa: std.mem.Allocator, io: Io, base_url: []const u8, path: []const u8, headers: []const http.Header, authorization: ?[]const u8) ![]u8 {
    const url = try endpointUrl(gpa, base_url, path);
    defer gpa.free(url);

    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .authorization = if (authorization) |value| .{ .override = value } else .default },
        .extra_headers = headers,
    });

    if (!summary.isAvailableHttpStatus(result.status)) return error.SummaryUnavailable;
    return try aw.toOwnedSlice();
}

fn fetchQbittorrentCookie(gpa: std.mem.Allocator, io: Io, base_url: []const u8, credential_value: []const u8) ![]u8 {
    const url = try endpointUrl(gpa, base_url, "/api/v2/auth/login");
    defer gpa.free(url);
    const body = try summary.qbittorrentLoginBody(gpa, credential_value);
    defer {
        @memset(body, 0);
        gpa.free(body);
    }

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

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
    if (!summary.isAvailableHttpStatus(response.head.status)) return error.SummaryUnavailable;

    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "set-cookie")) continue;
        const cookie = summary.qbittorrentSessionCookie(header.value) orelse continue;
        return try gpa.dupe(u8, cookie);
    }
    return error.SummaryUnavailable;
}

fn endpointUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8) ![]u8 {
    const root = std.mem.trimEnd(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ root, path });
}

fn probeService(gpa: std.mem.Allocator, io: Io, svc: Service) render.ServiceReachability {
    return within(io, probe_timeout_seconds, probeUrl, .{ gpa, io, svc.check orelse svc.url }) orelse .down;
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

fn collectMetrics(arena: std.mem.Allocator, io: Io, cfg: *const Config) !render.Metrics {
    const t = cfg.thresholds;

    const load_opt: ?f64 = readLoadAvg(io) catch null;
    const ncpu = std.Thread.getCpuCount() catch 1;
    const cpu_pct: ?u64 = if (load_opt) |load|
        @min(100, @as(u64, @intFromFloat(load / @as(f64, @floatFromInt(ncpu)) * 100.0)))
    else
        null;
    const cpu_detail = if (load_opt) |load|
        try std.fmt.allocPrint(arena, "load {d:.2}", .{load})
    else
        "load --";
    const cpu: render.MetricRow = .{
        .label = "CPU",
        .percent = cpu_pct,
        .detail = cpu_detail,
        .state = health.classify(cpu_pct, t.cpu),
    };

    const mem = readMemInfo(io) catch render.MemInfo{ .total = 0, .available = 0 };
    const memory = try usageRow(arena, "Memory", mem.total, mem.available, t.memory);

    const disks = try arena.alloc(render.MetricRow, cfg.mounts.len);
    for (cfg.mounts, 0..) |mnt, i| {
        const fs = readDiskFree(mnt) catch render.DiskUsage{ .total = 0, .free = 0 };
        disks[i] = try usageRow(arena, mnt, fs.total, fs.free, health.diskThresholdFor(t, mnt));
    }
    return .{ .cpu = cpu, .memory = memory, .disks = disks };
}

fn usageRow(arena: std.mem.Allocator, label: []const u8, total: u64, free: u64, thresholds: health.Thresholds) !render.MetricRow {
    const used = if (total > free) total - free else 0;
    const pct: ?u64 = if (total == 0) null else @min(100, used * 100 / total);
    var buf: [32]u8 = undefined;
    const detail = if (total == 0)
        "-- free"
    else
        try std.fmt.allocPrint(arena, "{s} free", .{format.bytes(&buf, free)});
    return .{ .label = label, .percent = pct, .detail = detail, .state = health.classify(pct, thresholds) };
}

fn readSmall(io: Io, path: []const u8, buf: []u8) ![]const u8 {
    var file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var fr = file.reader(io, &.{});
    const n = try fr.interface.readSliceShort(buf);
    return buf[0..n];
}

fn readHostname(io: Io, buf: []u8) ![]const u8 {
    return std.mem.trim(u8, try readSmall(io, "/etc/hostname", buf), " \t\r\n");
}

fn readUptime(io: Io) !u64 {
    var buf: [128]u8 = undefined;
    const text = try readSmall(io, "/proc/uptime", &buf);
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const dot = std.mem.indexOfScalar(u8, text[0..space], '.') orelse space;
    return std.fmt.parseInt(u64, text[0..dot], 10) catch 0;
}

fn readLoadAvg(io: Io) !f64 {
    var buf: [128]u8 = undefined;
    const text = try readSmall(io, "/proc/loadavg", &buf);
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return error.BadLoadAvg;
    return std.fmt.parseFloat(f64, text[0..space]);
}

fn readMemInfo(io: Io) !render.MemInfo {
    var buf: [4096]u8 = undefined;
    const text = try readSmall(io, "/proc/meminfo", &buf);
    return .{
        .total = format.parseMemKb(text, "MemTotal:") * 1024,
        .available = format.parseMemKb(text, "MemAvailable:") * 1024,
    };
}

fn readDiskFree(path: []const u8) !render.DiskUsage {
    if (builtin.os.tag != .linux) return .{ .total = 0, .free = 0 };

    const linux = std.os.linux;
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var st: StatFs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(&path_buf), @intFromPtr(&st));
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.StatFsFailed,
    }
    const bs: u64 = @intCast(st.f_bsize);
    return .{ .total = st.f_blocks *% bs, .free = st.f_bavail *% bs };
}

// Linux statfs (64-bit). Stable layout on x86_64/aarch64/riscv64.
const StatFs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};
