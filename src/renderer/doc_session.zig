const std = @import("std");

const dom_mod = @import("dom.zig");
const html_tokenizer = @import("html/tokenizer.zig");
const html_tree_builder = @import("html/tree_builder.zig");
const css = @import("css.zig");
const png = @import("image/png.zig");

pub const DocSession = struct {
    alloc: std.mem.Allocator = undefined,
    dom: dom_mod.Dom = undefined,
    builder: html_tree_builder.Builder = undefined,
    tokenizer: html_tokenizer.Tokenizer = undefined,

    pending_stylesheets: std.ArrayListUnmanaged(html_tree_builder.StylesheetLink) = .{},
    pending_images: std.ArrayListUnmanaged(html_tree_builder.ImageLink) = .{},
    scripts_ready: std.ArrayListUnmanaged(dom_mod.NodeId) = .{},
    scripts_executed: usize = 0,
    stylesheets: std.ArrayList(Stylesheet) = undefined,
    images: std.ArrayList(Image) = undefined,
    stylesheet_total: u32 = 0,
    stylesheet_done: u32 = 0,
    css_rules: std.ArrayListUnmanaged(css.Rule) = .{},
    html_done: bool = false,
    done_sent: bool = false,

    viewport_w: u32 = 0,
    viewport_h: u32 = 0,
    scroll_y: u32 = 0,

    bytes_received: usize = 0,
    bytes_processed: usize = 0,
    truncated: bool = false,

    pub const max_stylesheet_bytes: usize = 1024 * 1024;
    pub const max_image_bytes: usize = 4 * 1024 * 1024;
    pub const max_image_pixels: usize = 512 * 512;
    pub const max_total_css_rules: usize = 4096;

    const Stylesheet = struct {
        resource_id: u32,
        href: []const u8,
        status_code: u32 = 0,
        net_result: u32 = 0,
        total_sent: u32 = 0,
        bytes: std.ArrayList(u8),
        overflow: bool = false,
        done: bool = false,
    };

    const Image = struct {
        resource_id: u32,
        src: []const u8,
        status_code: u32 = 0,
        net_result: u32 = 0,
        total_sent: u32 = 0,
        bytes: std.ArrayList(u8),
        overflow: bool = false,
        done: bool = false,
        decoded: ?png.DecodedImage = null,
    };

    pub fn init(self: *DocSession, alloc: std.mem.Allocator, viewport_w: u32, viewport_h: u32) !void {
        self.alloc = alloc;
        self.dom = try dom_mod.Dom.init(alloc);
        errdefer self.dom.deinit();

        self.tokenizer = try html_tokenizer.Tokenizer.init(alloc);
        errdefer self.tokenizer.deinit();

        self.stylesheets = try std.ArrayList(Stylesheet).initCapacity(alloc, 8);
        errdefer self.stylesheets.deinit(alloc);

        self.images = try std.ArrayList(Image).initCapacity(alloc, 8);
        errdefer self.images.deinit(alloc);

        self.pending_stylesheets = .{};
        self.pending_images = .{};
        self.scripts_ready = .{};
        self.scripts_executed = 0;
        self.builder = html_tree_builder.Builder.init(&self.dom, &self.pending_stylesheets, &self.pending_images, &self.scripts_ready);

        self.stylesheet_total = 0;
        self.stylesheet_done = 0;
        self.css_rules = .{};
        self.html_done = false;
        self.done_sent = false;

        self.viewport_w = viewport_w;
        self.viewport_h = viewport_h;
        self.scroll_y = 0;
        self.bytes_received = 0;
        self.bytes_processed = 0;
        self.truncated = false;
    }

    pub fn deinit(self: *DocSession) void {
        for (self.stylesheets.items) |*ss| ss.bytes.deinit(self.alloc);
        self.stylesheets.deinit(self.alloc);
        for (self.images.items) |*img| {
            img.bytes.deinit(self.alloc);
            if (img.decoded) |*d| png.freeDecoded(self.alloc, d);
        }
        self.images.deinit(self.alloc);
        self.css_rules.deinit(self.alloc);
        self.tokenizer.deinit();
        self.dom.deinit();
        self.* = undefined;
    }

    pub fn ensureStylesheet(self: *DocSession, resource_id: u32, href: []const u8) void {
        for (self.stylesheets.items) |s| {
            if (s.resource_id == resource_id) return;
        }
        if (self.stylesheets.items.len >= self.builder.max_stylesheets) return;

        var bytes = std.ArrayList(u8).initCapacity(self.alloc, 16 * 1024) catch return;
        self.stylesheets.append(self.alloc, .{ .resource_id = resource_id, .href = href, .bytes = bytes }) catch {
            bytes.deinit(self.alloc);
            return;
        };
        self.stylesheet_total +%= 1;
    }

    pub fn stylesheetMut(self: *DocSession, resource_id: u32) ?*Stylesheet {
        for (self.stylesheets.items) |*s| {
            if (s.resource_id == resource_id) return s;
        }
        return null;
    }

    pub fn ensureImage(self: *DocSession, resource_id: u32, src: []const u8) void {
        for (self.images.items) |img| {
            if (img.resource_id == resource_id) return;
        }
        if (self.images.items.len >= self.builder.max_images) return;

        var bytes = std.ArrayList(u8).initCapacity(self.alloc, 64 * 1024) catch return;
        self.images.append(self.alloc, .{ .resource_id = resource_id, .src = src, .bytes = bytes }) catch {
            bytes.deinit(self.alloc);
        };
    }

    pub fn imageMut(self: *DocSession, resource_id: u32) ?*Image {
        for (self.images.items) |*img| {
            if (img.resource_id == resource_id) return img;
        }
        return null;
    }

    pub fn feedChunk(self: *DocSession, chunk: []const u8) !void {
        const max_doc_bytes: usize = 8 * 1024 * 1024;
        self.bytes_received += chunk.len;

        const remaining = max_doc_bytes -| self.bytes_processed;
        if (remaining == 0) {
            self.truncated = true;
            return;
        }

        const n = @min(remaining, chunk.len);
        if (n != chunk.len) self.truncated = true;

        try self.tokenizer.feed(chunk[0..n], &self.builder);
        self.bytes_processed += n;

        if (self.builder.truncated) self.truncated = true;
    }

    pub fn finish(self: *DocSession) !void {
        try self.tokenizer.finish(&self.builder);
        if (self.builder.truncated) self.truncated = true;
    }
};
