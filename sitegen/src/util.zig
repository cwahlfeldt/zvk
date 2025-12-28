const std = @import("std");

pub const Util = struct {
    pub fn replaceString(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
        const index = std.mem.indexOf(u8, haystack, needle) orelse {
            return try allocator.dupe(u8, haystack);
        };

        const new_len = haystack.len - needle.len + replacement.len;
        const result = try allocator.alloc(u8, new_len);

        @memcpy(result[0..index], haystack[0..index]);
        @memcpy(result[index..][0..replacement.len], replacement);
        @memcpy(result[index + replacement.len ..], haystack[index + needle.len ..]);

        return result;
    }
};
