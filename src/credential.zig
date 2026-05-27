const std = @import("std");

pub const Error = error{
    EmptyName,
    UnsafeName,
};

pub fn validateName(name: []const u8) Error!void {
    if (name.len == 0) return error.EmptyName;
    if (std.mem.indexOfAny(u8, name, "/:") != null) return error.UnsafeName;
}

pub fn path(allocator: std.mem.Allocator, directory: []const u8, name: []const u8) ![]u8 {
    try validateName(name);
    return std.fs.path.join(allocator, &.{ directory, name });
}

test "credential names reject empty and systemd separator bytes" {
    try validateName("sonarr-api-key");
    try validateName("jellyfin_token");
    try std.testing.expectError(error.EmptyName, validateName(""));
    try std.testing.expectError(error.UnsafeName, validateName("sonarr/key"));
    try std.testing.expectError(error.UnsafeName, validateName("sonarr:key"));
}

test "credential path joins directory and safe name" {
    const joined = try path(std.testing.allocator, "/run/credentials/heimdash.service", "sonarr-api-key");
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("/run/credentials/heimdash.service/sonarr-api-key", joined);
}

test "credential path rejects unsafe names" {
    try std.testing.expectError(error.UnsafeName, path(std.testing.allocator, "/run/credentials", "bad/name"));
    try std.testing.expectError(error.EmptyName, path(std.testing.allocator, "/run/credentials", ""));
}
