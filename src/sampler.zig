const std = @import("std");
const Io = std.Io;

const format = @import("format.zig");
const health = @import("health.zig");
const host = @import("host.zig");
const metric = @import("metric.zig");

pub const history_capacity = 1920;
pub const sample_interval_seconds = 15;

pub const Config = struct {
    mounts: []const []const u8,
    thresholds: health.Config,
    network_interface: ?[]const u8 = null,
};

const Usage = struct { total: u64, free: u64 };
const Cpu = struct { util: u64, load: f64 };
const Net = struct { rx_rate: u64, tx_rate: u64, link_speed: ?u64 };

const network_unknown_detail = format.download_marker ++ " --/s " ++ format.upload_marker ++ " --/s";

pub const Sampler = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    mutex: Io.Mutex = .init,
    histories: []History,
    disks: []?Usage,
    disk_io: []?TimedDiskIo = &.{},
    cpu: ?Cpu = null,
    memory: ?Usage = null,
    temperature: ?i64 = null,
    network: ?Net = null,
    last_network: ?TimedNetwork = null,
    last_cpu: ?host.CpuTimes = null,

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
        const disk_io = try allocator.alloc(?TimedDiskIo, cfg.mounts.len);
        @memset(disk_io, null);
        return .{ .allocator = allocator, .cfg = cfg, .histories = histories, .disks = disks, .disk_io = disk_io };
    }

    pub fn deinit(self: *Sampler) void {
        self.allocator.free(self.histories);
        self.allocator.free(self.disks);
        self.allocator.free(self.disk_io);
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

        self.cpu = self.sampleCpu(io);
        self.memory = memoryUsage(io) catch null;
        self.temperature = host.temperature(io) catch null;
        self.network = self.sampleNetwork(io, now);

        self.histories[cpu_index].push(if (self.cpu) |cpu| cpu.util else null);
        self.histories[memory_index].push(usagePercent(self.memory));
        self.histories[temperature_index].push(if (self.temperature) |milli| metric.scaledPercent(temperatureCelsius(milli), self.cfg.thresholds.temperature.critical) else null);
        if (self.network) |net| {
            self.histories[network_down_index].push(net.rx_rate);
            self.histories[network_up_index].push(net.tx_rate);
        } else {
            self.histories[network_down_index].push(null);
            self.histories[network_up_index].push(null);
        }
        for (self.cfg.mounts, 0..) |mount, i| {
            self.disks[i] = diskUsage(mount) catch null;
            self.histories[disk_start_index + i].push(self.diskIoSample(io, mount, i, now));
        }
    }

    fn diskIoSample(self: *Sampler, io: Io, mount: []const u8, index: usize, now: Io.Timestamp) ?u64 {
        const current = host.diskIo(io, mount) catch return null;
        return self.diskIoRate(index, current, now);
    }

    fn diskIoRate(self: *Sampler, index: usize, current: host.DiskIo, now: Io.Timestamp) u64 {
        defer self.disk_io[index] = .{ .counters = current, .timestamp = now };
        const previous = self.disk_io[index] orelse return 0;
        const elapsed_ns = previous.timestamp.durationTo(now).toNanoseconds();
        return metric.ratePerSecond(previous.counters.read_bytes, current.read_bytes, elapsed_ns) +
            metric.ratePerSecond(previous.counters.write_bytes, current.write_bytes, elapsed_ns);
    }

    fn sampleCpu(self: *Sampler, io: Io) ?Cpu {
        const load = host.loadAverage(io) catch return null;
        const current = host.cpuTimes(io) catch return null;
        return .{ .util = self.cpuUtilRate(current), .load = load };
    }

    fn cpuUtilRate(self: *Sampler, current: host.CpuTimes) u64 {
        defer self.last_cpu = current;
        const previous = self.last_cpu orelse return 0;
        const total_delta = current.total -| previous.total;
        if (total_delta == 0) return 0;
        const idle_delta = current.idle -| previous.idle;
        const busy = total_delta - idle_delta;
        return @min(100, busy * 100 / total_delta);
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
        return .{
            .label = "CPU",
            .percent = cpu.util,
            .detail = try std.fmt.allocPrint(arena, "load {d:.2}", .{cpu.load}),
            .state = health.classify(cpu.util, self.cfg.thresholds.cpu),
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
        const celsius: u64 = temperatureCelsius(milli);
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
        var row = try usageRow(arena, mount, self.disks[i], health.diskThresholdFor(self.cfg.thresholds, mount), history);
        row.spark_relative = true;
        return row;
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

fn usagePercent(usage: ?Usage) ?u64 {
    const value = usage orelse return null;
    return metric.usedPercent(value.total, value.free);
}

fn temperatureCelsius(milli: i64) u64 {
    return @intCast(@max(@as(i64, 0), @divTrunc(milli, 1000)));
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

const TimedDiskIo = struct {
    counters: host.DiskIo,
    timestamp: Io.Timestamp,
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

test "cpu utilization derives busy percent from jiffie deltas" {
    var sampler = Sampler{
        .allocator = std.testing.allocator,
        .cfg = undefined,
        .histories = &.{},
        .disks = &.{},
    };

    try std.testing.expectEqual(@as(u64, 0), sampler.cpuUtilRate(.{ .total = 1000, .idle = 800 }));
    try std.testing.expectEqual(@as(u64, 75), sampler.cpuUtilRate(.{ .total = 1100, .idle = 825 }));
    try std.testing.expectEqual(@as(u64, 0), sampler.cpuUtilRate(.{ .total = 1200, .idle = 925 }));
}

test "disk io rate sums read and write deltas after the first sample" {
    var io_state = [_]?TimedDiskIo{null};
    var sampler = Sampler{
        .allocator = std.testing.allocator,
        .cfg = undefined,
        .histories = &.{},
        .disks = &.{},
        .disk_io = &io_state,
    };
    const first = Io.Timestamp.fromNanoseconds(1_000_000_000);
    const second = Io.Timestamp.fromNanoseconds(2_000_000_000);

    try std.testing.expectEqual(@as(u64, 0), sampler.diskIoRate(0, .{ .read_bytes = 1000, .write_bytes = 2000 }, first));
    try std.testing.expectEqual(@as(u64, 1500), sampler.diskIoRate(0, .{ .read_bytes = 1500, .write_bytes = 3000 }, second));
}

test "network percent scales against link speed" {
    try std.testing.expectEqual(@as(u64, 0), networkPercent(50, null));
    try std.testing.expectEqual(@as(u64, 0), networkPercent(0, 100));
    try std.testing.expectEqual(@as(u64, 1), networkPercent(1, 1000));
    try std.testing.expectEqual(@as(u64, 50), networkPercent(50, 100));
    try std.testing.expectEqual(@as(u64, 100), networkPercent(120, 100));
}
