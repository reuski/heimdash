const std = @import("std");
const Io = std.Io;

const format = @import("format.zig");
const health = @import("health.zig");
const host = @import("host.zig");
const metric = @import("metric.zig");

pub const history_capacity = 120;
pub const sample_interval_seconds = 15;

pub const Config = struct {
    mounts: []const []const u8,
    thresholds: health.Config,
    network_interface: ?[]const u8 = null,
};

const Usage = struct { total: u64, free: u64 };
const Cpu = struct { load: f64, ncpu: usize };
const Net = struct { rx_rate: u64, tx_rate: u64, link_speed: ?u64 };

const network_unknown_detail = format.download_marker ++ " --/s " ++ format.upload_marker ++ " --/s";

/// Single background sampler. One `run` loop is the sole writer of `histories`,
/// `last_network`, and the `latest` readings; request handlers only read through
/// `snapshot`. This keeps the in-memory timeseries advancing at a fixed cadence
/// regardless of how many clients are connected, and keeps network rate deltas
/// computed against a single consistent previous sample.
pub const Sampler = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    mutex: Io.Mutex = .init,
    histories: []History,
    disks: []?Usage,
    cpu: ?Cpu = null,
    memory: ?Usage = null,
    temperature: ?i64 = null,
    network: ?Net = null,
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
        const disks = try allocator.alloc(?Usage, cfg.mounts.len);
        @memset(disks, null);
        return .{ .allocator = allocator, .cfg = cfg, .histories = histories, .disks = disks };
    }

    pub fn deinit(self: *Sampler) void {
        self.allocator.free(self.histories);
        self.allocator.free(self.disks);
    }

    pub fn run(self: *Sampler, io: Io) void {
        self.tick(io);
        while (true) {
            Io.sleep(io, .fromSeconds(sample_interval_seconds), .awake) catch return;
            self.tick(io);
        }
    }

    fn tick(self: *Sampler, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const now = Io.Timestamp.now(io, .awake);

        self.cpu = sampleCpu(io);
        self.memory = memoryUsage(io) catch null;
        self.temperature = host.temperature(io) catch null;
        self.network = self.sampleNetwork(io, now);

        self.histories[cpu_index].push(if (self.cpu) |cpu| cpuPercent(cpu) else null);
        self.histories[memory_index].push(usagePercent(self.memory));
        self.histories[temperature_index].push(if (self.temperature) |milli| temperatureSample(milli) else null);
        if (self.network) |net| {
            self.histories[network_down_index].push(net.rx_rate);
            self.histories[network_up_index].push(net.tx_rate);
        } else {
            self.histories[network_down_index].push(null);
            self.histories[network_up_index].push(null);
        }
        for (self.cfg.mounts, 0..) |mount, i| {
            self.disks[i] = diskUsage(mount) catch null;
            self.histories[disk_start_index + i].push(usagePercent(self.disks[i]));
        }
    }

    pub fn snapshot(self: *Sampler, arena: std.mem.Allocator, io: Io) !metric.Snapshot {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const system_rows = try arena.alloc(metric.Row, system_row_count);
        system_rows[0] = try self.cpuRow(arena);
        system_rows[1] = try self.memoryRow(arena);
        system_rows[2] = try self.temperatureRow(arena);
        system_rows[3] = try self.networkRow(arena);

        const disks = try arena.alloc(metric.Row, self.cfg.mounts.len);
        for (self.cfg.mounts, 0..) |mount, i| disks[i] = try self.diskRow(arena, mount, i);

        const sections = try arena.alloc(metric.Section, 2);
        sections[0] = .{ .id = "system", .title = "System", .rows = system_rows };
        sections[1] = .{ .id = "disks", .title = "Disks", .rows = disks };
        return .{ .sections = sections };
    }

    fn cpuRow(self: *Sampler, arena: std.mem.Allocator) !metric.Row {
        const history = try self.histories[cpu_index].snapshot(arena);
        const cpu = self.cpu orelse return unknownRow("CPU", "load --", history);
        const pct = cpuPercent(cpu);
        return .{
            .label = "CPU",
            .percent = pct,
            .detail = try std.fmt.allocPrint(arena, "load {d:.2}", .{cpu.load}),
            .state = health.classify(pct, self.cfg.thresholds.cpu),
            .history = history,
        };
    }

    fn memoryRow(self: *Sampler, arena: std.mem.Allocator) !metric.Row {
        const history = try self.histories[memory_index].snapshot(arena);
        return usageRow(arena, "Memory", self.memory, self.cfg.thresholds.memory, history);
    }

    fn temperatureRow(self: *Sampler, arena: std.mem.Allocator) !metric.Row {
        const history = try self.histories[temperature_index].snapshot(arena);
        const milli = self.temperature orelse return unknownRow("Temp", "-- C", history);
        const celsius: u64 = @intCast(@max(@as(i64, 0), @divTrunc(milli, 1000)));
        var buf: [32]u8 = undefined;
        return .{
            .label = "Temp",
            .percent = metric.scaledPercent(celsius, self.cfg.thresholds.temperature.critical),
            .detail = try arena.dupe(u8, format.milliCelsius(&buf, milli)),
            .state = health.classify(celsius, self.cfg.thresholds.temperature),
            .history = history,
        };
    }

    fn networkRow(self: *Sampler, arena: std.mem.Allocator) !metric.Row {
        const history = try self.histories[network_down_index].snapshot(arena);
        const net = self.network orelse return .{
            .label = "Network",
            .percent = null,
            .detail = network_unknown_detail,
            .state = .unknown,
            .history = history,
        };
        var down_buf: [24]u8 = undefined;
        var up_buf: [24]u8 = undefined;
        const segments = try arena.alloc(metric.Segment, 2);
        segments[0] = .{ .signal = .down, .percent = networkPercent(net.rx_rate, net.link_speed) };
        segments[1] = .{ .signal = .up, .percent = networkPercent(net.tx_rate, net.link_speed) };
        return .{
            .label = "Network",
            .percent = null,
            .detail = try std.fmt.allocPrint(arena, "{s} {s} {s} {s}", .{
                format.download_marker,
                format.compactBytesPerSecond(&down_buf, net.rx_rate),
                format.upload_marker,
                format.compactBytesPerSecond(&up_buf, net.tx_rate),
            }),
            .state = .ok,
            .history = history,
            .segments = segments,
        };
    }

    fn diskRow(self: *Sampler, arena: std.mem.Allocator, mount: []const u8, i: usize) !metric.Row {
        const history = try self.histories[disk_start_index + i].snapshot(arena);
        return usageRow(arena, mount, self.disks[i], health.diskThresholdFor(self.cfg.thresholds, mount), history);
    }

    fn sampleNetwork(self: *Sampler, io: Io, now: Io.Timestamp) ?Net {
        var interface_buf: [64]u8 = undefined;
        const interface = self.cfg.network_interface orelse host.defaultInterface(io, &interface_buf) catch return null;
        const counters = host.network(io, interface) catch return null;
        const link_speed = host.linkSpeed(io, interface) catch null;
        const rates = self.networkRates(interface, counters, now);
        return .{ .rx_rate = rates.rx_bytes_per_second, .tx_rate = rates.tx_bytes_per_second, .link_speed = link_speed };
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

fn usageRow(
    arena: std.mem.Allocator,
    label: []const u8,
    usage: ?Usage,
    thresholds: health.Thresholds,
    history: []const ?u64,
) !metric.Row {
    const value = usage orelse return unknownRow(label, "-- free", history);
    const pct = metric.usedPercent(value.total, value.free);
    var buf: [32]u8 = undefined;
    return .{
        .label = label,
        .percent = pct,
        .detail = try std.fmt.allocPrint(arena, "{s} free", .{format.bytes(&buf, value.free)}),
        .state = health.classify(pct, thresholds),
        .history = history,
    };
}

fn unknownRow(label: []const u8, detail: []const u8, history: []const ?u64) metric.Row {
    return .{ .label = label, .percent = null, .detail = detail, .state = .unknown, .history = history };
}

fn sampleCpu(io: Io) ?Cpu {
    const load = host.loadAverage(io) catch return null;
    const ncpu = std.Thread.getCpuCount() catch return null;
    return .{ .load = load, .ncpu = ncpu };
}

fn cpuPercent(cpu: Cpu) u64 {
    return @min(100, @as(u64, @intFromFloat(cpu.load / @as(f64, @floatFromInt(cpu.ncpu)) * 100.0)));
}

fn usagePercent(usage: ?Usage) ?u64 {
    const value = usage orelse return null;
    return metric.usedPercent(value.total, value.free);
}

fn temperatureSample(milli: i64) u64 {
    return @intCast(@max(@as(i64, 0), @divTrunc(milli, 100)));
}

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

const History = struct {
    values: [history_capacity]?u64 = undefined,
    start: usize = 0,
    len: usize = 0,

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
        .cfg = undefined,
        .histories = &.{},
        .disks = &.{},
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
