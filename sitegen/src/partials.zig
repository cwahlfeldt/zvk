const std = @import("std");

pub const Partials = struct {
    allocator: std.mem.Allocator,
    partials: std.StringHashMap([]const u8),
    context: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Partials {
        return .{
            .allocator = allocator,
            .partials = std.StringHashMap([]const u8).init(allocator),
            .context = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Partials) void {
        var partial_iter = self.partials.iterator();
        while (partial_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.partials.deinit();

        var ctx_iter = self.context.iterator();
        while (ctx_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.context.deinit();
    }

    /// Load all partial files from the partials directory
    pub fn loadFromDir(self: *Partials, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return; // No partials dir is okay
            return err;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".html")) continue;

            const file = try dir.openFile(entry.name, .{});
            defer file.close();

            const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);

            // Store partial name without .html extension
            const name_len = entry.name.len - 5; // Remove ".html"
            const name = try self.allocator.dupe(u8, entry.name[0..name_len]);

            try self.partials.put(name, content);
        }
    }

    /// Set a global context value accessible via {{ctx.key}} or {{key}}
    pub fn setContext(self: *Partials, key: []const u8, value: []const u8) !void {
        // Free existing entry if present
        if (self.context.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }

        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.context.put(key_copy, value_copy);
    }

    /// Render a template, expanding partials and context variables
    pub fn render(self: *Partials, template: []const u8) ![]u8 {
        var result = try self.allocator.dupe(u8, template);

        // Expand partials: {{> partial_name}}
        result = try self.expandPartials(result);

        // Expand context variables: {{ctx.key}} and {{key}}
        result = try self.expandContext(result);
        result = try self.expandSimpleContext(result);

        return result;
    }

    fn expandPartials(self: *Partials, input: []u8) ![]u8 {
        var result = input;

        while (std.mem.indexOf(u8, result, "{{>")) |start| {
            const end = std.mem.indexOfPos(u8, result, start, "}}") orelse break;

            // Extract partial name (trim whitespace)
            const raw_name = result[start + 3 .. end];
            const name = std.mem.trim(u8, raw_name, " \t");

            // Look up partial content
            const partial_content = self.partials.get(name) orelse {
                // Partial not found - leave placeholder or remove it
                const before = result[0..start];
                const after = result[end + 2 ..];
                const new_len = before.len + after.len;
                const new_result = try self.allocator.alloc(u8, new_len);
                @memcpy(new_result[0..before.len], before);
                @memcpy(new_result[before.len..], after);
                self.allocator.free(result);
                result = new_result;
                continue;
            };

            // First render the partial itself (for nested partials/context)
            const rendered_partial = try self.expandContext(try self.allocator.dupe(u8, partial_content));
            defer self.allocator.free(rendered_partial);

            // Replace {{> name}} with partial content
            const before = result[0..start];
            const after = result[end + 2 ..];
            const new_len = before.len + rendered_partial.len + after.len;
            const new_result = try self.allocator.alloc(u8, new_len);

            @memcpy(new_result[0..before.len], before);
            @memcpy(new_result[before.len..][0..rendered_partial.len], rendered_partial);
            @memcpy(new_result[before.len + rendered_partial.len ..], after);

            self.allocator.free(result);
            result = new_result;
        }

        return result;
    }

    fn expandContext(self: *Partials, input: []u8) ![]u8 {
        var result = input;

        while (std.mem.indexOf(u8, result, "{{ctx.")) |start| {
            const end = std.mem.indexOfPos(u8, result, start, "}}") orelse break;

            // Extract context key
            const key = result[start + 6 .. end];

            // Look up context value
            const value = self.context.get(key) orelse "";

            // Replace {{ctx.key}} with value
            const before = result[0..start];
            const after = result[end + 2 ..];
            const new_len = before.len + value.len + after.len;
            const new_result = try self.allocator.alloc(u8, new_len);

            @memcpy(new_result[0..before.len], before);
            @memcpy(new_result[before.len..][0..value.len], value);
            @memcpy(new_result[before.len + value.len ..], after);

            self.allocator.free(result);
            result = new_result;
        }

        return result;
    }

    /// Expand simple context variables: {{key}} (without ctx. prefix)
    fn expandSimpleContext(self: *Partials, input: []u8) ![]u8 {
        var result = input;

        var pos: usize = 0;
        while (pos < result.len) {
            const start = std.mem.indexOfPos(u8, result, pos, "{{") orelse break;

            // Skip if this is a partial ({{>) or already processed ctx
            if (start + 2 < result.len and (result[start + 2] == '>' or
                (result.len > start + 5 and std.mem.eql(u8, result[start + 2 .. start + 6], "ctx."))))
            {
                pos = start + 2;
                continue;
            }

            const end = std.mem.indexOfPos(u8, result, start, "}}") orelse break;

            // Extract key
            const key = std.mem.trim(u8, result[start + 2 .. end], " \t");

            // Look up context value
            const value = self.context.get(key) orelse {
                pos = end + 2;
                continue;
            };

            // Replace {{key}} with value
            const before = result[0..start];
            const after = result[end + 2 ..];
            const new_len = before.len + value.len + after.len;
            const new_result = try self.allocator.alloc(u8, new_len);

            @memcpy(new_result[0..before.len], before);
            @memcpy(new_result[before.len..][0..value.len], value);
            @memcpy(new_result[before.len + value.len ..], after);

            self.allocator.free(result);
            result = new_result;
            pos = before.len + value.len;
        }

        return result;
    }
};
