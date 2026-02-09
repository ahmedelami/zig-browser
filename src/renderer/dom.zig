const std = @import("std");

const tag_mod = @import("html/tag.zig");
pub const Tag = tag_mod.Tag;

const css = @import("css.zig");

pub const NodeId = u32;

pub const Kind = enum(u8) { document, element, text };

pub const Node = struct {
    kind: Kind,
    parent: ?NodeId = null,
    first_child: ?NodeId = null,
    last_child: ?NodeId = null,
    next_sibling: ?NodeId = null,

    tag: Tag = .document,
    raw_name: ?[]const u8 = null,
    id: ?[]const u8 = null,
    class: ?[]const u8 = null,
    inline_style: css.InlineStyle = .{},
    href: ?[]const u8 = null,
    link_index: u32 = 0,
    img_resource_id: u32 = 0,
    img_alt: ?[]const u8 = null,
    text: ?[]const u8 = null,

    // Inline script support (v0): capture + run once, best-effort.
    script_text: ?[]const u8 = null,
    script_overflow: bool = false,
    script_ran: bool = false,
};

pub const Dom = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node),
    root: NodeId,
    body: ?NodeId = null,
    title: std.ArrayList(u8),

    pub fn init(parent_alloc: std.mem.Allocator) !Dom {
        var arena = std.heap.ArenaAllocator.init(parent_alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        var nodes = try std.ArrayList(Node).initCapacity(a, 1024);
        errdefer nodes.deinit(a);

        try nodes.append(a, .{ .kind = .document, .tag = .document });

        var title = try std.ArrayList(u8).initCapacity(a, 64);
        errdefer title.deinit(a);

        return .{
            .arena = arena,
            .nodes = nodes,
            .root = 0,
            .title = title,
        };
    }

    pub fn deinit(self: *Dom) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn alloc(self: *Dom) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn node(self: *const Dom, id: NodeId) *const Node {
        return &self.nodes.items[@intCast(id)];
    }

    pub fn nodeMut(self: *Dom, id: NodeId) *Node {
        return &self.nodes.items[@intCast(id)];
    }

    pub fn appendChild(self: *Dom, parent: NodeId, child: NodeId) void {
        const p = self.nodeMut(parent);
        const c = self.nodeMut(child);
        c.parent = parent;

        if (p.first_child == null) {
            p.first_child = child;
            p.last_child = child;
            return;
        }

        const last = p.last_child.?;
        self.nodeMut(last).next_sibling = child;
        p.last_child = child;
    }

    pub fn createElement(self: *Dom, tag: Tag, raw_name: ?[]const u8) !NodeId {
        const a = self.alloc();
        var name_copy: ?[]const u8 = null;
        if (raw_name) |s| name_copy = try a.dupe(u8, s);

        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(a, .{
            .kind = .element,
            .tag = tag,
            .raw_name = name_copy,
        });
        return id;
    }

    pub fn createText(self: *Dom, bytes: []const u8) !NodeId {
        const a = self.alloc();
        const copy = try a.dupe(u8, bytes);
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(a, .{
            .kind = .text,
            .tag = .unknown,
            .text = copy,
        });
        return id;
    }

    pub fn dump(self: *const Dom, w: anytype, max_nodes: usize) !void {
        var seen: usize = 0;
        try dumpNode(self, w, self.root, 0, &seen, max_nodes);
        if (seen >= max_nodes) try w.writeAll("… (truncated)\n");
    }

    fn dumpNode(self: *const Dom, w: anytype, id: NodeId, depth: usize, seen: *usize, max_nodes: usize) !void {
        if (seen.* >= max_nodes) return;
        seen.* += 1;

        const n = self.node(id).*;
        for (0..depth) |_| try w.writeAll("  ");
        switch (n.kind) {
            .document => {
                try w.writeAll(tag_mod.name(.document));
                try w.writeAll("\n");
            },
            .element => {
                const label = if (n.tag == .unknown and n.raw_name != null) n.raw_name.? else tag_mod.name(n.tag);
                try w.writeAll("<");
                try w.writeAll(label);
                if (n.tag == .a) {
                    if (n.href) |h| {
                        try w.writeAll(" href=\"");
                        try writeEscapedPreview(w, h, 80);
                        try w.writeAll("\"");
                    }
                }
                if (n.tag == .img) {
                    if (n.img_alt) |alt| {
                        try w.writeAll(" alt=\"");
                        try writeEscapedPreview(w, alt, 80);
                        try w.writeAll("\"");
                    }
                    if (n.img_resource_id != 0) {
                        var buf: [32]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, " rid={d}", .{n.img_resource_id}) catch null;
                        if (s) |t| try w.writeAll(t);
                    }
                }
                if (n.tag == .script) {
                    if (n.script_overflow) try w.writeAll(" overflow=true");
                    if (n.script_text) |src| {
                        var buf: [48]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, " bytes={d}", .{src.len}) catch null;
                        if (s) |t| try w.writeAll(t);
                        try w.writeAll(" preview=\"");
                        try writeEscapedPreview(w, src, 80);
                        try w.writeAll("\"");
                    }
                }
                try w.writeAll(">\n");
            },
            .text => {
                try w.writeAll("\"");
                if (n.text) |t| try writeEscapedPreview(w, t, 80);
                try w.writeAll("\"\n");
            },
        }

        var child_opt = n.first_child;
        while (child_opt) |child| {
            try dumpNode(self, w, child, depth + 1, seen, max_nodes);
            if (seen.* >= max_nodes) return;
            child_opt = self.node(child).next_sibling;
        }
    }

    pub fn writeEscapedPreview(w: anytype, bytes: []const u8, max_len: usize) !void {
        const n = @min(bytes.len, max_len);
        for (bytes[0..n]) |c| {
            switch (c) {
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => {
                    if (c >= 0x20 and c < 0x7F) try w.writeByte(c) else try w.writeByte('.');
                },
            }
        }
        if (bytes.len > n) try w.writeAll("…");
    }
};
