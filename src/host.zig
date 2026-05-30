const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const format = @import("format.zig");

pub const Memory = struct { total: u64, available: u64 };
pub const Disk = struct { total: u64, free: u64 };
pub const DiskIo = struct { read_bytes: u64, write_bytes: u64 };
pub const CpuTimes = struct { total: u64, idle: u64 };
pub const Network = struct { rx_bytes: u64, tx_bytes: u64 };

const diskstats_sector_size = 512;

pub fn hostname(io: Io, buf: []u8) ![]const u8 {
    return std.mem.trim(u8, try readSmall(io, "/etc/hostname", buf), " \t\r\n");
}

pub fn uptime(io: Io) !u64 {
    try requireLinux();
    var buf: [128]u8 = undefined;
    const text = try readSmall(io, "/proc/uptime", &buf);
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const dot = std.mem.indexOfScalar(u8, text[0..space], '.') orelse space;
    return std.fmt.parseInt(u64, text[0..dot], 10) catch 0;
}

pub fn loadAverage(io: Io) !f64 {
    try requireLinux();
    var buf: [128]u8 = undefined;
    const text = try readSmall(io, "/proc/loadavg", &buf);
    const space = std.mem.indexOfScalar(u8, text, ' ') orelse return error.BadLoadAvg;
    return std.fmt.parseFloat(f64, text[0..space]);
}

pub fn cpuTimes(io: Io) !CpuTimes {
    try requireLinux();
    var buf: [1024]u8 = undefined;
    const text = try readSmall(io, "/proc/stat", &buf);
    return parseCpuTimes(text) orelse error.CpuUnavailable;
}

pub fn memory(io: Io) !Memory {
    try requireLinux();
    var buf: [4096]u8 = undefined;
    const text = try readSmall(io, "/proc/meminfo", &buf);
    return .{
        .total = format.parseMemKb(text, "MemTotal:") * 1024,
        .available = format.parseMemKb(text, "MemAvailable:") * 1024,
    };
}

pub fn temperature(io: Io) !i64 {
    try requireLinux();
    var best: ?i64 = null;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        var path_buf: [80]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/class/thermal/thermal_zone{d}/temp", .{i}) catch unreachable;
        var value_buf: [64]u8 = undefined;
        const text = readSmall(io, path, &value_buf) catch continue;
        const value = parseTemperature(text) orelse continue;
        if (value < -100_000 or value > 200_000) continue;
        if (best == null or value > best.?) best = value;
    }
    return best orelse error.TemperatureUnavailable;
}

pub fn defaultInterface(io: Io, buf: []u8) ![]const u8 {
    try requireLinux();
    var text_buf: [4096]u8 = undefined;
    const text = try readSmall(io, "/proc/net/route", &text_buf);
    const iface = parseDefaultInterface(text) orelse return error.NetworkUnavailable;
    if (iface.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..iface.len], iface);
    return buf[0..iface.len];
}

pub fn network(io: Io, interface: []const u8) !Network {
    try requireLinux();
    var buf: [32 * 1024]u8 = undefined;
    const text = try readSmall(io, "/proc/net/dev", &buf);
    return parseNetwork(text, interface) orelse error.NetworkUnavailable;
}

pub fn linkSpeed(io: Io, interface: []const u8) !u64 {
    try requireLinux();
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/class/net/{s}/speed", .{interface}) catch return error.NameTooLong;
    var buf: [64]u8 = undefined;
    const text = try readSmall(io, path, &buf);
    return parseLinkSpeed(text) orelse error.NetworkUnavailable;
}

pub fn disk(path: []const u8) !Disk {
    try requireLinux();
    const linux = std.os.linux;
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var st: StatFs = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(&path_buf), @intFromPtr(&st));
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.StatFsFailed,
    }
    const bs: u64 = @intCast(st.f_bsize);
    return .{ .total = st.f_blocks *% bs, .free = st.f_bavail *% bs };
}

pub fn diskIo(io: Io, path: []const u8) !DiskIo {
    try requireLinux();
    const linux = std.os.linux;
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    var stx: linux.Statx = undefined;
    const mask: linux.STATX = @bitCast(@as(u32, 0));
    switch (linux.errno(linux.statx(linux.AT.FDCWD, @ptrCast(&path_buf), 0, mask, &stx))) {
        .SUCCESS => {},
        else => return error.DiskIoUnavailable,
    }

    var buf: [64 * 1024]u8 = undefined;
    const text = try readSmall(io, "/proc/diskstats", &buf);
    return parseDiskstats(text, stx.dev_major, stx.dev_minor) orelse error.DiskIoUnavailable;
}

fn requireLinux() !void {
    if (builtin.os.tag != .linux) return error.UnsupportedHost;
}

pub fn parseTemperature(text: []const u8) ?i64 {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len == 0) return null;
    return std.fmt.parseInt(i64, value, 10) catch null;
}

pub fn parseCpuTimes(text: []const u8) ?CpuTimes {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return null;
    var fields = std.mem.tokenizeAny(u8, first, " \t");
    if (!std.mem.eql(u8, fields.next() orelse return null, "cpu")) return null;

    var total: u64 = 0;
    var idle: u64 = 0;
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        const value = std.fmt.parseInt(u64, field, 10) catch return null;
        total += value;
        if (index == 3 or index == 4) idle += value;
    }
    return .{ .total = total, .idle = idle };
}

pub fn parseDefaultInterface(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const iface = fields.next() orelse continue;
        const destination = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        if (!std.mem.eql(u8, destination, "00000000")) continue;
        return iface;
    }
    return null;
}

pub fn parseNetwork(text: []const u8, interface: []const u8) ?Network {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.mem.eql(u8, name, interface)) continue;

        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const rx = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
        var skipped: usize = 0;
        while (skipped < 7) : (skipped += 1) _ = fields.next() orelse return null;
        const tx = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
        return .{ .rx_bytes = rx, .tx_bytes = tx };
    }
    return null;
}

pub fn parseDiskstats(text: []const u8, major: u32, minor: u32) ?DiskIo {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const maj = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const min = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        if (maj != major or min != minor) continue;

        _ = fields.next() orelse return null;
        _ = fields.next() orelse return null;
        _ = fields.next() orelse return null;
        const sectors_read = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
        _ = fields.next() orelse return null;
        _ = fields.next() orelse return null;
        _ = fields.next() orelse return null;
        const sectors_written = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
        return .{
            .read_bytes = sectors_read *% diskstats_sector_size,
            .write_bytes = sectors_written *% diskstats_sector_size,
        };
    }
    return null;
}

pub fn parseLinkSpeed(text: []const u8) ?u64 {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len == 0) return null;
    const megabits = std.fmt.parseInt(i64, value, 10) catch return null;
    if (megabits <= 0) return null;
    const bytes_per_second = @as(u128, @intCast(megabits)) * 1_000_000 / 8;
    return @intCast(@min(bytes_per_second, std.math.maxInt(u64)));
}

fn readSmall(io: Io, path: []const u8, buf: []u8) ![]const u8 {
    var file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var fr = file.reader(io, &.{});
    const n = try fr.interface.readSliceShort(buf);
    return buf[0..n];
}

const StatFs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

test "parseTemperature trims thermal zone values" {
    try std.testing.expectEqual(@as(?i64, 42123), parseTemperature("42123\n"));
    try std.testing.expectEqual(@as(?i64, -5000), parseTemperature(" -5000 "));
    try std.testing.expectEqual(@as(?i64, null), parseTemperature("\n"));
}

test "parseCpuTimes totals jiffies and counts idle plus iowait" {
    const text =
        \\cpu  100 0 200 1000 50 0 0 0 0 0
        \\cpu0 50 0 100 500 25 0 0 0 0 0
        \\intr 12345
    ;
    const times = parseCpuTimes(text).?;
    try std.testing.expectEqual(@as(u64, 1350), times.total);
    try std.testing.expectEqual(@as(u64, 1050), times.idle);
    try std.testing.expectEqual(@as(?CpuTimes, null), parseCpuTimes("intr 0\n"));
}

test "parseDefaultInterface selects the default route" {
    const text =
        \\Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT
        \\lo 0000007F 00000000 0001 0 0 0 000000FF 0 0 0
        \\enp1s0 00000000 0102A8C0 0003 0 0 100 00000000 0 0 0
    ;
    try std.testing.expectEqualStrings("enp1s0", parseDefaultInterface(text).?);
}

test "parseNetwork extracts rx and tx bytes" {
    const text =
        \\Inter-|   Receive                                                |  Transmit
        \\ face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        \\    lo: 1000 1 0 0 0 0 0 0 2000 2 0 0 0 0 0 0
        \\enp1s0: 123456 10 0 0 0 0 0 0 654321 20 0 0 0 0 0 0
    ;
    const counters = parseNetwork(text, "enp1s0").?;
    try std.testing.expectEqual(@as(u64, 123456), counters.rx_bytes);
    try std.testing.expectEqual(@as(u64, 654321), counters.tx_bytes);
    try std.testing.expectEqual(@as(?Network, null), parseNetwork(text, "missing0"));
}

test "parseDiskstats reads sector counters for the matching device" {
    const text =
        \\   8       0 sda 12345 100 678900 5000 23456 200 789000 6000 0 7000 11000
        \\ 259       0 nvme0n1 11 0 880 2 33 0 1320 4 0 6 8
    ;
    const sda = parseDiskstats(text, 8, 0).?;
    try std.testing.expectEqual(@as(u64, 678900 * 512), sda.read_bytes);
    try std.testing.expectEqual(@as(u64, 789000 * 512), sda.write_bytes);

    const nvme = parseDiskstats(text, 259, 0).?;
    try std.testing.expectEqual(@as(u64, 880 * 512), nvme.read_bytes);
    try std.testing.expectEqual(@as(u64, 1320 * 512), nvme.write_bytes);

    try std.testing.expectEqual(@as(?DiskIo, null), parseDiskstats(text, 8, 1));
}

test "parseLinkSpeed converts sysfs megabits to bytes per second" {
    try std.testing.expectEqual(@as(?u64, 125_000_000), parseLinkSpeed("1000\n"));
    try std.testing.expectEqual(@as(?u64, 1_250_000_000), parseLinkSpeed("10000"));
    try std.testing.expectEqual(@as(?u64, null), parseLinkSpeed("-1\n"));
    try std.testing.expectEqual(@as(?u64, null), parseLinkSpeed("0\n"));
    try std.testing.expectEqual(@as(?u64, null), parseLinkSpeed("\n"));
}
