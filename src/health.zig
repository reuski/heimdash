const std = @import("std");

pub const Thresholds = struct {
    warn: u8 = 80,
    critical: u8 = 90,
};

pub const MountThreshold = struct {
    mount: []const u8,
    warn: u8 = 80,
    critical: u8 = 90,
};

pub const Config = struct {
    cpu: Thresholds = .{ .warn = 75, .critical = 90 },
    memory: Thresholds = .{ .warn = 80, .critical = 90 },
    disk: Thresholds = .{ .warn = 80, .critical = 90 },
    disks: []const MountThreshold = &.{},
    temperature: Thresholds = .{ .warn = 75, .critical = 85 },
};

pub const State = enum { ok, warn, critical, unknown };

pub fn classify(pct: ?u64, t: Thresholds) State {
    const p = pct orelse return .unknown;
    if (p >= @as(u64, t.critical)) return .critical;
    if (p >= @as(u64, t.warn)) return .warn;
    return .ok;
}

pub fn diskThresholdFor(cfg: Config, mount: []const u8) Thresholds {
    for (cfg.disks) |d| {
        if (std.mem.eql(u8, d.mount, mount)) return .{ .warn = d.warn, .critical = d.critical };
    }
    return cfg.disk;
}

pub fn cssClass(state: State) []const u8 {
    return switch (state) {
        .ok => "is-ok",
        .warn => "is-warn",
        .critical => "is-critical",
        .unknown => "is-unknown",
    };
}

test "classify maps percentages to states" {
    const t: Thresholds = .{ .warn = 80, .critical = 90 };
    try std.testing.expectEqual(State.unknown, classify(null, t));
    try std.testing.expectEqual(State.ok, classify(0, t));
    try std.testing.expectEqual(State.ok, classify(79, t));
    try std.testing.expectEqual(State.warn, classify(80, t));
    try std.testing.expectEqual(State.warn, classify(89, t));
    try std.testing.expectEqual(State.critical, classify(90, t));
    try std.testing.expectEqual(State.critical, classify(100, t));
}

test "diskThresholdFor prefers per-mount override then disk default" {
    const overrides = [_]MountThreshold{.{ .mount = "/mnt/media", .warn = 90, .critical = 97 }};
    const cfg: Config = .{ .disks = &overrides };
    try std.testing.expectEqual(@as(u8, 90), diskThresholdFor(cfg, "/mnt/media").warn);
    try std.testing.expectEqual(@as(u8, 97), diskThresholdFor(cfg, "/mnt/media").critical);
    try std.testing.expectEqual(@as(u8, 80), diskThresholdFor(cfg, "/").warn);
    try std.testing.expectEqual(@as(u8, 90), diskThresholdFor(cfg, "/").critical);
}

test "Config parses with defaulted and partial fields" {
    const json =
        \\{ "cpu": { "warn": 60 }, "disks": [ { "mount": "/srv", "warn": 95, "critical": 99 } ] }
    ;
    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const cfg = parsed.value;
    try std.testing.expectEqual(@as(u8, 60), cfg.cpu.warn);
    try std.testing.expectEqual(@as(u8, 90), cfg.cpu.critical);
    try std.testing.expectEqual(@as(u8, 80), cfg.memory.warn);
    try std.testing.expectEqual(@as(u8, 95), diskThresholdFor(cfg, "/srv").warn);
    try std.testing.expectEqual(@as(u8, 99), diskThresholdFor(cfg, "/srv").critical);
    try std.testing.expectEqual(@as(u8, 75), cfg.temperature.warn);
    try std.testing.expectEqual(@as(u8, 85), cfg.temperature.critical);
}

test "cssClass covers every state" {
    try std.testing.expectEqualStrings("is-ok", cssClass(.ok));
    try std.testing.expectEqualStrings("is-warn", cssClass(.warn));
    try std.testing.expectEqualStrings("is-critical", cssClass(.critical));
    try std.testing.expectEqualStrings("is-unknown", cssClass(.unknown));
}
