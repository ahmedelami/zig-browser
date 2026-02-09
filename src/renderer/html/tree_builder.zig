const std = @import("std");

const dom_mod = @import("../dom.zig");
const css_inline = @import("../css_inline.zig");
const tag_mod = @import("tag.zig");
const html_entities = @import("entities.zig");
const html_tokenizer = @import("tokenizer.zig");

const Attribute = html_tokenizer.Attribute;

pub const StylesheetLink = struct {
    resource_id: u32,
    href: []const u8,
};

pub const ImageLink = struct {
    resource_id: u32,
    src: []const u8,
};

pub const Builder = struct {
    dom: *dom_mod.Dom,

    truncated: bool = false,
    max_nodes: usize = 25_000,
    max_text_bytes: usize = 1024 * 1024,
    total_text_bytes: usize = 0,

    open: [256]dom_mod.NodeId = undefined,
    open_len: usize = 0,

    in_title: bool = false,
    next_link_index: u32 = 1,

    stylesheet_out: ?*std.ArrayListUnmanaged(StylesheetLink) = null,
    max_stylesheets: usize = 16,
    next_stylesheet_id: u32 = 1,
    seen_stylesheet_hashes: [64]u64 = undefined,
    seen_stylesheet_len: usize = 0,

    image_out: ?*std.ArrayListUnmanaged(ImageLink) = null,
    max_images: usize = 24,
    next_image_id: u32 = 1,
    seen_image_hashes: [128]u64 = undefined,
    seen_image_ids: [128]u32 = undefined,
    seen_image_len: usize = 0,

    script_out: ?*std.ArrayListUnmanaged(dom_mod.NodeId) = null,
    max_scripts: usize = 64,

    pub fn init(
        dom: *dom_mod.Dom,
        stylesheet_out: ?*std.ArrayListUnmanaged(StylesheetLink),
        image_out: ?*std.ArrayListUnmanaged(ImageLink),
        script_out: ?*std.ArrayListUnmanaged(dom_mod.NodeId),
    ) Builder {
        var b: Builder = .{
            .dom = dom,
            .stylesheet_out = stylesheet_out,
            .image_out = image_out,
            .script_out = script_out,
        };
        b.open[0] = dom.root;
        b.open_len = 1;
        return b;
    }

    pub fn current(self: *const Builder) dom_mod.NodeId {
        return self.open[self.open_len - 1];
    }

    pub fn onStartTag(self: *Builder, name_lower: []const u8, attrs: []const Attribute, self_closing: bool) !void {
        if (self.truncated) return;

        const t = tag_mod.fromNameLower(name_lower);
        const raw_name: ?[]const u8 = if (t == .unknown) name_lower else null;

        const id = try self.dom.createElement(t, raw_name);
        self.dom.appendChild(self.current(), id);

        if (t == .body and self.dom.body == null) self.dom.body = id;

        if (findAttr(attrs, "id")) |id_raw| {
            const trimmed = std.mem.trim(u8, id_raw, " \t\r\n");
            if (trimmed.len != 0 and trimmed.len <= 256) {
                const a = self.dom.alloc();
                const copy = try a.dupe(u8, trimmed);
                self.dom.nodeMut(id).id = copy;
            }
        }
        if (findAttr(attrs, "class")) |class_raw| {
            const trimmed = std.mem.trim(u8, class_raw, " \t\r\n");
            if (trimmed.len != 0 and trimmed.len <= 1024) {
                const a = self.dom.alloc();
                const copy = try a.dupe(u8, trimmed);
                self.dom.nodeMut(id).class = copy;
            }
        }

        if (findAttr(attrs, "style")) |style_raw| {
            const trimmed = std.mem.trim(u8, style_raw, " \t\r\n");
            if (trimmed.len != 0 and trimmed.len <= 4096) {
                self.dom.nodeMut(id).inline_style = css_inline.parseInlineStyle(trimmed);
            }
        }

        if (t == .a) {
            if (findAttr(attrs, "href")) |href_raw| {
                const href_trim = std.mem.trim(u8, href_raw, " \t\r\n");
                if (href_trim.len != 0 and href_trim.len <= 2048) {
                    const a = self.dom.alloc();
                    const href_copy = try html_entities.decodeHtmlEntitiesAlloc(a, href_trim);
                    const n = self.dom.nodeMut(id);
                    n.href = href_copy;
                    n.link_index = self.next_link_index;
                    self.next_link_index +%= 1;
                }
            }
        }

        if (t == .link) {
            if (self.stylesheet_out) |out| {
                if (out.items.len < self.max_stylesheets) {
                    const rel_raw = findAttr(attrs, "rel") orelse "";
                    if (relHasToken(rel_raw, "stylesheet")) {
                        if (findAttr(attrs, "href")) |href_raw| {
                            const href_trim = std.mem.trim(u8, href_raw, " \t\r\n");
                            if (href_trim.len != 0 and href_trim.len <= 2048) {
                                const a = self.dom.alloc();
                                const href_copy = try html_entities.decodeHtmlEntitiesAlloc(a, href_trim);
                                const h = std.hash.Wyhash.hash(0, href_copy);
                                if (!seenStylesheetHash(self, h)) {
                                    rememberStylesheetHash(self, h);
                                    const rid = self.next_stylesheet_id;
                                    self.next_stylesheet_id +%= 1;
                                    out.append(a, .{ .resource_id = rid, .href = href_copy }) catch {};
                                }
                            }
                        }
                    }
                }
            }
        }

        if (t == .img) {
            if (self.image_out) |out| {
                if (out.items.len < self.max_images) {
                    if (findAttr(attrs, "alt")) |alt_raw| {
                        const alt_trim = std.mem.trim(u8, alt_raw, " \t\r\n");
                        if (alt_trim.len != 0 and alt_trim.len <= 256) {
                            const a = self.dom.alloc();
                            const alt_copy = try a.dupe(u8, alt_trim);
                            self.dom.nodeMut(id).img_alt = alt_copy;
                        }
                    }

                    if (findAttr(attrs, "src")) |src_raw| {
                        const src_trim = std.mem.trim(u8, src_raw, " \t\r\n");
                        if (src_trim.len != 0 and src_trim.len <= 2048) {
                            const a = self.dom.alloc();
                            const src_copy = try html_entities.decodeHtmlEntitiesAlloc(a, src_trim);
                            const h = std.hash.Wyhash.hash(0, src_copy);
                            const rid = seenImageId(self, h) orelse blk: {
                                const next: u32 = 0x8000_0000 | self.next_image_id;
                                self.next_image_id +%= 1;
                                rememberImage(self, h, next);
                                out.append(a, .{ .resource_id = next, .src = src_copy }) catch {};
                                break :blk next;
                            };
                            self.dom.nodeMut(id).img_resource_id = rid;
                        }
                    }
                }
            }
        }

        if (t == .title) {
            self.in_title = true;
            self.dom.title.items.len = 0;
        }

        const is_void = tag_mod.isVoid(t);
        if (self_closing or is_void) return;

        if (self.open_len < self.open.len) {
            self.open[self.open_len] = id;
            self.open_len += 1;
        }

        if (self.dom.nodes.items.len >= self.max_nodes) self.truncated = true;
    }

    pub fn onEndTag(self: *Builder, name_lower: []const u8) !void {
        if (self.open_len <= 1) return;

        const t = tag_mod.fromNameLower(name_lower);
        if (t == .title) self.in_title = false;

        var i: usize = self.open_len;
        while (i > 1) : (i -= 1) {
            const id = self.open[i - 1];
            const n = self.dom.node(id).*;
            if (n.kind == .element and n.tag == t) {
                if (t == .script) queueInlineScript(self, id);
                self.open_len = i - 1;
                return;
            }
        }
    }

    pub fn onText(self: *Builder, bytes: []const u8) !void {
        if (bytes.len == 0) return;

        if (self.in_title) {
            // Store a tiny title string for future UI; keep it bounded.
            if (self.dom.title.items.len < 256) {
                const remaining = 256 - self.dom.title.items.len;
                const n = @min(remaining, bytes.len);
                self.dom.title.appendSlice(self.dom.alloc(), bytes[0..n]) catch {};
            }
        }

        const cur = self.current();
        const cur_node = self.dom.node(cur).*;
        if (cur_node.kind == .element and (cur_node.tag == .script or cur_node.tag == .style)) {
            if (self.truncated) return;
            if (cur_node.tag == .script) {
                const max_inline_script_bytes: usize = 256 * 1024;
                const n = self.dom.nodeMut(cur);
                if (n.script_overflow) return;
                if (bytes.len == 0 or bytes.len >= max_inline_script_bytes) {
                    n.script_overflow = true;
                    n.script_text = null;
                    return;
                }
                const a = self.dom.alloc();
                n.script_text = a.dupe(u8, bytes) catch {
                    n.script_overflow = true;
                    n.script_text = null;
                    return;
                };
                return;
            }

            // Inline <style> bytes are captured for CSS parsing later, but should not count toward the
            // visible text budget (avoid truncating a page because of large stylesheets).
            const id = try self.dom.createText(bytes);
            self.dom.appendChild(cur, id);
            if (self.dom.nodes.items.len >= self.max_nodes) self.truncated = true;
            return;
        }

        if (self.truncated) return;
        if (self.total_text_bytes + bytes.len > self.max_text_bytes) {
            self.truncated = true;
            return;
        }

        const id = try self.dom.createText(bytes);
        self.dom.appendChild(cur, id);
        self.total_text_bytes += bytes.len;

        if (self.dom.nodes.items.len >= self.max_nodes) self.truncated = true;
    }
};

fn queueInlineScript(self: *Builder, id: dom_mod.NodeId) void {
    const out = self.script_out orelse return;
    if (out.items.len >= self.max_scripts) return;

    const n = self.dom.node(id).*;
    if (n.kind != .element or n.tag != .script) return;
    if (n.script_overflow) return;
    if (n.script_text == null) return;

    out.append(self.dom.alloc(), id) catch {};
}

fn findAttr(attrs: []const Attribute, name: []const u8) ?[]const u8 {
    for (attrs) |a| {
        if (std.mem.eql(u8, a.name, name)) return a.value;
    }
    return null;
}

fn relHasToken(rel_raw: []const u8, token: []const u8) bool {
    const rel = std.mem.trim(u8, rel_raw, " \t\r\n");
    if (rel.len == 0) return false;
    var it = std.mem.tokenizeAny(u8, rel, " \t\r\n");
    while (it.next()) |t| {
        if (std.ascii.eqlIgnoreCase(t, token)) return true;
    }
    return false;
}

fn seenStylesheetHash(self: *const Builder, h: u64) bool {
    for (self.seen_stylesheet_hashes[0..self.seen_stylesheet_len]) |prev| {
        if (prev == h) return true;
    }
    return false;
}

fn rememberStylesheetHash(self: *Builder, h: u64) void {
    if (self.seen_stylesheet_len >= self.seen_stylesheet_hashes.len) return;
    self.seen_stylesheet_hashes[self.seen_stylesheet_len] = h;
    self.seen_stylesheet_len += 1;
}

fn seenImageId(self: *const Builder, h: u64) ?u32 {
    for (self.seen_image_hashes[0..self.seen_image_len], self.seen_image_ids[0..self.seen_image_len]) |prev, id| {
        if (prev == h) return id;
    }
    return null;
}

fn rememberImage(self: *Builder, h: u64, resource_id: u32) void {
    if (self.seen_image_len >= self.seen_image_hashes.len) return;
    self.seen_image_hashes[self.seen_image_len] = h;
    self.seen_image_ids[self.seen_image_len] = resource_id;
    self.seen_image_len += 1;
}
