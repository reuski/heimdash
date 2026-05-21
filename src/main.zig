const std = @import("std");

pub fn main() void {
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) _ = args.next();
    }
    std.debug.print("heimdash: not yet implemented\n", .{});
}
