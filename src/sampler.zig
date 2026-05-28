const std = @import("std");
const Io = std.Io;

const format = @import("format.zig");
const health = @import("health.zig");
const host = @import("host.zig");
const metric = @import("metric.zig");

pub const history_capacity = 120;

pub const Config = struct {
    mounts: []const []const u8,
    thresholds: health.Config,
    network_interface: ?[]const u8 = null,
};

pub const Sampler = struct {
    allocator: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    histories: []History,
    last_network: ?TimedNetwork = null,

    const cpu_index = 0;
    const memory_index = 1;
    const temperature_index = 2;
    const network_down_index = 3;
    const network_up_index = 4;
    const disk_start_index = 5;
    const system_row_count = 4;

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Sampler {
        const histories = try allocator.alloc(History, disk_start_index + cfg.mounts.len);
        for (histories) |*history| history.* = .{};
        return .{ .allocator = allocator, .histories = histories };
    }

    pub fn deinit(self: *Sampler) void {
        self.allocator.free(self.histories);
    }

    pub fn snapshot(self: *Sampler, arena: std.mem.Allocator, io: Io, cfg: Config) !metric.Snapshot {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const system_rows = try arena.alloc(metric.Row, system_row_count);
        const disks = try arena.alloc(metric.Row, cfg.mounts.len);
        const now = Io.Timestamp.now(io, .awake);

        system_rows[0] = try self.cpuRow(arena, io, cfg.thresholds.cpu);
        system_rows[1] = try usageRow(
            arena,
            &self.histories[memory_index],
            "Memory",
            memoryUsage(io) catch null,
            cfg.thresholds.memory,
        );
        system_rows[2] = try self.temperatureRow(arena, io, cfg.thresholds.temperature);
        system_rows[3] = try self.networkRow(arena, io, cfg.network_interface, now);

        for (cfg.mounts, 0..) |mount, i| {
            disks[i] = try usageRow(
                arena,
                &self.histories[disk_start_index + i],
                mount,
                diskUsage(mount) catch null,
                health.diskThresholdFor(cfg.thresholds, mount),
            );
        }

        const sections = try arena.alloc(metric.Section, 2);
        sections[0] = .{ .id = "system", .title = "System", .rows = system_rows };
        sections[1] = .{ .id = "disks", .title = "Disks", .rows = disks };
        return .{ .sections = sections };
    }

    fn cpuRow(self: *Sampler, arena: std.mem.Allocator, io: Io, thresholds: health.Thresholds) !metric.Row {
        const load = host.loadAverage(io) catch return unknownRow(arena, &self.histories[cpu_index], "CPU", "load --");
        const ncpu = std.Thread.getCpuCount() catch return unknownRow(arena, &self.histories[cpu_index], "CPU", "load --");
        const pct: u64 = @min(100, @as(u64, @intFromFloat(load / @as(f64, @floatFromInt(ncpu)) * 100.0)));
        return .{
            .label = "CPU",
            .percent = pct,
            .detail = try std.fmt.allocPrint(arena, "load {d:.2}", .{load}),
            .state = health.classify(pct, thresholds),
            .history = try self.histories[cpu_index].pushSnapshot(arena, pct),
        };
    }

    fn usageRow(
        arena: std.mem.Allocator,
        history: *History,
        label: []const u8,
        usage: ?Usage,
        thresholds: health.Thresholds,
    ) !metric.Row {
        const value = usage orelse return unknownRow(arena, history, label, "-- free");
        const pct = metric.usedPercent(value.total, value.free);
        var buf: [32]u8 = undefined;
        return .{
            .label = label,
            .percent = pct,
            .detail = try std.fmt.allocPrint(arena, "{s} free", .{format.bytes(&buf, value.free)}),
            .state = health.classify(pct, thresholds),
            .history = try history.pushSnapshot(arena, pct),
        };
    }

    fn temperatureRow(self: *Sampler, arena: std.mem.Allocator, io: Io, thresholds: health.Thresholds) !metric.Row {
        const temp_milli = host.temperature(io) catch return unknownRow(arena, &self.histories[temperature_index], "Temp", "-- C");
        const temp_celsius: u64 = @intCast(@max(@as(i64, 0), @divTrunc(temp_milli, 1000)));
        var buf: [32]u8 = undefined;
        return .{
            .label = "Temp",
            .percent = metric.scaledPercent(temp_celsius, thresholds.critical),
            .detail = try arena.dupe(u8, format.milliCelsius(&buf, temp_milli)),
            .state = health.classify(temp_celsius, thresholds),
            .history = try self.histories[temperature_index].pushSnapshot(arena, @intCast(@max(@as(i64, 0), @divTrunc(temp_milli, 100)))),
        };
    }

    fn networkRow(self: *Sampler, arena: std.mem.Allocator, io: Io, configured_interface: ?[]const u8, now: Io.Timestamp) !metric.Row {
        var interface_buf: [64]u8 = undefined;
        const interface = configured_interface orelse host.defaultInterface(io, &interface_buf) catch return self.networkUnknownRow(arena);
        const counters = host.network(io, interface) catch return self.networkUnknownRow(arena);
        const link_speed = host.linkSpeed(io, interface) catch null;

        const rates = self.networkRates(interface, counters, now);
        var down_buf: [24]u8 = undefined;
        var up_buf: [24]u8 = undefined;
        const segments = try arena.alloc(metric.Segment, 2);
        segments[0] = .{ .signal = .down, .percent = networkPercent(rates.rx_bytes_per_second, link_speed) };
        segments[1] = .{ .signal = .up, .percent = networkPercent(rates.tx_bytes_per_second, link_speed) };
        const detail = try std.fmt.allocPrint(
            arena,
            "{s} {s} {s} {s}",
            .{
                format.download_marker,
                format.compactBytesPerSecond(&down_buf, rates.rx_bytes_per_second),
                format.upload_marker,
                format.compactBytesPerSecond(&up_buf, rates.tx_bytes_per_second),
            },
        );
        const history = try self.histories[network_down_index].pushSnapshot(arena, rates.rx_bytes_per_second);
        self.histories[network_up_index].push(rates.tx_bytes_per_second);
        return .{
            .label = "Network",
            .percent = null,
            .detail = detail,
            .state = .ok,
            .history = history,
            .segments = segments,
        };
    }

    fn networkUnknownRow(self: *Sampler, arena: std.mem.Allocator) !metric.Row {
        self.histories[network_down_index].push(null);
        self.histories[network_up_index].push(null);
        return .{
            .label = "Network",
            .percent = null,
            .detail = format.download_marker ++ " --/s " ++ format.upload_marker ++ " --/s",
            .state = .unknown,
            .history = try self.histories[network_down_index].snapshot(arena),
        };
    }

    fn networkRates(self: *Sampler, interface: []const u8, counters: host.Network, now: Io.Timestamp) NetworkRates {
        defer self.last_network = TimedNetwork.init(interface, counters, now);
        const previous = self.last_network orelse return .{};
        if (!std.mem.eql(u8, previous.interfaceName(), interface)) return .{};
        const elapsed_ns = previous.timestamp.durationTo(now).toNanoseconds();
        return .{
            .rx_bytes_per_second = metric.ratePerSecond(previous.counters.rx_bytes, counters.rx_bytes, elapsed_ns),
            .tx_bytes_per_second = metric.ratePerSecond(previous.counters.tx_bytes, counters.tx_bytes, elapsed_ns),
        };
    }
};

const Usage = struct { total: u64, free: u64 };

const NetworkRates = struct {
    rx_bytes_per_second: u64 = 0,
    tx_bytes_per_second: u64 = 0,
};

const TimedNetwork = struct {
    interface: [64]u8 = undefined,
    interface_len: usize,
    counters: host.Network,
    timestamp: Io.Timestamp,

    fn init(interface: []const u8, counters: host.Network, timestamp: Io.Timestamp) TimedNetwork {
        var timed: TimedNetwork = .{
            .interface_len = @min(interface.len, 64),
            .counters = counters,
            .timestamp = timestamp,
        };
        @memcpy(timed.interface[0..timed.interface_len], interface[0..timed.interface_len]);
        return timed;
    }

    fn interfaceName(timed: *const TimedNetwork) []const u8 {
        return timed.interface[0..timed.interface_len];
    }
};

fn unknownRow(arena: std.mem.Allocator, history: *History, label: []const u8, detail: []const u8) !metric.Row {
    return .{
        .label = label,
        .percent = null,
        .detail = detail,
        .state = .unknown,
        .history = try history.pushSnapshot(arena, null),
    };
}

const History = struct {
    values: [history_capacity]?u64 = undefined,
    start: usize = 0,
    len: usize = 0,

    fn pushSnapshot(history: *History, arena: std.mem.Allocator, value: ?u64) ![]const ?u64 {
        history.push(value);
        return history.snapshot(arena);
    }

    fn push(history: *History, value: ?u64) void {
        if (history.len < history.values.len) {
            history.values[(history.start + history.len) % history.values.len] = value;
            history.len += 1;
            return;
        }
        history.values[history.start] = value;
        history.start = (history.start + 1) % history.values.len;
    }

    fn snapshot(history: *const History, arena: std.mem.Allocator) ![]const ?u64 {
        const values = try arena.alloc(?u64, history.len);
        for (values, 0..) |*value, i| value.* = history.values[(history.start + i) % history.values.len];
        return values;
    }

    fn max(history: *const History) u64 {
        var result: u64 = 0;
        var i: usize = 0;
        while (i < history.len) : (i += 1) {
            if (history.values[(history.start + i) % history.values.len]) |value| result = @max(result, value);
        }
        return result;
    }
};

fn memoryUsage(io: Io) !Usage {
    const mem = try host.memory(io);
    return .{ .total = mem.total, .free = mem.available };
}

fn diskUsage(path: []const u8) !Usage {
    const value = try host.disk(path);
    return .{ .total = value.total, .free = value.free };
}

fn networkPercent(rate: u64, link_speed: ?u64) u64 {
    if (rate == 0) return 0;
    const capacity = link_speed orelse return 0;
    return @max(1, metric.scaledPercent(rate, capacity) orelse 0);
}

test "history keeps newest values in order" {
    var history: History = .{};
    var i: u64 = 0;
    while (i < history_capacity + 5) : (i += 1) history.push(i);

    const values = try history.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(values);

    try std.testing.expectEqual(@as(usize, history_capacity), values.len);
    try std.testing.expectEqual(@as(?u64, 5), values[0]);
    try std.testing.expectEqual(@as(?u64, history_capacity + 4), values[values.len - 1]);
}

test "history max ignores unknown samples" {
    var history: History = .{};
    history.push(null);
    history.push(4);
    history.push(9);
    history.push(null);
    history.push(7);
    try std.testing.expectEqual(@as(u64, 9), history.max());
}

test "network rates reset on first sample and interface change" {
    var sampler = Sampler{
        .allocator = std.testing.allocator,
        .histories = &.{},
    };
    const first = Io.Timestamp.fromNanoseconds(1_000_000_000);
    const second = Io.Timestamp.fromNanoseconds(2_000_000_000);

    try std.testing.expectEqual(NetworkRates{}, sampler.networkRates("eth0", .{ .rx_bytes = 100, .tx_bytes = 200 }, first));
    try std.testing.expectEqual(
        NetworkRates{ .rx_bytes_per_second = 50, .tx_bytes_per_second = 100 },
        sampler.networkRates("eth0", .{ .rx_bytes = 150, .tx_bytes = 300 }, second),
    );
    try std.testing.expectEqual(NetworkRates{}, sampler.networkRates("wlan0", .{ .rx_bytes = 1000, .tx_bytes = 1000 }, second));
}

test "network percent scales against link speed" {
    try std.testing.expectEqual(@as(u64, 0), networkPercent(50, null));
    try std.testing.expectEqual(@as(u64, 0), networkPercent(0, 100));
    try std.testing.expectEqual(@as(u64, 1), networkPercent(1, 1000));
    try std.testing.expectEqual(@as(u64, 50), networkPercent(50, 100));
    try std.testing.expectEqual(@as(u64, 100), networkPercent(120, 100));
}
