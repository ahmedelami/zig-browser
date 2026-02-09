const std = @import("std");
const shared = @import("shared");

const display_list = shared.display_list;

const dom_mod = @import("../dom.zig");
const css = @import("../css.zig");
const tag_mod = @import("../html/tag.zig");

pub const Options = struct {
    viewport_w: i32,
    viewport_h: i32,
    clip_y0: i32 = std.math.minInt(i32),
    clip_y1: i32 = std.math.maxInt(i32),
    x0: i32 = 16,
    y0: i32 = 32,
    margin_right: i32 = 16,
    line_h: i32 = 10,
    bg: u32 = 0xFF111418,
    color_text: u32 = 0xFFE6E6E6,
    color_link: u32 = 0xFF61AFEF,
    color_heading: u32 = 0xFFF9D65C,
    color_muted: u32 = 0xFF9AA4B2,
    max_commands: usize = 4000,
    css_rules: []const css.Rule = &.{},
    images: []const ImageView = &.{},
};

pub const Result = struct {
    commands: usize,
    truncated: bool,
};

pub const LinkRect = struct {
    link_index: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const ImageView = struct {
    resource_id: u32,
    width: i32,
    height: i32,
    bgra: []const u8,
};

pub fn paintDom(
    alloc: std.mem.Allocator,
    dl: *display_list.Builder,
    dom: *const dom_mod.Dom,
    opts: Options,
    dump: ?*std.ArrayList(u8),
    rects: ?*std.ArrayList(LinkRect),
) !Result {
    var w = try FlowWriter.init(alloc, dl, opts, dump, rects);
    defer w.deinit();

    const start = dom.body orelse dom.root;
    try walk(dom, start, &w, .{ .color = opts.color_text, .bg = null });
    try w.finish();

    return .{ .commands = w.commands_emitted, .truncated = w.truncated };
}

const Context = struct {
    pre: bool = false,
    link_index: u32 = 0,
    list_depth: u8 = 0,
    color: u32,
    bg: ?u32 = null,
};

fn walk(dom: *const dom_mod.Dom, id: dom_mod.NodeId, w: *FlowWriter, ctx: Context) !void {
    if (w.truncated) return;

    const n = dom.node(id).*;
    switch (n.kind) {
        .document => {},
        .text => {
            if (n.text) |t| {
                try w.writeText(t, ctx.pre, ctx.color, ctx.link_index, ctx.bg);
            }
        },
        .element => {
            const t = n.tag;

            // Skip non-rendered sections for now.
            if (t == .head or t == .script or t == .style or t == .meta or t == .link or t == .title) return;

            const decls = css.computeForElement(w.opts.css_rules, t, n.id, n.class);
            const inl = n.inline_style;

            // Self-contained void nodes.
            if (t == .br) {
                try w.newline();
                return;
            }
            if (t == .hr) {
                try w.blockBreak();
                try w.hrLine();
                try w.blockBreak();
                return;
            }
            if (t == .img) {
                if (n.img_resource_id != 0 and w.opts.images.len != 0) {
                    if (findImageView(w.opts.images, n.img_resource_id)) |img| {
                        try w.bitmap(img, ctx.link_index);
                        return;
                    }
                }
                if (n.img_alt) |alt| {
                    const trimmed = std.mem.trim(u8, alt, " \t\r\n");
                    if (trimmed.len != 0) {
                        try w.writeText(trimmed, false, w.opts.color_muted, ctx.link_index, ctx.bg);
                        return;
                    }
                }
                try w.writeText("[image]", false, w.opts.color_muted, ctx.link_index, ctx.bg);
                return;
            }

            var child_ctx = ctx;
            if (tag_mod.isPreformatted(t)) child_ctx.pre = true;

            if (decls.background) |c| child_ctx.bg = c;
            if (inl.background) |c| child_ctx.bg = c;

            if (inl.color) |c| {
                child_ctx.color = c;
            } else if (decls.color) |c| {
                child_ctx.color = c;
            } else if (tag_mod.isHeading(t)) {
                child_ctx.color = w.opts.color_heading;
            } else if (t == .a) {
                child_ctx.color = w.opts.color_link;
            }

            const is_blockish = tag_mod.isBlock(t) or t == .li;

            const mt_raw: i32 = inl.margin.top orelse decls.margin.top orelse 0;
            const mr_raw: i32 = inl.margin.right orelse decls.margin.right orelse 0;
            const mb_raw: i32 = inl.margin.bottom orelse decls.margin.bottom orelse 0;
            const ml_raw: i32 = inl.margin.left orelse decls.margin.left orelse 0;

            const pt_raw: i32 = inl.padding.top orelse decls.padding.top orelse 0;
            const pr_raw: i32 = inl.padding.right orelse decls.padding.right orelse 0;
            const pb_raw: i32 = inl.padding.bottom orelse decls.padding.bottom orelse 0;
            const pl_raw: i32 = inl.padding.left orelse decls.padding.left orelse 0;

            const mt: i32 = std.math.clamp(mt_raw, -256, 256);
            const mr: i32 = std.math.clamp(mr_raw, -256, 256);
            const mb: i32 = std.math.clamp(mb_raw, -256, 256);
            const ml: i32 = std.math.clamp(ml_raw, -256, 256);

            const pt: i32 = std.math.clamp(pt_raw, 0, 256);
            const pr: i32 = std.math.clamp(pr_raw, 0, 256);
            const pb: i32 = std.math.clamp(pb_raw, 0, 256);
            const pl: i32 = std.math.clamp(pl_raw, 0, 256);

            const inset_left: i32 = ml + pl;
            const inset_right: i32 = mr + pr;

            const saved_x0 = w.x0;
            const saved_mr = w.margin_right;

            if (is_blockish) {
                try w.blockBreak();
                if (mt > 0) try w.vspace(mt);

                var new_x0 = saved_x0 + inset_left;
                var new_mr = saved_mr + inset_right;
                if (t == .body or t == .html) {
                    if (inl.margin.left != null or decls.margin.left != null) new_x0 = inset_left;
                    if (inl.margin.right != null or decls.margin.right != null) new_mr = inset_right;
                }
                try w.setInsets(new_x0, new_mr);
                if (pt != 0) try w.vspace(pt);
            }

            if (t == .a) {
                if (n.href != null and n.link_index != 0) {
                    child_ctx.link_index = n.link_index;
                    var buf: [32]u8 = undefined;
                    if (std.fmt.bufPrint(&buf, "[{d}] ", .{n.link_index})) |s| {
                        try w.writeText(s, true, child_ctx.color, child_ctx.link_index, child_ctx.bg);
                    } else |_| {}
                }
            }
            if (t == .ul or t == .ol) child_ctx.list_depth +|= 1;

            if (t == .li) {
                const depth = child_ctx.list_depth;
                try w.newline();
                try w.indent(depth);
                try w.writeText("- ", false, child_ctx.color, 0, child_ctx.bg);
            }

            if (tag_mod.isHeading(t)) {
                try w.newline();
            }

            var child_opt = n.first_child;
            while (child_opt) |child| {
                try walk(dom, child, w, child_ctx);
                child_opt = dom.node(child).next_sibling;
                if (w.truncated) break;
            }

            if (is_blockish) {
                if (pb != 0) try w.vspace(pb);
                try w.setInsets(saved_x0, saved_mr);
                if (mb > 0) try w.vspace(mb);
                try w.blockBreak();
            }
        },
    }
}

const FlowWriter = struct {
    alloc: std.mem.Allocator,
    dl: *display_list.Builder,
    opts: Options,
    dump: ?*std.ArrayList(u8),
    rects: ?*std.ArrayList(LinkRect),

    line: std.ArrayList(u8),
    y: i32,
    x0: i32,
    margin_right: i32,
    line_color: u32,
    line_link_index: u32 = 0,
    line_bg: ?u32 = null,
    active_link_index: u32 = 0,
    active_bg: ?u32 = null,
    commands_emitted: usize = 0,
    truncated: bool = false,

    pub fn init(
        alloc: std.mem.Allocator,
        dl: *display_list.Builder,
        opts: Options,
        dump: ?*std.ArrayList(u8),
        rects: ?*std.ArrayList(LinkRect),
    ) !FlowWriter {
        var line = try std.ArrayList(u8).initCapacity(alloc, 256);
        errdefer line.deinit(alloc);
        return .{
            .alloc = alloc,
            .dl = dl,
            .opts = opts,
            .dump = dump,
            .rects = rects,
            .line = line,
            .y = opts.y0,
            .x0 = opts.x0,
            .margin_right = opts.margin_right,
            .line_color = opts.color_text,
        };
    }

    pub fn deinit(self: *FlowWriter) void {
        self.line.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn finish(self: *FlowWriter) !void {
        try self.flushLine();
    }

    fn maxCols(self: *const FlowWriter) usize {
        const usable = self.opts.viewport_w - self.x0 - self.margin_right;
        if (usable <= 0) return 1;
        return @max(1, @as(usize, @intCast(@divTrunc(usable, 8))));
    }

    pub fn blockBreak(self: *FlowWriter) !void {
        try self.flushLine();
        if (self.y != self.opts.y0) self.y += self.opts.line_h;
        if (self.y >= self.opts.viewport_h) self.truncated = true;
    }

    pub fn vspace(self: *FlowWriter, px: i32) !void {
        if (px <= 0) return;
        try self.flushLine();
        self.y += px;
        if (self.y >= self.opts.viewport_h) self.truncated = true;
    }

    pub fn setInsets(self: *FlowWriter, x0: i32, margin_right: i32) !void {
        const new_x0 = std.math.clamp(x0, 0, self.opts.viewport_w);
        const new_mr = std.math.clamp(margin_right, 0, self.opts.viewport_w);
        if (self.x0 == new_x0 and self.margin_right == new_mr) return;
        try self.flushLine();
        self.x0 = new_x0;
        self.margin_right = new_mr;
    }

    pub fn newline(self: *FlowWriter) !void {
        if (self.line.items.len != 0) {
            try self.flushLine();
        } else {
            self.y += self.opts.line_h;
        }
        if (self.y >= self.opts.viewport_h) self.truncated = true;
    }

    pub fn hrLine(self: *FlowWriter) !void {
        if (self.truncated) return;
        if (self.commands_emitted >= self.opts.max_commands) {
            self.truncated = true;
            return;
        }
        const w_px = self.opts.viewport_w - self.x0 - self.margin_right;
        if (w_px <= 0) return;
        const in_clip = (self.y + self.opts.line_h > self.opts.clip_y0) and (self.y < self.opts.clip_y1);
        if (in_clip) {
            try self.dl.rect(self.x0, self.y, w_px, 1, 0xFF2A2F3A);
            self.commands_emitted += 1;
        }
        self.y += self.opts.line_h;
        if (self.y >= self.opts.viewport_h) self.truncated = true;
    }

    pub fn bitmap(self: *FlowWriter, img: ImageView, link_index: u32) !void {
        if (self.truncated) return;

        try self.flushLine();
        if (img.width <= 0 or img.height <= 0) return;
        const in_clip = (self.y + img.height > self.opts.clip_y0) and (self.y < self.opts.clip_y1);
        if (in_clip) {
            if (self.commands_emitted >= self.opts.max_commands) {
                self.truncated = true;
                return;
            }
            try self.dl.bitmap(self.x0, self.y, img.width, img.height, img.bgra);
            self.commands_emitted += 1;

            if (link_index != 0) {
                if (self.rects) |rects| {
                    if (rects.items.len < 8192) {
                        rects.append(self.alloc, .{
                            .link_index = link_index,
                            .x = self.x0,
                            .y = self.y,
                            .w = img.width,
                            .h = img.height,
                        }) catch {};
                    }
                }
            }
        }

        self.y += img.height + self.opts.line_h;
        if (self.y >= self.opts.viewport_h) self.truncated = true;
    }

    pub fn indent(self: *FlowWriter, depth: u8) !void {
        if (self.line.items.len != 0) return;
        self.line_link_index = self.active_link_index;
        self.line_bg = self.active_bg;
        const spaces: usize = @as(usize, depth) * 2;
        for (0..spaces) |_| {
            try self.line.append(self.alloc, ' ');
        }
    }

    pub fn writeText(self: *FlowWriter, bytes: []const u8, pre: bool, color: u32, link_index: u32, bg: ?u32) !void {
        if (self.truncated) return;

        const prev_active = self.active_link_index;
        self.active_link_index = link_index;
        defer self.active_link_index = prev_active;

        const prev_bg = self.active_bg;
        self.active_bg = bg;
        defer self.active_bg = prev_bg;

        if (self.line.items.len != 0 and (self.line_link_index != link_index or self.line_bg != bg)) {
            try self.flushLine();
        }

        self.ensureLineLinkIndex();
        self.ensureLineBg();
        try self.ensureColor(color);
        if (pre) return try self.writePre(bytes, color);
        return try self.writeCollapsed(bytes, color);
    }

    fn ensureLineLinkIndex(self: *FlowWriter) void {
        if (self.line.items.len == 0) self.line_link_index = self.active_link_index;
    }

    fn ensureLineBg(self: *FlowWriter) void {
        if (self.line.items.len == 0) self.line_bg = self.active_bg;
    }

    fn writeCollapsed(self: *FlowWriter, bytes: []const u8, color: u32) !void {
        var i: usize = 0;
        var in_space = false;
        while (i < bytes.len) : (i += 1) {
            const c = bytes[i];
            if (isSpace(c)) {
                in_space = true;
                continue;
            }
            if (in_space) {
                try self.appendWord(" ", color, true);
                in_space = false;
            }

            // Read a word.
            const start = i;
            var j = i;
            while (j < bytes.len and !isSpace(bytes[j])) : (j += 1) {}
            const word = bytes[start..j];
            try self.appendWord(word, color, false);
            i = j - 1;
        }
    }

    fn writePre(self: *FlowWriter, bytes: []const u8, color: u32) !void {
        const max_cols = self.maxCols();
        for (bytes) |c| {
            if (self.truncated) return;
            switch (c) {
                '\n' => try self.newline(),
                '\r' => {},
                '\t' => {
                    try self.appendByte(' ', color);
                    try self.appendByte(' ', color);
                    try self.appendByte(' ', color);
                    try self.appendByte(' ', color);
                },
                else => try self.appendByte(if (c >= 0x20) c else ' ', color),
            }

            if (self.line.items.len >= max_cols) try self.newline();
        }
    }

    fn appendWord(self: *FlowWriter, word: []const u8, color: u32, is_space: bool) !void {
        if (self.truncated) return;
        if (word.len == 0) return;

        self.ensureLineLinkIndex();
        self.ensureLineBg();
        try self.ensureColor(color);
        const max_cols = self.maxCols();
        if (is_space) {
            if (self.line.items.len == 0) return;
            if (self.line.items[self.line.items.len - 1] == ' ') return;
        }

        if (self.line.items.len + word.len > max_cols) {
            if (self.line.items.len != 0) try self.flushLine();
            if (word.len > max_cols) {
                var off: usize = 0;
                while (off < word.len and !self.truncated) {
                    const n = @min(max_cols, word.len - off);
                    self.ensureLineLinkIndex();
                    self.ensureLineBg();
                    try self.line.appendSlice(self.alloc, word[off .. off + n]);
                    off += n;
                    self.line_color = color;
                    try self.flushLine();
                }
                return;
            }
        }

        self.ensureLineLinkIndex();
        self.ensureLineBg();
        try self.line.appendSlice(self.alloc, word);
    }

    fn appendByte(self: *FlowWriter, b: u8, color: u32) !void {
        self.ensureLineLinkIndex();
        self.ensureLineBg();
        try self.ensureColor(color);
        const max_cols = self.maxCols();
        if (self.line.items.len >= max_cols) try self.newline();
        try self.line.append(self.alloc, b);
    }

    fn ensureColor(self: *FlowWriter, color: u32) !void {
        if (self.line.items.len == 0) {
            self.line_color = color;
            return;
        }
        if (self.line_color != color) {
            try self.flushLine();
            self.line_color = color;
        }
    }

    fn flushLine(self: *FlowWriter) !void {
        if (self.truncated) return;
        if (self.line.items.len == 0) return;
        const in_clip = (self.y + self.opts.line_h > self.opts.clip_y0) and (self.y < self.opts.clip_y1);
        if (!in_clip) {
            self.line.items.len = 0;
            self.line_link_index = 0;
            self.line_bg = null;
            self.y += self.opts.line_h;
            if (self.y >= self.opts.viewport_h) self.truncated = true;
            return;
        }
        const need_bg = (self.line_bg != null and self.line_bg.? != self.opts.bg);
        const needed_cmds: usize = if (need_bg) 2 else 1;
        if (self.commands_emitted + needed_cmds > self.opts.max_commands) {
            self.truncated = true;
            self.line.items.len = 0;
            self.line_link_index = 0;
            self.line_bg = null;
            return;
        }

        if (need_bg) {
            var w_px: i32 = self.opts.viewport_w - self.x0 - self.margin_right;
            if (w_px < 0) w_px = 0;
            try self.dl.rect(self.x0, self.y, w_px, self.opts.line_h, self.line_bg.?);
            self.commands_emitted += 1;
        }
        try self.dl.text(self.x0, self.y, self.line_color, self.line.items);
        self.commands_emitted += 1;

        if (self.line_link_index != 0) {
            if (self.rects) |rects| {
                if (rects.items.len < 8192) {
                    const y0 = self.y;
                    var w_px: i32 = @intCast(self.line.items.len * 8);
                    var max_w_px: i32 = self.opts.viewport_w - self.x0 - self.margin_right;
                    if (max_w_px < 0) max_w_px = 0;
                    if (w_px > max_w_px) w_px = max_w_px;
                    if (w_px < 0) w_px = 0;
                    rects.append(self.alloc, .{
                        .link_index = self.line_link_index,
                        .x = self.x0,
                        .y = y0,
                        .w = w_px,
                        .h = self.opts.line_h,
                    }) catch {};
                }
            }
        }

        if (self.dump) |d| {
            var buf: [256]u8 = undefined;
            const bg = self.line_bg orelse self.opts.bg;
            const header = std.fmt.bufPrint(
                &buf,
                "y={d} fg=0x{X:0>8} bg=0x{X:0>8} len={d} text=\"",
                .{ self.y, self.line_color, bg, self.line.items.len },
            ) catch null;
            if (header) |s| d.appendSlice(self.alloc, s) catch {};
            appendEscapedPreview(d, self.alloc, self.line.items, 120) catch {};
            d.appendSlice(self.alloc, "\"\n") catch {};
        }

        self.line.items.len = 0;
        self.line_link_index = 0;
        self.line_bg = null;
        self.y += self.opts.line_h;
        if (self.y >= self.opts.viewport_h) self.truncated = true;
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn appendEscapedPreview(d: *std.ArrayList(u8), alloc: std.mem.Allocator, bytes: []const u8, max_len: usize) !void {
    const n = @min(bytes.len, max_len);
    for (bytes[0..n]) |c| {
        switch (c) {
            '\\' => try d.appendSlice(alloc, "\\\\"),
            '\n' => try d.appendSlice(alloc, "\\n"),
            '\r' => try d.appendSlice(alloc, "\\r"),
            '\t' => try d.appendSlice(alloc, "\\t"),
            else => {
                if (c >= 0x20 and c < 0x7F) {
                    try d.append(alloc, c);
                } else {
                    try d.append(alloc, '.');
                }
            },
        }
    }
    if (bytes.len > n) try d.appendSlice(alloc, "…");
}

fn findImageView(images: []const ImageView, resource_id: u32) ?ImageView {
    for (images) |img| {
        if (img.resource_id == resource_id) return img;
    }
    return null;
}
