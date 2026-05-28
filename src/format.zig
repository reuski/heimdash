const std = @import("std");
const Io = std.Io;

pub const download_marker = "\u{25BE}";
pub const upload_marker = "\u{25B4}";

pub fn bytes(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    var value: f64 = @floatFromInt(n);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) : (unit += 1) value /= 1024.0;
    const result = if (unit == 0)
        std.fmt.bufPrint(buf, "{d:.0} {s}", .{ value, units[unit] })
    else
        std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] });
    return result catch "?";
}

pub fn bytesPerSecond(buf: []u8, n: u64) []const u8 {
    var bytes_buf: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/s", .{bytes(&bytes_buf, n)}) catch "?/s";
}

pub fn compactBytesPerSecond(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "K", "M", "G", "T", "P" };
    var value: f64 = @floatFromInt(n);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) : (unit += 1) value /= 1024.0;
    const result = if (unit == 0)
        std.fmt.bufPrint(buf, "{d:.0}{s}/s", .{ value, units[unit] })
    else
        std.fmt.bufPrint(buf, "{d:.1}{s}/s", .{ value, units[unit] });
    return result catch "?/s";
}

pub fn transferSpeeds(w: *Io.Writer, down: u64, up: u64) !void {
    var down_buf: [24]u8 = undefined;
    var up_buf: [24]u8 = undefined;
    try w.print("{s} {s} {s} {s}", .{
        download_marker,
        compactBytesPerSecond(&down_buf, down),
        upload_marker,
        compactBytesPerSecond(&up_buf, up),
    });
}

pub fn milliCelsius(buf: []u8, milli: i64) []const u8 {
    const negative = milli < 0;
    const abs: u64 = @intCast(if (negative) -milli else milli);
    const whole = abs / 1000;
    const tenth = (abs % 1000) / 100;
    const sign = if (negative) "-" else "";
    return std.fmt.bufPrint(buf, "{s}{d}.{d} C", .{ sign, whole, tenth }) catch "? C";
}

pub fn uptime(buf: []u8, seconds: u64) []const u8 {
    if (seconds == 0) return std.fmt.bufPrint(buf, "uptime unknown", .{}) catch "uptime unknown";
    const days = seconds / 86_400;
    const hours = (seconds % 86_400) / 3_600;
    const mins = (seconds % 3_600) / 60;
    return std.fmt.bufPrint(buf, "up {d}d {d}h {d}m", .{ days, hours, mins }) catch "up";
}

pub fn parseMemKb(text: []const u8, key: []const u8) u64 {
    const idx = std.mem.indexOf(u8, text, key) orelse return 0;
    const rest = std.mem.trimStart(u8, text[idx + key.len ..], " \t");
    const end = std.mem.indexOfAny(u8, rest, " \t\n") orelse rest.len;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch 0;
}

pub fn escape(w: *Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

test "bytes scales units" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", bytes(&buf, 0));
    try std.testing.expectEqualStrings("512 B", bytes(&buf, 512));
    try std.testing.expectEqualStrings("1.0 KiB", bytes(&buf, 1024));
    try std.testing.expectEqualStrings("1.5 KiB", bytes(&buf, 1536));
    try std.testing.expectEqualStrings("1.0 GiB", bytes(&buf, 1024 * 1024 * 1024));
}

test "bytesPerSecond appends rate suffix" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("0 B/s", bytesPerSecond(&buf, 0));
    try std.testing.expectEqualStrings("1.0 KiB/s", bytesPerSecond(&buf, 1024));
}

test "compactBytesPerSecond uses short rate units" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0B/s", compactBytesPerSecond(&buf, 0));
    try std.testing.expectEqualStrings("512B/s", compactBytesPerSecond(&buf, 512));
    try std.testing.expectEqualStrings("1.0K/s", compactBytesPerSecond(&buf, 1024));
    try std.testing.expectEqualStrings("1.5M/s", compactBytesPerSecond(&buf, 1536 * 1024));
}

test "transferSpeeds writes compact down and up markers" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try transferSpeeds(&aw.writer, 1048576, 2048);
    try std.testing.expectEqualStrings("\u{25BE} 1.0M/s \u{25B4} 2.0K/s", aw.written());
}

test "milliCelsius formats tenths" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("42.1 C", milliCelsius(&buf, 42123));
    try std.testing.expectEqualStrings("-5.0 C", milliCelsius(&buf, -5000));
}

test "uptime formats days, hours, minutes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("uptime unknown", uptime(&buf, 0));
    try std.testing.expectEqualStrings("up 0d 0h 1m", uptime(&buf, 60));
    try std.testing.expectEqualStrings("up 1d 1h 1m", uptime(&buf, 86_400 + 3_600 + 60));
}

test "parseMemKb reads the keyed kibibytes" {
    const text = "MemTotal:       16307200 kB\nMemAvailable:    8000000 kB\n";
    try std.testing.expectEqual(@as(u64, 16307200), parseMemKb(text, "MemTotal:"));
    try std.testing.expectEqual(@as(u64, 8000000), parseMemKb(text, "MemAvailable:"));
    try std.testing.expectEqual(@as(u64, 0), parseMemKb(text, "Missing:"));
}

test "escape replaces html-sensitive bytes" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try escape(&aw.writer, "<a href=\"x\">&'");
    try std.testing.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;&amp;&#39;", aw.written());
}
