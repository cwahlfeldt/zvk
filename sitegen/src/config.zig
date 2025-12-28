const std = @import("std");
const Partials = @import("partials.zig").Partials;

// Import site config at comptime
pub const site = @import("site.config");

pub const Config = struct {
    /// Apply all site config values to a Partials context
    pub fn applyToPartials(partials: *Partials) !void {
        const info = @typeInfo(site);

        inline for (info.@"struct".decls) |decl| {
            const value = @field(site, decl.name);
            const T = @TypeOf(value);

            // Only process string constants
            if (T == []const u8 or T == *const [value.len:0]u8) {
                try partials.setContext(decl.name, value);
            }
        }
    }
};
