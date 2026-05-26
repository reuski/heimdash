const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const http = std.http;

const health = @import("health.zig");
const format = @import("format.zig");

const index_html = @embedFile("index.html");
const style_css = @embedFile("style.css");
const datastar_js = @embedFile("datastar.js");

const Service = struct {
    name: []const u8,
    url: []const u8,
    check: ?[]const u8 = null,
};

const Config = struct {
    listen: []const u8,
    mounts: []const []const u8,
    services: []const Service,
    thresholds: health.Config = .{},
};

const ServiceReachability = enum { checking, up, down };

const ProbeJob = struct {
    allocator: std.mem.Allocator,
    io: Io,
    done: Io.Event = .unset,
    refs: std.atomic.Value(u32) = .init(2),
    state: ServiceReachability = .down,
    url: []const u8,

    fn release(job: *ProbeJob) void {
        if (job.refs.fetchSub(1, .acq_rel) != 1) return;
        job.allocator.free(job.url);
        job.allocator.destroy(job);
    }
};

const DiskUsage = struct { total: u64, free: u64 };
const MemInfo = struct { total: u64, available: u64 };

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
        const thread = std.Thread.spawn(.{}, serveConnectionThread, .{ io, gpa, &cfg, stream }) catch |err| {
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

fn serveConnectionThread(io: Io, gpa: std.mem.Allocator, cfg: *const Config, stream: net.Stream) void {
    serveConnection(io, gpa, cfg, stream) catch |err|
        std.log.err("connection error: {t}", .{err});
}

fn serveConnection(io: Io, gpa: std.mem.Allocator, cfg: *const Config, stream: net.Stream) !void {
    defer {
        var s = stream;
        s.close(io);
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var recv_buf: [4096]u8 = undefined;
    var send_buf: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &recv_buf);
    var stream_writer = stream.writer(io, &send_buf);
    var conn: http.Server = .init(&stream_reader.interface, &stream_writer.interface);

    var request = conn.receiveHead() catch return;
    try route(&request, arena, io, gpa, cfg);
}

fn route(req: *http.Server.Request, arena: std.mem.Allocator, io: Io, gpa: std.mem.Allocator, cfg: *const Config) !void {
    const path = requestPath(req.head.target);
    if (std.mem.eql(u8, path, "/")) return servePage(req, arena, io, cfg);
    if (std.mem.eql(u8, path, "/poll")) return servePoll(req, arena, io, cfg);
    if (std.mem.eql(u8, path, "/poll/services")) return servePollServices(req, arena, io, gpa, cfg);
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

fn serveAsset(req: *http.Server.Request, body: []const u8, ctype: []const u8) !void {
    try req.respond(body, .{
        .keep_alive = false,
        .extra_headers = &.{ .{ .name = "content-type", .value = ctype }, asset_cache },
    });
}

fn servePage(req: *http.Server.Request, arena: std.mem.Allocator, io: Io, cfg: *const Config) !void {
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    try renderPage(&aw.writer, io, cfg);
    try req.respond(aw.written(), .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}

fn servePoll(req: *http.Server.Request, arena: std.mem.Allocator, io: Io, cfg: *const Config) !void {
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("event: datastar-patch-elements\ndata: elements ");
    try renderMetrics(w, io, cfg);
    try w.writeAll("\n\n");
    try req.respond(aw.written(), .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

fn servePollServices(req: *http.Server.Request, arena: std.mem.Allocator, io: Io, gpa: std.mem.Allocator, cfg: *const Config) !void {
    const states = try arena.alloc(ServiceReachability, cfg.services.len);
    for (cfg.services, 0..) |svc, i| {
        states[i] = probeService(gpa, io, svc);
    }

    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("event: datastar-patch-elements\ndata: elements ");
    try renderServices(w, cfg.services, states);
    try w.writeAll("\n\n");
    try req.respond(aw.written(), .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

fn renderPage(w: *Io.Writer, io: Io, cfg: *const Config) !void {
    var hostname_buf: [256]u8 = undefined;
    const hostname = readHostname(io, &hostname_buf) catch "unknown";

    var uptime_buf: [64]u8 = undefined;
    const uptime_text = format.uptime(&uptime_buf, readUptime(io) catch 0);

    var i: usize = 0;
    while (i < index_html.len) {
        const rest = index_html[i..];

        if (startsWith(rest, "<h1>heimdash</h1>")) |n| {
            try w.writeAll("<h1>");
            try format.escape(w, hostname);
            try w.writeAll("</h1>");
            i += n;
            continue;
        }

        if (startsWith(rest, "<span id=\"uptime\"></span>")) |n| {
            try w.writeAll("<span id=\"uptime\">");
            try format.escape(w, uptime_text);
            try w.writeAll("</span>");
            i += n;
            continue;
        }

        if (startsWith(rest, "<section id=\"metrics\">")) |_| {
            const end_tag = "</section>";
            const end = std.mem.indexOfPos(u8, index_html, i, end_tag) orelse return error.InvalidIndexHtml;
            try renderMetrics(w, io, cfg);
            i = end + end_tag.len;
            continue;
        }

        if (startsWith(rest, "<ul id=\"services\"></ul>")) |n| {
            try renderServices(w, cfg.services, null);
            i += n;
            continue;
        }

        try w.writeByte(index_html[i]);
        i += 1;
    }
}

fn startsWith(haystack: []const u8, needle: []const u8) ?usize {
    if (haystack.len < needle.len) return null;
    if (!std.mem.eql(u8, haystack[0..needle.len], needle)) return null;
    return needle.len;
}

fn renderServices(w: *Io.Writer, services: []const Service, states: ?[]const ServiceReachability) !void {
    try w.writeAll("<ul id=\"services\">");
    for (services, 0..) |svc, i| {
        const state = if (states) |items| items[i] else .checking;
        try w.writeAll("<li class=\"");
        try w.writeAll(serviceReachabilityClass(state));
        try w.writeAll("\"><a href=\"");
        try format.escape(w, svc.url);
        try w.writeAll("\"><span class=\"service-name\">");
        try format.escape(w, svc.name);
        try w.writeAll("</span><span class=\"service-state\">");
        try w.writeAll(@tagName(state));
        try w.writeAll("</span></a></li>");
    }
    try w.writeAll("</ul>");
}

fn serviceReachabilityClass(state: ServiceReachability) []const u8 {
    return switch (state) {
        .checking => "is-checking",
        .up => "is-up",
        .down => "is-down",
    };
}

fn probeService(gpa: std.mem.Allocator, io: Io, svc: Service) ServiceReachability {
    const target = svc.check orelse svc.url;
    const job = gpa.create(ProbeJob) catch return .down;
    const url = gpa.dupe(u8, target) catch {
        gpa.destroy(job);
        return .down;
    };
    job.* = .{ .allocator = gpa, .io = io, .url = url };

    const thread = std.Thread.spawn(.{}, runProbeJob, .{job}) catch {
        job.release();
        job.release();
        return .down;
    };
    thread.detach();

    const finished = if (job.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } })) true else |_| false;
    const state = if (finished) job.state else .down;
    job.release();
    return state;
}

fn runProbeJob(job: *ProbeJob) void {
    job.state = probeUrl(job.allocator, job.io, job.url);
    job.done.set(job.io);
    job.release();
}

fn probeUrl(gpa: std.mem.Allocator, io: Io, url: []const u8) ServiceReachability {
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

fn renderMetrics(w: *Io.Writer, io: Io, cfg: *const Config) !void {
    const t = cfg.thresholds;
    try w.writeAll("<section id=\"metrics\"><h2>System</h2><ul id=\"system\">");

    const load_opt: ?f64 = readLoadAvg(io) catch null;
    const ncpu = std.Thread.getCpuCount() catch 1;
    var cbuf: [32]u8 = undefined;
    const cpu_pct: ?u64 = if (load_opt) |load|
        @min(100, @as(u64, @intFromFloat(load / @as(f64, @floatFromInt(ncpu)) * 100.0)))
    else
        null;
    const cpu_detail = if (load_opt) |load|
        std.fmt.bufPrint(&cbuf, "load {d:.2}", .{load}) catch "?"
    else
        "load --";
    try renderBarRow(w, "CPU", cpu_pct, cpu_detail, health.classify(cpu_pct, t.cpu));

    const mem = readMemInfo(io) catch MemInfo{ .total = 0, .available = 0 };
    const mem_used = if (mem.total > mem.available) mem.total - mem.available else 0;
    const mem_pct: ?u64 = if (mem.total == 0) null else @min(100, mem_used * 100 / mem.total);
    var mfb: [32]u8 = undefined;
    var mdb: [48]u8 = undefined;
    const mem_detail = if (mem.total == 0)
        "-- free"
    else
        std.fmt.bufPrint(&mdb, "{s} free", .{format.bytes(&mfb, mem.available)}) catch "?";
    try renderBarRow(w, "Memory", mem_pct, mem_detail, health.classify(mem_pct, t.memory));

    try w.writeAll("</ul><h2>Disks</h2><ul id=\"disks\">");
    for (cfg.mounts) |mnt| {
        const fs = readDiskFree(mnt) catch DiskUsage{ .total = 0, .free = 0 };
        const used = if (fs.total > fs.free) fs.total - fs.free else 0;
        const pct: ?u64 = if (fs.total == 0) null else @min(100, used * 100 / fs.total);
        var fbuf: [32]u8 = undefined;
        var dbuf: [48]u8 = undefined;
        const detail = if (fs.total == 0)
            "-- free"
        else
            std.fmt.bufPrint(&dbuf, "{s} free", .{format.bytes(&fbuf, fs.free)}) catch "?";
        try renderBarRow(w, mnt, pct, detail, health.classify(pct, health.diskThresholdFor(t, mnt)));
    }
    try w.writeAll("</ul></section>");
}

fn renderBarRow(w: *Io.Writer, label: []const u8, pct: ?u64, detail: []const u8, state: health.State) !void {
    try w.writeAll("<li class=\"");
    try w.writeAll(health.cssClass(state));
    try w.writeAll("\"><span class=\"label\">");
    try format.escape(w, label);
    try w.print("</span><span class=\"bar\"><span style=\"width:{d}%\"></span></span><span class=\"free\">", .{pct orelse 0});
    try format.escape(w, detail);
    try w.writeAll("</span></li>");
}

fn readHostname(io: Io, buf: []u8) ![]const u8 {
    var file = try Io.Dir.openFileAbsolute(io, "/etc/hostname", .{});
    defer file.close(io);
    var fr = file.reader(io, &.{});
    const n = try fr.interface.readSliceShort(buf);
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

fn readUptime(io: Io) !u64 {
    var buf: [128]u8 = undefined;
    var file = try Io.Dir.openFileAbsolute(io, "/proc/uptime", .{});
    defer file.close(io);
    var fr = file.reader(io, &.{});
    const n = try fr.interface.readSliceShort(&buf);
    const text = buf[0..n];
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const dot = std.mem.indexOfScalar(u8, text[0..space], '.') orelse space;
    return std.fmt.parseInt(u64, text[0..dot], 10) catch 0;
}

fn readLoadAvg(io: Io) !f64 {
    var buf: [128]u8 = undefined;
    var file = try Io.Dir.openFileAbsolute(io, "/proc/loadavg", .{});
    defer file.close(io);
    var fr = file.reader(io, &.{});
    const n = try fr.interface.readSliceShort(&buf);
    const text = buf[0..n];
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return error.BadLoadAvg;
    return std.fmt.parseFloat(f64, text[0..space]);
}

fn readMemInfo(io: Io) !MemInfo {
    var buf: [4096]u8 = undefined;
    var file = try Io.Dir.openFileAbsolute(io, "/proc/meminfo", .{});
    defer file.close(io);
    var fr = file.reader(io, &.{});
    const n = try fr.interface.readSliceShort(&buf);
    const text = buf[0..n];
    return .{
        .total = format.parseMemKb(text, "MemTotal:") * 1024,
        .available = format.parseMemKb(text, "MemAvailable:") * 1024,
    };
}

fn readDiskFree(path: []const u8) !DiskUsage {
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
