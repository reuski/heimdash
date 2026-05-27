const std = @import("std");
const Io = std.Io;

const format = @import("format.zig");
const health = @import("health.zig");

pub const ServiceCard = struct {
    name: []const u8,
    url: []const u8,
};

pub const ServiceReachability = enum { checking, up, down };

pub const ServiceSummary = struct {
    text: []const u8 = "",
};

pub const DiskUsage = struct { total: u64, free: u64 };
pub const MemInfo = struct { total: u64, available: u64 };

pub const MetricRow = struct {
    label: []const u8,
    percent: ?u64,
    detail: []const u8,
    state: health.State,
};

pub const Metrics = struct {
    cpu: MetricRow,
    memory: MetricRow,
    disks: []const MetricRow,
};

pub const Services = struct {
    items: []const ServiceCard,
    states: ?[]const ServiceReachability = null,
    summaries: ?[]const ServiceSummary = null,
};

pub const Page = struct {
    hostname: []const u8,
    uptime: []const u8,
    metrics: Metrics,
    services: Services,
};

pub fn page(w: *Io.Writer, template: []const u8, data: Page) !void {
    var i: usize = 0;
    while (i < template.len) {
        const rest = template[i..];

        if (startsWith(rest, "<h1>heimdash</h1>")) |n| {
            try w.writeAll("<h1>");
            try format.escape(w, data.hostname);
            try w.writeAll("</h1>");
            i += n;
            continue;
        }

        if (startsWith(rest, "<span id=\"uptime\"></span>")) |n| {
            try w.writeAll("<span id=\"uptime\">");
            try format.escape(w, data.uptime);
            try w.writeAll("</span>");
            i += n;
            continue;
        }

        if (startsWith(rest, "<section id=\"metrics\">")) |_| {
            const end_tag = "</section>";
            const end = std.mem.indexOfPos(u8, template, i, end_tag) orelse return error.InvalidIndexHtml;
            try metrics(w, data.metrics);
            i = end + end_tag.len;
            continue;
        }

        if (startsWith(rest, "<ul id=\"services\"></ul>")) |n| {
            try services(w, data.services);
            i += n;
            continue;
        }

        try w.writeByte(template[i]);
        i += 1;
    }
}

pub fn metrics(w: *Io.Writer, data: Metrics) !void {
    try w.writeAll("<section id=\"metrics\"><h2>System</h2><ul id=\"system\">");
    try metricRow(w, data.cpu);
    try metricRow(w, data.memory);
    try w.writeAll("</ul><h2>Disks</h2><ul id=\"disks\">");
    for (data.disks) |row| try metricRow(w, row);
    try w.writeAll("</ul></section>");
}

pub fn services(w: *Io.Writer, data: Services) !void {
    try w.writeAll("<ul id=\"services\">");
    for (data.items, 0..) |svc, i| {
        const state = if (data.states) |items| items[i] else .checking;
        const summary_text = if (data.summaries) |items| items[i].text else "";
        try w.writeAll("<li class=\"");
        try w.writeAll(serviceReachabilityClass(state));
        try w.writeAll("\"><a href=\"");
        try format.escape(w, svc.url);
        try w.writeAll("\"><span class=\"service-name\">");
        try format.escape(w, svc.name);
        try w.writeAll("</span><span class=\"service-summary\">");
        try format.escape(w, summary_text);
        try w.writeAll("</span><span class=\"service-state\">");
        try w.writeAll(@tagName(state));
        try w.writeAll("</span></a></li>");
    }
    try w.writeAll("</ul>");
}

fn startsWith(haystack: []const u8, needle: []const u8) ?usize {
    if (haystack.len < needle.len) return null;
    if (!std.mem.eql(u8, haystack[0..needle.len], needle)) return null;
    return needle.len;
}

fn serviceReachabilityClass(state: ServiceReachability) []const u8 {
    return switch (state) {
        .checking => "is-checking",
        .up => "is-up",
        .down => "is-down",
    };
}

fn metricRow(w: *Io.Writer, row: MetricRow) !void {
    try w.writeAll("<li class=\"");
    try w.writeAll(health.cssClass(row.state));
    try w.writeAll("\"><span class=\"label\">");
    try format.escape(w, row.label);
    try w.print("</span><span class=\"bar\"><span style=\"width:{d}%\"></span></span><span class=\"free\">", .{row.percent orelse 0});
    try format.escape(w, row.detail);
    try w.writeAll("</span></li>");
}

test "service card rendering preserves state summary and escaping" {
    const service_items = [_]ServiceCard{.{ .name = "NAS <main>", .url = "http://nas.invalid/?q=\"status\"" }};
    const states = [_]ServiceReachability{.up};
    const summaries = [_]ServiceSummary{.{ .text = "v1 & idle" }};
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try services(&aw.writer, .{ .items = &service_items, .states = &states, .summaries = &summaries });

    try std.testing.expectEqualStrings(
        "<ul id=\"services\"><li class=\"is-up\"><a href=\"http://nas.invalid/?q=&quot;status&quot;\"><span class=\"service-name\">NAS &lt;main&gt;</span><span class=\"service-summary\">v1 &amp; idle</span><span class=\"service-state\">up</span></a></li></ul>",
        aw.written(),
    );
}

test "service card defaults to checking without summaries" {
    const service_items = [_]ServiceCard{.{ .name = "Jellyfin", .url = "http://jellyfin.invalid" }};
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try services(&aw.writer, .{ .items = &service_items });

    try std.testing.expectEqualStrings(
        "<ul id=\"services\"><li class=\"is-checking\"><a href=\"http://jellyfin.invalid\"><span class=\"service-name\">Jellyfin</span><span class=\"service-summary\"></span><span class=\"service-state\">checking</span></a></li></ul>",
        aw.written(),
    );
}

test "metric row rendering preserves classes width and escaping" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try metricRow(&aw.writer, .{
        .label = "Disk <root>",
        .percent = null,
        .detail = "-- free",
        .state = .unknown,
    });

    try std.testing.expectEqualStrings(
        "<li class=\"is-unknown\"><span class=\"label\">Disk &lt;root&gt;</span><span class=\"bar\"><span style=\"width:0%\"></span></span><span class=\"free\">-- free</span></li>",
        aw.written(),
    );
}

test "metrics rendering preserves morph targets" {
    const disks = [_]MetricRow{.{
        .label = "/srv",
        .percent = 42,
        .detail = "58.0 GiB free",
        .state = .ok,
    }};
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try metrics(&aw.writer, .{
        .cpu = .{ .label = "CPU", .percent = 12, .detail = "load 0.25", .state = .ok },
        .memory = .{ .label = "Memory", .percent = 75, .detail = "1.0 GiB free", .state = .warn },
        .disks = &disks,
    });

    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "<section id=\"metrics\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<ul id=\"system\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<ul id=\"disks\">") != null);
}
