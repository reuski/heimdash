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
    try w.writeAll("</span><span class=\"gauge\">");
    try sparkline(w, row);
    try metricBar(w, row);
    try w.writeAll("</span><span class=\"free\">");
    try format.escape(w, row.detail);
    try w.writeAll("</span></li>");
}

fn metricBar(w: *Io.Writer, row: MetricRow) !void {
    try w.writeAll("<span class=\"bar\">");
    if (row.segments.len == 0) {
        try meter(w, "", row.percent orelse 0);
    } else for (row.segments) |segment| {
        try meter(w, signalClass(segment.signal), segment.percent);
    }
    try w.writeAll("</span>");
}

fn meter(w: *Io.Writer, class: []const u8, percent: u64) !void {
    try w.print("<span class=\"meter{s}\" style=\"--pct:{d}%\"></span>", .{ class, @min(percent, 100) });
}

const spark_resolution = 120;

const SparkBucket = struct { lo: u64, hi: u64, mean: u64 };

fn sparkline(w: *Io.Writer, row: MetricRow) !void {
    const fixed_domain = row.percent != null and !row.spark_relative;
    const count = @min(row.history.len, spark_resolution);
    var buckets: [spark_resolution]?SparkBucket = undefined;
    sparkBuckets(row.history, buckets[0..count]);
    const span = if (count > 1) count - 1 else 1;
    try w.print("<span class=\"spark\"><svg class=\"spark-svg\" viewBox=\"0 0 {d} 100\" preserveAspectRatio=\"none\" aria-hidden=\"true\">", .{span});
    if (count > 1) {
        const ceiling: u64 = if (fixed_domain) 100 else @max(1, sparkCeiling(buckets[0..count]));
        try sparkTrace(w, buckets[0..count], ceiling);
    }
    try w.writeAll("</svg></span>");
}

fn sparkBuckets(history: []const ?u64, buckets: []?SparkBucket) void {
    for (buckets, 0..) |*bucket, k| {
        const lo = k * history.len / buckets.len;
        const hi = (k + 1) * history.len / buckets.len;
        var min_value: u64 = std.math.maxInt(u64);
        var max_value: u64 = 0;
        var sum: u128 = 0;
        var count: u64 = 0;
        for (history[lo..hi]) |sample| {
            if (sample) |value| {
                min_value = @min(min_value, value);
                max_value = @max(max_value, value);
                sum += value;
                count += 1;
            }
        }
        bucket.* = if (count == 0) null else .{ .lo = min_value, .hi = max_value, .mean = @intCast(sum / count) };
    }
}

fn sparkCeiling(buckets: []const ?SparkBucket) u64 {
    var result: u64 = 0;
    for (buckets) |maybe| {
        if (maybe) |bucket| result = @max(result, bucket.hi);
    }
    return result;
}

fn sparkTrace(w: *Io.Writer, buckets: []const ?SparkBucket, ceiling: u64) !void {
    var i: usize = 0;
    while (i < buckets.len) {
        if (buckets[i] == null) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < buckets.len and buckets[i] != null) : (i += 1) {}
        const run = buckets[start..i];
        if (run.len < 2) continue;
        try sparkBand(w, run, start, ceiling);
        try sparkMeanLine(w, run, start, ceiling);
    }
}

fn sparkBand(w: *Io.Writer, run: []const ?SparkBucket, start: usize, ceiling: u64) !void {
    var has_range = false;
    for (run) |maybe| {
        const bucket = maybe.?;
        if (bucket.hi != bucket.lo) {
            has_range = true;
            break;
        }
    }
    if (!has_range) return;

    try w.writeAll("<polygon class=\"spark-band\" points=\"");
    for (run, start..) |maybe, x| {
        if (x != start) try w.writeByte(' ');
        try w.print("{d},{d}", .{ x, 100 - metric.relativePercent(maybe.?.hi, ceiling) });
    }
    var j = run.len;
    while (j > 0) {
        j -= 1;
        try w.print(" {d},{d}", .{ start + j, 100 - metric.relativePercent(run[j].?.lo, ceiling) });
    }
    try w.writeAll("\" />");
}

fn sparkMeanLine(w: *Io.Writer, run: []const ?SparkBucket, start: usize, ceiling: u64) !void {
    try w.writeAll("<polyline class=\"spark-line\" points=\"");
    for (run, start..) |maybe, x| {
        if (x != start) try w.writeByte(' ');
        try w.print("{d},{d}", .{ x, 100 - metric.relativePercent(maybe.?.mean, ceiling) });
    }
    try w.writeAll("\" />");
}

fn signalClass(signal: metric.Signal) []const u8 {
    return switch (signal) {
        .down => " is-down",
        .up => " is-up",
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
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"bar\"><span class=\"meter\" style=\"--pct:0%\"></span></span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"free\">-- free</span></li>") != null);
}

test "metric meter renders the percent custom property and caps at full scale" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try metricRow(&aw.writer, .{ .label = "CPU", .percent = 120, .detail = "load 9.99", .state = .critical });

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "<span class=\"meter\" style=\"--pct:100%\"></span>") != null);
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
        .detail = "\u{25BC} 1.0M/s \u{25B2} 512B/s",
        .state = .ok,
        .segments = &segments,
    });

    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "<span class=\"bar\"><span class=\"meter is-down\" style=\"--pct:12%\"></span><span class=\"meter is-up\" style=\"--pct:4%\"></span></span>",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"free\">\u{25BC} 1.0M/s \u{25B2} 512B/s</span></li>") != null);
}

test "sparkline emits an empty svg wrapper when history is too short to plot" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try sparkline(&aw.writer, .{ .label = "CPU", .percent = 50, .detail = "", .state = .ok });

    try std.testing.expectEqualStrings(
        "<span class=\"spark\"><svg class=\"spark-svg\" viewBox=\"0 0 1 100\" preserveAspectRatio=\"none\" aria-hidden=\"true\"></svg></span>",
        aw.written(),
    );
}

test "sparkline inverts y over a fixed percent domain" {
    const history = [_]?u64{ 0, 50, 100 };
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try sparkline(&aw.writer, .{ .label = "CPU", .percent = 50, .detail = "", .state = .ok, .history = &history });

    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "viewBox=\"0 0 2 100\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<polyline class=\"spark-line\" points=\"0,100 1,50 2,0\" />") != null);
}

test "sparkline relative-scales rows that lack a fixed percent domain" {
    const history = [_]?u64{ 200, 400, 800 };
    const cases = [_]MetricRow{
        .{ .label = "Network", .percent = null, .detail = "", .state = .ok, .history = &history },
        .{ .label = "/srv", .percent = 42, .detail = "", .state = .ok, .history = &history, .spark_relative = true },
    };

    for (cases) |row| {
        var aw: Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try sparkline(&aw.writer, row);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "points=\"0,75 1,50 2,0\"") != null);
    }
}

test "sparkline splits the trace into segments across gaps and drops lone samples" {
    const history = [_]?u64{ 10, 20, null, 30, null, 40, 50 };
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try sparkline(&aw.writer, .{ .label = "CPU", .percent = 50, .detail = "", .state = .ok, .history = &history });

    const html = aw.written();
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(html, "<polyline"));
    try std.testing.expect(std.mem.indexOf(u8, html, "points=\"0,90 1,80\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "points=\"5,60 6,50\"") != null);
}

test "sparkBuckets reduces samples to min, max, and mean and marks empty buckets as gaps" {
    const history = [_]?u64{ 10, 20, null, 40, 60, 80 };
    var buckets: [3]?SparkBucket = undefined;

    sparkBuckets(&history, &buckets);

    try std.testing.expectEqual(@as(?SparkBucket, .{ .lo = 10, .hi = 20, .mean = 15 }), buckets[0]);
    try std.testing.expectEqual(@as(?SparkBucket, .{ .lo = 40, .hi = 40, .mean = 40 }), buckets[1]);
    try std.testing.expectEqual(@as(?SparkBucket, .{ .lo = 60, .hi = 80, .mean = 70 }), buckets[2]);
}

test "sparkline draws a min/max envelope band under the mean line for aggregated buckets" {
    var history: [spark_resolution * 2]?u64 = undefined;
    for (&history, 0..) |*sample, i| sample.* = if (i % 2 == 0) @as(u64, 20) else 80;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try sparkline(&aw.writer, .{ .label = "CPU", .percent = 50, .detail = "", .state = .ok, .history = &history });

    const html = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "viewBox=\"0 0 119 100\"") != null);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(html, "<polygon class=\"spark-band\""));
    const band = html[std.mem.indexOf(u8, html, "<polygon").?..];
    try std.testing.expect(std.mem.indexOf(u8, band, "0,20") != null);
    try std.testing.expect(std.mem.indexOf(u8, band, "0,80") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<polyline class=\"spark-line\" points=\"0,50 1,50") != null);
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

test "page splices host data into the template and preserves morph targets" {
    const template = "<head></head><h1>heimdash</h1><span id=\"uptime\"></span>" ++
        "<section id=\"metrics\"><ul id=\"disks\"></ul></section><ul id=\"services\"></ul><footer></footer>";
    const rows = [_]MetricRow{.{ .label = "CPU", .percent = 12, .detail = "load 0.25", .state = .ok }};
    const sections = [_]metric.Section{.{ .id = "system", .title = "System", .rows = &rows }};
    const service_items = [_]ServiceCard{.{ .name = "Jellyfin", .url = "http://jellyfin.invalid" }};
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try page(&aw.writer, template, .{
        .hostname = "argos<1>",
        .uptime = "up 1d 2h 3m",
        .metrics = .{ .sections = &sections },
        .services = .{ .items = &service_items },
    });

    const html = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, html, "<head></head><h1>argos&lt;1&gt;</h1>"));
    try std.testing.expect(std.mem.indexOf(u8, html, "<span id=\"uptime\">up 1d 2h 3m</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<section id=\"metrics\"><h2>System</h2><ul id=\"system\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<ul id=\"services\">") != null);
    try std.testing.expect(std.mem.endsWith(u8, html, "<footer></footer>"));
}

test "page rejects a template whose metrics section never closes" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try std.testing.expectError(error.InvalidIndexHtml, page(&aw.writer, "<section id=\"metrics\">", .{
        .hostname = "argos",
        .uptime = "up 0d 0h 1m",
        .metrics = .{ .sections = &.{} },
        .services = .{ .items = &.{} },
    }));
}
