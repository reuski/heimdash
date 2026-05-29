const std = @import("std");
const Io = std.Io;

const format = @import("format.zig");
const health = @import("health.zig");
const metric = @import("metric.zig");

pub const ServiceCard = struct {
    name: []const u8,
    url: []const u8,
};

pub const ServiceReachability = enum { checking, up, down };

pub const ServiceSummary = struct {
    text: []const u8 = "",
};

pub const MetricRow = metric.Row;
pub const Metrics = metric.Snapshot;

const meter_cell_count = 64;

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
    try w.writeAll("<section id=\"metrics\">");
    for (data.sections) |section| {
        try w.writeAll("<h2>");
        try format.escape(w, section.title);
        try w.writeAll("</h2><ul id=\"");
        try format.escape(w, section.id);
        try w.writeAll("\">");
        for (section.rows) |row| try metricRow(w, row);
        try w.writeAll("</ul>");
    }
    try w.writeAll("</section>");
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
    try w.writeAll("</span>");
    try metricBar(w, row);
    try w.writeAll("<span class=\"free\">");
    try format.escape(w, row.detail);
    try w.writeAll("</span></li>");
}

fn metricBar(w: *Io.Writer, row: MetricRow) !void {
    if (row.segments.len == 0) {
        try w.writeAll("<span class=\"bar is-led\">");
        try meterRow(w, "is-single", row.percent orelse 0);
        try meterRow(w, "is-single", row.percent orelse 0);
        try w.writeAll("</span>");
        return;
    }

    try w.writeAll("<span class=\"bar is-led is-split\">");
    for (row.segments) |segment| {
        try meterRow(w, signalClass(segment.signal), segment.percent);
    }
    try w.writeAll("</span>");
}

fn meterRow(w: *Io.Writer, class: []const u8, percent: u64) !void {
    const lit = litCellCount(percent);
    try w.print("<span class=\"meter-row {s}\">", .{class});
    for (0..meter_cell_count) |i| {
        if (i < lit) {
            try w.writeAll("<span class=\"led is-lit\"></span>");
        } else {
            try w.writeAll("<span class=\"led\"></span>");
        }
    }
    try w.writeAll("</span>");
}

fn litCellCount(percent: u64) usize {
    const pct = @min(percent, 100);
    return @intCast((@as(u128, pct) * meter_cell_count + 99) / 100);
}

fn signalClass(signal: metric.Signal) []const u8 {
    return switch (signal) {
        .down => "is-down",
        .up => "is-up",
    };
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

    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "<li class=\"is-unknown\"><span class=\"label\">Disk &lt;root&gt;</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"bar is-led\">") != null);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(html, "meter-row is-single"));
    try std.testing.expectEqual(@as(usize, meter_cell_count * 2), countOccurrences(html, "class=\"led"));
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"free\">-- free</span></li>") != null);
}

test "metric row rendering supports split meter segments" {
    const segments = [_]metric.Segment{
        .{ .signal = .down, .percent = 12 },
        .{ .signal = .up, .percent = 4 },
    };
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try metricRow(&aw.writer, .{
        .label = "Network",
        .percent = null,
        .detail = "\u{25BE} 1.0M/s \u{25B4} 512B/s",
        .state = .ok,
        .segments = &segments,
    });

    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"bar is-led is-split\">") != null);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(html, "meter-row is-down"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(html, "meter-row is-up"));
    try std.testing.expectEqual(@as(usize, meter_cell_count * 2), countOccurrences(html, "class=\"led"));
    try std.testing.expectEqual(@as(usize, 11), countOccurrences(html, "class=\"led is-lit\""));
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"free\">\u{25BE} 1.0M/s \u{25B4} 512B/s</span></li>") != null);
}

test "meter cell counts round up visible values and cap at full scale" {
    try std.testing.expectEqual(@as(usize, 0), litCellCount(0));
    try std.testing.expectEqual(@as(usize, 1), litCellCount(1));
    try std.testing.expectEqual(@as(usize, 32), litCellCount(50));
    try std.testing.expectEqual(@as(usize, meter_cell_count), litCellCount(100));
    try std.testing.expectEqual(@as(usize, meter_cell_count), litCellCount(120));
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |idx| {
        count += 1;
        i = idx + needle.len;
    }
    return count;
}

test "metrics rendering preserves morph targets" {
    const system = [_]MetricRow{
        .{ .label = "CPU", .percent = 12, .detail = "load 0.25", .state = .ok },
        .{ .label = "Memory", .percent = 75, .detail = "1.0 GiB free", .state = .warn },
    };
    const disks = [_]MetricRow{.{
        .label = "/srv",
        .percent = 42,
        .detail = "58.0 GiB free",
        .state = .ok,
    }};
    const sections = [_]metric.Section{
        .{ .id = "system", .title = "System", .rows = &system },
        .{ .id = "disks", .title = "Disks", .rows = &disks },
    };
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try metrics(&aw.writer, .{ .sections = &sections });

    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "<section id=\"metrics\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<ul id=\"system\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<ul id=\"disks\">") != null);
}
