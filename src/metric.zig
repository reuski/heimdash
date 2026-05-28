const std = @import("std");

const health = @import("health.zig");

pub const Signal = enum { down, up };

pub const Segment = struct {
    signal: Signal,
    percent: u64,
};

pub const Row = struct {
    label: []const u8,
    percent: ?u64,
    detail: []const u8,
    state: health.State,
    history: []const ?u64 = &.{},
    segments: []const Segment = &.{},
};

pub const Section = struct {
    id: []const u8,
    title: []const u8,
    rows: []const Row,
};

pub const Snapshot = struct {
    sections: []const Section,
};

pub fn usedPercent(total: u64, free: u64) ?u64 {
    if (total == 0) return null;
    const used = if (total > free) total - free else 0;
    return @min(100, used * 100 / total);
}

pub fn scaledPercent(value: u64, limit: u64) ?u64 {
    if (limit == 0) return null;
    return @min(100, @as(u64, @intCast(@as(u128, value) * 100 / limit)));
}

pub fn relativePercent(value: u64, max_value: u64) u64 {
    if (max_value == 0) return 0;
    return @min(100, @as(u64, @intCast(@as(u128, value) * 100 / max_value)));
}

pub fn ratePerSecond(previous: u64, current: u64, elapsed_ns: i96) u64 {
    if (elapsed_ns <= 0 or current <= previous) return 0;
    const bytes = @as(u128, current - previous);
    const elapsed = @as(u128, @intCast(elapsed_ns));
    const rate = bytes * std.time.ns_per_s / elapsed;
    return @intCast(@min(rate, std.math.maxInt(u64)));
}

test "usedPercent handles empty and full totals" {
    try std.testing.expectEqual(@as(?u64, null), usedPercent(0, 0));
    try std.testing.expectEqual(@as(?u64, 0), usedPercent(100, 100));
    try std.testing.expectEqual(@as(?u64, 25), usedPercent(100, 75));
    try std.testing.expectEqual(@as(?u64, 100), usedPercent(100, 0));
}

test "scaledPercent caps values" {
    try std.testing.expectEqual(@as(?u64, null), scaledPercent(10, 0));
    try std.testing.expectEqual(@as(?u64, 50), scaledPercent(40, 80));
    try std.testing.expectEqual(@as(?u64, 100), scaledPercent(90, 80));
}

test "relativePercent scales against observed maximum" {
    try std.testing.expectEqual(@as(u64, 0), relativePercent(0, 0));
    try std.testing.expectEqual(@as(u64, 25), relativePercent(5, 20));
    try std.testing.expectEqual(@as(u64, 100), relativePercent(25, 20));
}

test "ratePerSecond computes monotonic counter deltas" {
    try std.testing.expectEqual(@as(u64, 0), ratePerSecond(100, 99, std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 0), ratePerSecond(100, 200, 0));
    try std.testing.expectEqual(@as(u64, 100), ratePerSecond(100, 200, std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 200), ratePerSecond(100, 200, std.time.ns_per_s / 2));
}
