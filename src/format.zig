const std = @import("std");
const Io = std.Io;

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
