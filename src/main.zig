const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const http = std.http;

const health = @import("health.zig");
const format = @import("format.zig");
const host = @import("host.zig");
const render = @import("render.zig");
const sampler = @import("sampler.zig");
const service = @import("service.zig");

const index_html = @embedFile("index.html");
const style_css = @embedFile("style.css");
const datastar_js = @embedFile("datastar.js");

const Config = struct {
    listen: []const u8,
    mounts: []const []const u8,
    services: []const service.Service,
    thresholds: health.Config = .{},
    networkInterface: ?[]const u8 = null,
};

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

    var metric_sampler = sampler.Sampler.init(gpa, .{
        .mounts = cfg.mounts,
        .thresholds = cfg.thresholds,
        .network_interface = cfg.networkInterface,
    }) catch |err|
        std.process.fatal("failed to initialize metric sampler: {t}", .{err});
    defer metric_sampler.deinit();

    const sampler_thread = std.Thread.spawn(.{}, sampler.Sampler.run, .{ &metric_sampler, io }) catch |err|
        std.process.fatal("failed to start metric sampler: {t}", .{err});
    sampler_thread.detach();

    var server = listen_addr.listen(io, .{ .reuse_address = true }) catch |err|
        std.process.fatal("failed to bind {f}: {t}", .{ listen_addr, err });
    defer server.deinit(io);

    std.log.info("heimdash listening on http://{f}", .{listen_addr});

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("accept failed: {t}", .{err});
            continue;
        };
        const thread = std.Thread.spawn(.{}, serveConnectionThread, .{ io, gpa, &cfg, credentials_directory, &metric_sampler, stream }) catch |err| {
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

fn serveConnectionThread(io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8, metric_sampler: *sampler.Sampler, stream: net.Stream) void {
    serveConnection(io, gpa, cfg, credentials_directory, metric_sampler, stream) catch |err|
        std.log.err("connection error: {t}", .{err});
}

fn serveConnection(io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8, metric_sampler: *sampler.Sampler, stream: net.Stream) !void {
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
    try route(&request, &request_arena, io, gpa, cfg, credentials_directory, metric_sampler);
}

fn route(req: *http.Server.Request, request_arena: *std.heap.ArenaAllocator, io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8, metric_sampler: *sampler.Sampler) !void {
    const arena = request_arena.allocator();
    const path = requestPath(req.head.target);
    if (std.mem.eql(u8, path, "/")) return servePage(req, arena, io, cfg, metric_sampler);
    if (std.mem.eql(u8, path, "/stream")) return serveStream(req, request_arena, io, gpa, cfg, credentials_directory, metric_sampler);
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

fn servePage(req: *http.Server.Request, arena: std.mem.Allocator, io: Io, cfg: *const Config, metric_sampler: *sampler.Sampler) !void {
    var hostname_buf: [256]u8 = undefined;
    const host_name = host.hostname(io, &hostname_buf) catch "unknown";

    var uptime_buf: [64]u8 = undefined;
    const uptime_text = format.uptime(&uptime_buf, host.uptime(io) catch 0);

    const metric_data = try metric_sampler.snapshot(arena, io);
    const service_items = try service.cards(arena, cfg.services);
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    try render.page(&aw.writer, index_html, .{
        .hostname = host_name,
        .uptime = uptime_text,
        .metrics = metric_data,
        .services = .{ .items = service_items },
    });
    try req.respond(aw.written(), .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}

fn serveStream(req: *http.Server.Request, request_arena: *std.heap.ArenaAllocator, io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8, metric_sampler: *sampler.Sampler) !void {
    const method = req.head.method;
    var body_buf: [16 * 1024]u8 = undefined;
    var body = try req.respondStreaming(&body_buf, .{
        .respond_options = .{
            .extra_headers = &sse_headers,
        },
    });
    if (method == .HEAD) return body.end();

    runStream(&body, request_arena, io, gpa, cfg, credentials_directory, metric_sampler) catch |err|
        if (err != error.WriteFailed) return err;
}

fn runStream(body: *http.BodyWriter, request_arena: *std.heap.ArenaAllocator, io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8, metric_sampler: *sampler.Sampler) !void {
    try writeHeartbeat(body);
    try writeStreamMetrics(body, request_arena, io, metric_sampler);
    try writeStreamServices(body, request_arena, io, gpa, cfg, credentials_directory);

    var ticks: u64 = 0;
    while (true) {
        Io.sleep(io, .fromSeconds(stream_tick_seconds), .awake) catch return;
        ticks += 1;
        try writeHeartbeat(body);
        if (ticks % stream_metrics_every_ticks == 0) try writeStreamMetrics(body, request_arena, io, metric_sampler);
        if (ticks % stream_services_every_ticks == 0) try writeStreamServices(body, request_arena, io, gpa, cfg, credentials_directory);
    }
}

fn writeStreamMetrics(body: *http.BodyWriter, request_arena: *std.heap.ArenaAllocator, io: Io, metric_sampler: *sampler.Sampler) !void {
    defer _ = request_arena.reset(.free_all);
    const metric_data = try metric_sampler.snapshot(request_arena.allocator(), io);
    try writePatch(&body.writer, render.metrics, metric_data);
    try flushStream(body);
}

fn writeStreamServices(body: *http.BodyWriter, request_arena: *std.heap.ArenaAllocator, io: Io, gpa: std.mem.Allocator, cfg: *const Config, credentials_directory: ?[]const u8) !void {
    defer _ = request_arena.reset(.free_all);
    const service_data = try service.collect(request_arena.allocator(), io, gpa, cfg.services, credentials_directory);
    try writePatch(&body.writer, render.services, service_data);
    try flushStream(body);
}

fn writePatch(w: *Io.Writer, comptime renderFn: anytype, data: anytype) !void {
    try w.writeAll("event: datastar-patch-elements\ndata: elements ");
    try renderFn(w, data);
    try w.writeAll("\n\n");
}

fn writeHeartbeat(body: *http.BodyWriter) !void {
    try body.writer.writeAll(": heartbeat\n\n");
    try flushStream(body);
}

fn flushStream(body: *http.BodyWriter) !void {
    try body.writer.flush();
    try body.flush();
}
