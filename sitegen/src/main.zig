const std = @import("std");
const util = @import("util.zig").Util;
const md = @import("markdown.zig").Markdown;
const Partials = @import("partials.zig").Partials;
const config = @import("config.zig");
const Config = config.Config;
const site = config.site;

const c = @cImport({
    @cInclude("stdlib.h");
});

pub fn main() !void {
    const stdout = std.fs.File.stdout();

    try stdout.writeAll("=== Simple Static Site Generator ===\n\n");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize partials system
    var partials = Partials.init(allocator);
    defer partials.deinit();

    // Load partials and apply site config to context
    try partials.loadFromDir("partials");
    try Config.applyToPartials(&partials);

    // Load HTML template
    const template = std.fs.cwd().openFile("templates/base.html", .{}) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.writeAll("Error: 'templates/base.html' not found.\n");
            return;
        }
        return err;
    };
    defer template.close();

    const html_template = try template.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(html_template);

    // Open content directory (supports absolute or relative paths)
    const content_path = site.content_dir;
    var content_dir = openPath(content_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            try stdout.writeAll("Error: '");
            try stdout.writeAll(content_path);
            try stdout.writeAll("' directory not found.\n");
            return;
        }
        return err;
    };
    defer content_dir.close();

    // Build navigation from content directory structure
    const nav_html = try buildNavigation(allocator, content_dir, "");
    defer allocator.free(nav_html);
    try partials.setContext("nav", nav_html);

    // Create or open output directory
    var output_dir = try std.fs.cwd().makeOpenPath("public", .{});
    defer output_dir.close();

    try stdout.writeAll("Building site...\n\n");

    // Recursively process markdown files
    var file_count: u32 = 0;
    try processDirectory(allocator, content_dir, output_dir, "", &partials, html_template, stdout, &file_count);

    // Print summary
    try stdout.writeAll("\n");
    var buf: [64]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Built {d} page(s) to public/\n", .{file_count});
    try stdout.writeAll(msg);
}

/// Open a directory from an absolute or relative path
fn openPath(path: []const u8, flags: std.fs.Dir.OpenOptions) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openDirAbsolute(path, flags);
    } else {
        return std.fs.cwd().openDir(path, flags);
    }
}

/// Generate an index page for a directory without index.md
fn generateDirectoryIndex(allocator: std.mem.Allocator, entries: []const std.fs.Dir.Entry, rel_path: []const u8) ![]u8 {
    var html = std.ArrayListUnmanaged(u8){};
    defer html.deinit(allocator);

    // Add title
    const dir_name = std.fs.path.basename(rel_path);
    var capitalized = try allocator.dupe(u8, dir_name);
    defer allocator.free(capitalized);
    if (capitalized.len > 0 and capitalized[0] >= 'a' and capitalized[0] <= 'z') {
        capitalized[0] -= 32;
    }

    const heading = try std.fmt.allocPrint(allocator, "<h1>{s}</h1>\n<ul>\n", .{capitalized});
    defer allocator.free(heading);
    try html.appendSlice(allocator, heading);

    // Count markdown files for URL structure
    var md_count: usize = 0;
    for (entries) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
            md_count += 1;
        }
    }

    for (entries) |entry| {
        if (entry.kind == .directory) {
            // Link to subdirectory
            const link = try std.fmt.allocPrint(allocator, "<li><a href=\"{s}/\">{s}/</a></li>\n", .{ entry.name, entry.name });
            defer allocator.free(link);
            try html.appendSlice(allocator, link);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
            const title = entry.name[0 .. entry.name.len - 3];

            // Skip index.md in listing
            if (std.mem.eql(u8, title, "index")) continue;

            // Capitalize title
            var display = try allocator.dupe(u8, title);
            defer allocator.free(display);
            if (display.len > 0 and display[0] >= 'a' and display[0] <= 'z') {
                display[0] -= 32;
            }

            // Determine URL based on file count
            const href = if (md_count == 1)
                try std.fmt.allocPrint(allocator, "{s}/", .{title})
            else
                try std.fmt.allocPrint(allocator, "{s}.html", .{title});
            defer allocator.free(href);

            const link = try std.fmt.allocPrint(allocator, "<li><a href=\"{s}\">{s}</a></li>\n", .{ href, display });
            defer allocator.free(link);
            try html.appendSlice(allocator, link);
        }
    }

    try html.appendSlice(allocator, "</ul>\n");

    return try allocator.dupe(u8, html.items);
}

/// Build navigation HTML from content directory structure
fn buildNavigation(allocator: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8) ![]u8 {
    var nav = std.ArrayListUnmanaged(u8){};
    defer nav.deinit(allocator);

    // Collect and sort entries
    var entries = std.ArrayListUnmanaged(std.fs.Dir.Entry){};
    defer entries.deinit(allocator);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        try entries.append(allocator, entry);
    }

    // Sort entries alphabetically, but put index first
    std.mem.sort(std.fs.Dir.Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: std.fs.Dir.Entry, b: std.fs.Dir.Entry) bool {
            // index.md always comes first
            if (std.mem.eql(u8, a.name, "index.md")) return true;
            if (std.mem.eql(u8, b.name, "index.md")) return false;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    // Count markdown files in this directory
    var md_count: usize = 0;
    for (entries.items) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
            md_count += 1;
        }
    }

    for (entries.items) |entry| {
        if (entry.kind == .directory) {
            // Check what's in this subdirectory
            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();

            const new_prefix = if (prefix.len == 0)
                try std.fmt.allocPrint(allocator, "/{s}", .{entry.name})
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            defer allocator.free(new_prefix);

            // Count items in subdirectory
            var sub_md_count: usize = 0;
            var sub_dir_count: usize = 0;
            var sub_iter = sub_dir.iterate();
            while (try sub_iter.next()) |sub_entry| {
                if (sub_entry.kind == .file and std.mem.endsWith(u8, sub_entry.name, ".md")) {
                    sub_md_count += 1;
                } else if (sub_entry.kind == .directory) {
                    sub_dir_count += 1;
                }
            }

            // Capitalize directory name
            var dir_display = try allocator.dupe(u8, entry.name);
            defer allocator.free(dir_display);
            if (dir_display.len > 0 and dir_display[0] >= 'a' and dir_display[0] <= 'z') {
                dir_display[0] -= 32;
            }

            // If directory has only one md file and no subdirs, link directly to it
            if (sub_md_count == 1 and sub_dir_count == 0) {
                const dir_link = try std.fmt.allocPrint(allocator, "<a href=\"{s}/\">{s}</a>\n", .{ new_prefix, dir_display });
                defer allocator.free(dir_link);
                try nav.appendSlice(allocator, dir_link);
                // Don't recurse - we already linked to the directory
            } else {
                // Add directory link
                const dir_link = try std.fmt.allocPrint(allocator, "<a href=\"{s}/\">{s}</a>\n", .{ new_prefix, dir_display });
                defer allocator.free(dir_link);
                try nav.appendSlice(allocator, dir_link);

                // Re-open for recursion
                var sub_dir2 = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer sub_dir2.close();

                // Recursively add subdirectory items (nested)
                const sub_nav = try buildNavigation(allocator, sub_dir2, new_prefix);
                defer allocator.free(sub_nav);
                if (sub_nav.len > 0) {
                    try nav.appendSlice(allocator, sub_nav);
                }
            }
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
            const title = entry.name[0 .. entry.name.len - 3];

            // Determine the URL based on file structure
            const href = if (std.mem.eql(u8, title, "index")) blk: {
                // index.md -> /prefix/
                if (prefix.len == 0) {
                    break :blk try allocator.dupe(u8, "/");
                } else {
                    break :blk try std.fmt.allocPrint(allocator, "{s}/", .{prefix});
                }
            } else if (md_count == 1) blk: {
                // Single file in directory -> /prefix/name/
                if (prefix.len == 0) {
                    break :blk try std.fmt.allocPrint(allocator, "/{s}/", .{title});
                } else {
                    break :blk try std.fmt.allocPrint(allocator, "{s}/{s}/", .{ prefix, title });
                }
            } else blk: {
                // Multiple files -> /prefix/name.html
                if (prefix.len == 0) {
                    break :blk try std.fmt.allocPrint(allocator, "/{s}.html", .{title});
                } else {
                    break :blk try std.fmt.allocPrint(allocator, "{s}/{s}.html", .{ prefix, title });
                }
            };
            defer allocator.free(href);

            // Use title for display (capitalize first letter)
            var display_title = try allocator.dupe(u8, title);
            defer allocator.free(display_title);
            if (display_title.len > 0 and display_title[0] >= 'a' and display_title[0] <= 'z') {
                display_title[0] -= 32;
            }

            // Skip adding "Index" to nav, it's usually the home page
            if (std.mem.eql(u8, title, "index")) {
                const link = try std.fmt.allocPrint(allocator, "<a href=\"{s}\">Home</a>\n", .{href});
                defer allocator.free(link);
                try nav.appendSlice(allocator, link);
            } else {
                const link = try std.fmt.allocPrint(allocator, "<a href=\"{s}\">{s}</a>\n", .{ href, display_title });
                defer allocator.free(link);
                try nav.appendSlice(allocator, link);
            }
        }
    }

    return try allocator.dupe(u8, nav.items);
}

/// Recursively process a directory of markdown files
fn processDirectory(
    allocator: std.mem.Allocator,
    content_dir: std.fs.Dir,
    output_dir: std.fs.Dir,
    rel_path: []const u8,
    partials: *Partials,
    html_template: []const u8,
    stdout: std.fs.File,
    file_count: *u32,
) !void {
    // First pass: collect all entries to determine structure
    var entries = std.ArrayListUnmanaged(std.fs.Dir.Entry){};
    defer entries.deinit(allocator);

    var iter = content_dir.iterate();
    while (try iter.next()) |entry| {
        try entries.append(allocator, entry);
    }

    // Count markdown files and check for index.md
    var md_count: usize = 0;
    var has_index = false;
    for (entries.items) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
            md_count += 1;
            if (std.mem.eql(u8, entry.name, "index.md")) {
                has_index = true;
            }
        }
    }

    // Sort entries for consistent ordering
    std.mem.sort(std.fs.Dir.Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: std.fs.Dir.Entry, b: std.fs.Dir.Entry) bool {
            // index.md first, then directories, then files alphabetically
            if (std.mem.eql(u8, a.name, "index.md")) return true;
            if (std.mem.eql(u8, b.name, "index.md")) return false;
            if (a.kind == .directory and b.kind != .directory) return true;
            if (a.kind != .directory and b.kind == .directory) return false;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    // If no index.md exists, generate an index page for this directory
    if (!has_index and rel_path.len > 0) {
        const dir_index = try generateDirectoryIndex(allocator, entries.items, rel_path);
        defer allocator.free(dir_index);

        // Get directory name for title
        const dir_name = std.fs.path.basename(rel_path);

        try partials.setContext("title", dir_name);
        try partials.setContext("content", dir_index);

        const full_html = try partials.render(html_template);
        defer allocator.free(full_html);

        const out_file = try output_dir.createFile("index.html", .{});
        defer out_file.close();
        try out_file.writeAll(full_html);

        try stdout.writeAll("  [GEN] ");
        try stdout.writeAll(rel_path);
        try stdout.writeAll("/index.html\n");

        file_count.* += 1;
    }

    // Process entries
    for (entries.items) |entry| {
        if (entry.kind == .directory) {
            // Create corresponding output directory
            var sub_content_dir = try content_dir.openDir(entry.name, .{ .iterate = true });
            defer sub_content_dir.close();

            // Build relative path for display
            const new_rel_path = if (rel_path.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_path, entry.name });
            defer allocator.free(new_rel_path);

            // Create output subdirectory
            try output_dir.makePath(entry.name);
            var sub_output_dir = try output_dir.openDir(entry.name, .{});
            defer sub_output_dir.close();

            // Recurse
            try processDirectory(allocator, sub_content_dir, sub_output_dir, new_rel_path, partials, html_template, stdout, file_count);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
            // Process markdown file
            const file = try content_dir.openFile(entry.name, .{});
            defer file.close();

            const markdown = try file.readToEndAlloc(allocator, 1024 * 1024);
            defer allocator.free(markdown);

            const html_content = md.toHtml(markdown);
            if (html_content == null) {
                try stdout.writeAll("  [FAIL] ");
                if (rel_path.len > 0) {
                    try stdout.writeAll(rel_path);
                    try stdout.writeAll("/");
                }
                try stdout.writeAll(entry.name);
                try stdout.writeAll("\n");
                continue;
            }
            defer c.free(html_content);

            const html_slice = std.mem.span(html_content.?);
            const title = entry.name[0 .. entry.name.len - 3];

            try partials.setContext("title", title);
            try partials.setContext("content", html_slice);

            const full_html = try partials.render(html_template);
            defer allocator.free(full_html);

            // Determine output path:
            // - If single .md file in directory -> name/index.html
            // - Otherwise -> name.html
            var output_name: []u8 = undefined;
            if (md_count == 1) {
                // Create subdirectory named after the file
                try output_dir.makePath(title);
                var sub_dir = try output_dir.openDir(title, .{});
                defer sub_dir.close();

                const out_file = try sub_dir.createFile("index.html", .{});
                defer out_file.close();
                try out_file.writeAll(full_html);

                output_name = try std.fmt.allocPrint(allocator, "{s}/index.html", .{title});
            } else {
                const filename = try std.fmt.allocPrint(allocator, "{s}.html", .{title});
                defer allocator.free(filename);

                const out_file = try output_dir.createFile(filename, .{});
                defer out_file.close();
                try out_file.writeAll(full_html);

                output_name = try std.fmt.allocPrint(allocator, "{s}.html", .{title});
            }
            defer allocator.free(output_name);

            // Print status
            try stdout.writeAll("  [OK] ");
            if (rel_path.len > 0) {
                try stdout.writeAll(rel_path);
                try stdout.writeAll("/");
            }
            try stdout.writeAll(entry.name);
            try stdout.writeAll(" -> public/");
            if (rel_path.len > 0) {
                try stdout.writeAll(rel_path);
                try stdout.writeAll("/");
            }
            try stdout.writeAll(output_name);
            try stdout.writeAll("\n");

            file_count.* += 1;
        }
    }
}
