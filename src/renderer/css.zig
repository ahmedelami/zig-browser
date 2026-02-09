const std = @import("std");

const tag_mod = @import("html/tag.zig");

pub const Selector = struct {
    tag: ?tag_mod.Tag = null,
    id: ?[]const u8 = null,
    class: ?[]const u8 = null,
};

pub const Edges = struct {
    top: ?i32 = null,
    right: ?i32 = null,
    bottom: ?i32 = null,
    left: ?i32 = null,
};

pub const InlineStyle = struct {
    color: ?u32 = null, // AARRGGBB
    background: ?u32 = null, // AARRGGBB
    margin: Edges = .{},
    padding: Edges = .{},
};

pub const Rule = struct {
    selector: Selector,
    specificity: u16 = 0,
    color: ?u32 = null, // AARRGGBB
    background: ?u32 = null, // AARRGGBB
    margin: Edges = .{},
    padding: Edges = .{},
};

pub const Globals = struct {
    bg: u32,
    text: u32,
    link: u32,
    heading: u32,
    muted: u32,
};

pub fn globalsFromRules(rules: []const Rule) Globals {
    // Minimal UA defaults (light).
    var g: Globals = .{
        .bg = 0xFFFFFFFF,
        .text = 0xFF000000,
        .link = 0xFF0000EE,
        .heading = 0xFF000000,
        .muted = 0xFF666666,
    };

    for (rules) |r| {
        // globalsFromRules is used when we don't have DOM context; ignore selectors
        // that depend on id/class to avoid misapplying styles.
        if (r.selector.id != null or r.selector.class != null) continue;

        const tag = r.selector.tag orelse continue;
        if (tag == .body or tag == .html) {
            if (r.background) |c| g.bg = c;
            if (r.color) |c| g.text = c;
            continue;
        }
        if (tag == .a) {
            if (r.color) |c| g.link = c;
            continue;
        }
        if (tag_mod.isHeading(tag)) {
            if (r.color) |c| g.heading = c;
            continue;
        }
    }

    return g;
}

pub const ComputedDecls = struct {
    color: ?u32 = null,
    background: ?u32 = null,
    margin: Edges = .{},
    padding: Edges = .{},
};

pub fn computeForElement(
    rules: []const Rule,
    tag: tag_mod.Tag,
    id: ?[]const u8,
    class_attr: ?[]const u8,
) ComputedDecls {
    var out: ComputedDecls = .{};

    var best_color_spec: u16 = 0;
    var best_color_idx: usize = 0;
    var best_bg_spec: u16 = 0;
    var best_bg_idx: usize = 0;

    var best_mt_spec: u16 = 0;
    var best_mt_idx: usize = 0;
    var best_mr_spec: u16 = 0;
    var best_mr_idx: usize = 0;
    var best_mb_spec: u16 = 0;
    var best_mb_idx: usize = 0;
    var best_ml_spec: u16 = 0;
    var best_ml_idx: usize = 0;

    var best_pt_spec: u16 = 0;
    var best_pt_idx: usize = 0;
    var best_pr_spec: u16 = 0;
    var best_pr_idx: usize = 0;
    var best_pb_spec: u16 = 0;
    var best_pb_idx: usize = 0;
    var best_pl_spec: u16 = 0;
    var best_pl_idx: usize = 0;

    for (rules, 0..) |r, idx| {
        if (!ruleMatches(r.selector, tag, id, class_attr)) continue;

        consider(u32, r.color, r.specificity, idx, &best_color_spec, &best_color_idx, &out.color);
        consider(u32, r.background, r.specificity, idx, &best_bg_spec, &best_bg_idx, &out.background);

        consider(i32, r.margin.top, r.specificity, idx, &best_mt_spec, &best_mt_idx, &out.margin.top);
        consider(i32, r.margin.right, r.specificity, idx, &best_mr_spec, &best_mr_idx, &out.margin.right);
        consider(i32, r.margin.bottom, r.specificity, idx, &best_mb_spec, &best_mb_idx, &out.margin.bottom);
        consider(i32, r.margin.left, r.specificity, idx, &best_ml_spec, &best_ml_idx, &out.margin.left);

        consider(i32, r.padding.top, r.specificity, idx, &best_pt_spec, &best_pt_idx, &out.padding.top);
        consider(i32, r.padding.right, r.specificity, idx, &best_pr_spec, &best_pr_idx, &out.padding.right);
        consider(i32, r.padding.bottom, r.specificity, idx, &best_pb_spec, &best_pb_idx, &out.padding.bottom);
        consider(i32, r.padding.left, r.specificity, idx, &best_pl_spec, &best_pl_idx, &out.padding.left);
    }

    return out;
}

fn consider(
    comptime T: type,
    value: ?T,
    spec: u16,
    idx: usize,
    best_spec: *u16,
    best_idx: *usize,
    out: *?T,
) void {
    const v = value orelse return;
    if (spec > best_spec.* or (spec == best_spec.* and idx >= best_idx.*)) {
        best_spec.* = spec;
        best_idx.* = idx;
        out.* = v;
    }
}

fn ruleMatches(sel: Selector, tag: tag_mod.Tag, id: ?[]const u8, class_attr: ?[]const u8) bool {
    if (sel.tag) |t| {
        if (t != tag) return false;
    }
    if (sel.id) |want| {
        const have = id orelse return false;
        if (!std.mem.eql(u8, have, want)) return false;
    }
    if (sel.class) |want| {
        const have = class_attr orelse return false;
        if (!classHasToken(have, want)) return false;
    }
    return true;
}

fn classHasToken(class_attr: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, class_attr, " \t\r\n");
    while (it.next()) |t| {
        if (std.mem.eql(u8, t, token)) return true;
    }
    return false;
}

pub fn parseAppend(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Rule),
    css_bytes: []const u8,
    max_rules: usize,
) void {
    var i: usize = 0;
    while (i < css_bytes.len and out.items.len < max_rules) {
        skipWsAndComments(css_bytes, &i);
        if (i >= css_bytes.len) break;

        if (css_bytes[i] == '@') {
            skipAtRule(css_bytes, &i);
            continue;
        }

        const sel_start = i;
        while (i < css_bytes.len and css_bytes[i] != '{') : (i += 1) {}
        if (i >= css_bytes.len) break;
        const selectors_raw = css_bytes[sel_start..i];
        i += 1; // consume '{'

        var decl_color: ?u32 = null;
        var decl_bg: ?u32 = null;
        var decl_margin: Edges = .{};
        var decl_padding: Edges = .{};

        // Declarations until '}'
        while (i < css_bytes.len) {
            skipWsAndComments(css_bytes, &i);
            if (i >= css_bytes.len) break;
            if (css_bytes[i] == '}') {
                i += 1;
                break;
            }

            const prop_start = i;
            while (i < css_bytes.len and isIdentChar(css_bytes[i])) : (i += 1) {}
            const prop = std.mem.trim(u8, css_bytes[prop_start..i], " \t\r\n");

            while (i < css_bytes.len and isWs(css_bytes[i])) : (i += 1) {}
            if (i >= css_bytes.len) break;
            if (css_bytes[i] != ':') {
                skipToDeclEnd(css_bytes, &i);
                continue;
            }
            i += 1; // consume ':'
            while (i < css_bytes.len and isWs(css_bytes[i])) : (i += 1) {}

            const val_start = i;
            while (i < css_bytes.len and css_bytes[i] != ';' and css_bytes[i] != '}') : (i += 1) {}
            const val = std.mem.trim(u8, css_bytes[val_start..i], " \t\r\n");

            if (std.ascii.eqlIgnoreCase(prop, "color")) {
                if (parseColor(val)) |c| decl_color = c;
            } else if (std.ascii.eqlIgnoreCase(prop, "background-color")) {
                if (parseColor(val)) |c| decl_bg = c;
            } else if (std.ascii.eqlIgnoreCase(prop, "background")) {
                if (parseColor(val)) |c| decl_bg = c;
            } else if (std.ascii.eqlIgnoreCase(prop, "margin")) {
                if (parsePxLength(val)) |px| {
                    decl_margin.top = px;
                    decl_margin.right = px;
                    decl_margin.bottom = px;
                    decl_margin.left = px;
                }
            } else if (std.ascii.eqlIgnoreCase(prop, "margin-top")) {
                if (parsePxLength(val)) |px| decl_margin.top = px;
            } else if (std.ascii.eqlIgnoreCase(prop, "margin-right")) {
                if (parsePxLength(val)) |px| decl_margin.right = px;
            } else if (std.ascii.eqlIgnoreCase(prop, "margin-bottom")) {
                if (parsePxLength(val)) |px| decl_margin.bottom = px;
            } else if (std.ascii.eqlIgnoreCase(prop, "margin-left")) {
                if (parsePxLength(val)) |px| decl_margin.left = px;
            } else if (std.ascii.eqlIgnoreCase(prop, "padding")) {
                if (parsePxLength(val)) |px| {
                    decl_padding.top = px;
                    decl_padding.right = px;
                    decl_padding.bottom = px;
                    decl_padding.left = px;
                }
            } else if (std.ascii.eqlIgnoreCase(prop, "padding-top")) {
                if (parsePxLength(val)) |px| decl_padding.top = px;
            } else if (std.ascii.eqlIgnoreCase(prop, "padding-right")) {
                if (parsePxLength(val)) |px| decl_padding.right = px;
            } else if (std.ascii.eqlIgnoreCase(prop, "padding-bottom")) {
                if (parsePxLength(val)) |px| decl_padding.bottom = px;
            } else if (std.ascii.eqlIgnoreCase(prop, "padding-left")) {
                if (parsePxLength(val)) |px| decl_padding.left = px;
            }

            if (i < css_bytes.len and css_bytes[i] == ';') i += 1;
        }

        if (decl_color == null and decl_bg == null and !hasAnyEdges(decl_margin) and !hasAnyEdges(decl_padding)) continue;

        var it = std.mem.splitScalar(u8, selectors_raw, ',');
        while (it.next()) |sel_part| {
            if (out.items.len >= max_rules) break;
            const selector = parseSelector(sel_part) orelse continue;
            out.append(alloc, .{
                .selector = selector,
                .specificity = selectorSpecificity(selector),
                .color = decl_color,
                .background = decl_bg,
                .margin = decl_margin,
                .padding = decl_padding,
            }) catch return;
        }
    }
}

fn hasAnyEdges(e: Edges) bool {
    return e.top != null or e.right != null or e.bottom != null or e.left != null;
}

fn selectorSpecificity(sel: Selector) u16 {
    var spec: u16 = 0;
    if (sel.tag != null) spec +|= 1;
    if (sel.class != null) spec +|= 10;
    if (sel.id != null) spec +|= 100;
    return spec;
}

fn parseSelector(sel_raw: []const u8) ?Selector {
    const sel = std.mem.trim(u8, sel_raw, " \t\r\n");
    if (sel.len == 0) return null;

    // Reject descendant/combinator selectors (e.g. "body a", "div > p").
    // We only support a single compound selector: tag? + (#id|.class)* + optional pseudo-class.
    var out: Selector = .{};
    var i: usize = 0;
    var universal: bool = false;

    if (sel[0] == ':') {
        // Minimal support for ":root" (treat as html).
        if (std.ascii.eqlIgnoreCase(sel, ":root")) {
            out.tag = .html;
            return out;
        }
        return null;
    }

    if (sel[0] == '*') {
        universal = true;
        i = 1; // universal
    } else if (sel[0] != '.' and sel[0] != '#') {
        const start = i;
        while (i < sel.len and (std.ascii.isAlphanumeric(sel[i]) or sel[i] == '-')) : (i += 1) {}
        if (i == start) return null;

        var name_buf: [32]u8 = undefined;
        const n = @min(name_buf.len, i - start);
        for (0..n) |k| name_buf[k] = std.ascii.toLower(sel[start + k]);
        const t = tag_mod.fromNameLower(name_buf[0..n]);
        if (t == .unknown) return null;
        out.tag = t;
    }

    while (i < sel.len) {
        const c = sel[i];
        switch (c) {
            '.' => {
                if (out.class != null) return null; // don't misapply multi-class selectors
                i += 1;
                const start = i;
                while (i < sel.len and isIdentChar(sel[i])) : (i += 1) {}
                if (i == start) return null;
                out.class = sel[start..i];
            },
            '#' => {
                if (out.id != null) return null;
                i += 1;
                const start = i;
                while (i < sel.len and isIdentChar(sel[i])) : (i += 1) {}
                if (i == start) return null;
                out.id = sel[start..i];
            },
            ':' => {
                // Pseudo-classes/elements alter matching; don't misapply them.
                // We only treat ":link" as "a" for now (assume all links are unvisited).
                var j = i + 1;
                if (j < sel.len and sel[j] == ':') j += 1;
                const start = j;
                while (j < sel.len and isIdentChar(sel[j])) : (j += 1) {}
                if (j == start) return null;
                const pseudo = sel[start..j];
                if (std.ascii.eqlIgnoreCase(pseudo, "link")) break;
                return null;
            },
            '[' => return null, // attribute selectors unsupported
            '>', '+', '~' => return null,
            else => {
                if (isWs(c)) {
                    // If there's anything non-ws after, it's a combinator/descendant selector.
                    var j = i;
                    while (j < sel.len and isWs(sel[j])) : (j += 1) {}
                    if (j < sel.len) return null;
                    break;
                }
                return null;
            },
        }
    }

    if (out.tag == null and out.id == null and out.class == null) {
        if (universal) return out;
        return null;
    }
    return out;
}

pub fn parseColor(val_raw: []const u8) ?u32 {
    var i: usize = 0;
    while (i < val_raw.len and isWs(val_raw[i])) : (i += 1) {}
    if (i >= val_raw.len) return null;

    // Stop at whitespace or '!' (e.g. "!important").
    var end: usize = i;
    while (end < val_raw.len) : (end += 1) {
        const c = val_raw[end];
        if (isWs(c) or c == '!' or c == ';' or c == '}') break;
    }
    const tok = val_raw[i..end];
    if (tok.len == 0) return null;

    if (tok[0] == '#') return parseHexColor(tok[1..]);

    if (std.ascii.startsWithIgnoreCase(tok, "rgb(")) return parseRgb(tok, false);
    if (std.ascii.startsWithIgnoreCase(tok, "rgba(")) return parseRgb(tok, true);

    return parseNamedColor(tok);
}

pub fn parsePxLength(val_raw: []const u8) ?i32 {
    var i: usize = 0;
    while (i < val_raw.len and isWs(val_raw[i])) : (i += 1) {}
    if (i >= val_raw.len) return null;

    var end: usize = i;
    while (end < val_raw.len) : (end += 1) {
        const c = val_raw[end];
        if (isWs(c) or c == '!' or c == ';' or c == '}') break;
    }
    const tok = val_raw[i..end];
    if (tok.len == 0) return null;

    // Strip "px" suffix if present.
    const num_tok = if (std.mem.endsWith(u8, tok, "px")) tok[0 .. tok.len - 2] else tok;
    if (num_tok.len == 0) return null;
    if (std.mem.indexOfScalar(u8, num_tok, '%') != null) return null;

    const v = std.fmt.parseInt(i32, num_tok, 10) catch return null;
    return std.math.clamp(v, -4096, 4096);
}

fn parseHexColor(hex: []const u8) ?u32 {
    if (hex.len == 3) {
        const r = parseHexNibble(hex[0]) orelse return null;
        const g = parseHexNibble(hex[1]) orelse return null;
        const b = parseHexNibble(hex[2]) orelse return null;
        const rr: u8 = (r << 4) | r;
        const gg: u8 = (g << 4) | g;
        const bb: u8 = (b << 4) | b;
        return packColor(rr, gg, bb);
    }
    if (hex.len == 6) {
        const r = parseHexByte(hex[0..2]) orelse return null;
        const g = parseHexByte(hex[2..4]) orelse return null;
        const b = parseHexByte(hex[4..6]) orelse return null;
        return packColor(r, g, b);
    }
    return null;
}

fn parseHexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn parseHexByte(s: []const u8) ?u8 {
    if (s.len != 2) return null;
    const hi = parseHexNibble(s[0]) orelse return null;
    const lo = parseHexNibble(s[1]) orelse return null;
    return (hi << 4) | lo;
}

fn parseRgb(tok: []const u8, comptime has_alpha: bool) ?u32 {
    const open = std.mem.indexOfScalar(u8, tok, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, tok, ')') orelse return null;
    if (close <= open) return null;
    const inner = tok[open + 1 .. close];
    var it = std.mem.splitScalar(u8, inner, ',');
    const r = parseU8Trim(it.next() orelse return null) orelse return null;
    const g = parseU8Trim(it.next() orelse return null) orelse return null;
    const b = parseU8Trim(it.next() orelse return null) orelse return null;
    if (has_alpha) _ = it.next(); // ignore alpha for now
    return packColor(r, g, b);
}

fn parseU8Trim(s_raw: []const u8) ?u8 {
    const s = std.mem.trim(u8, s_raw, " \t\r\n");
    if (s.len == 0) return null;
    const v = std.fmt.parseInt(u16, s, 10) catch return null;
    return @intCast(@min(v, 255));
}

fn parseNamedColor(name_raw: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(name_raw, "white")) return packColor(255, 255, 255);
    if (std.ascii.eqlIgnoreCase(name_raw, "black")) return packColor(0, 0, 0);
    if (std.ascii.eqlIgnoreCase(name_raw, "red")) return packColor(255, 0, 0);
    if (std.ascii.eqlIgnoreCase(name_raw, "green")) return packColor(0, 128, 0);
    if (std.ascii.eqlIgnoreCase(name_raw, "blue")) return packColor(0, 0, 255);
    if (std.ascii.eqlIgnoreCase(name_raw, "gray") or std.ascii.eqlIgnoreCase(name_raw, "grey")) return packColor(128, 128, 128);
    if (std.ascii.eqlIgnoreCase(name_raw, "yellow")) return packColor(255, 255, 0);
    if (std.ascii.eqlIgnoreCase(name_raw, "cyan")) return packColor(0, 255, 255);
    if (std.ascii.eqlIgnoreCase(name_raw, "magenta")) return packColor(255, 0, 255);
    if (std.ascii.eqlIgnoreCase(name_raw, "transparent")) return null;
    return null;
}

fn packColor(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, 0xFF) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

fn skipWsAndComments(bytes: []const u8, i: *usize) void {
    while (i.* < bytes.len) {
        while (i.* < bytes.len and isWs(bytes[i.*])) : (i.* += 1) {}
        if (i.* + 1 >= bytes.len) return;
        if (bytes[i.*] == '/' and bytes[i.* + 1] == '*') {
            i.* += 2;
            while (i.* + 1 < bytes.len) : (i.* += 1) {
                if (bytes[i.*] == '*' and bytes[i.* + 1] == '/') {
                    i.* += 2;
                    break;
                }
            }
            continue;
        }
        return;
    }
}

fn skipAtRule(bytes: []const u8, i: *usize) void {
    // Skip until ';' or a balanced '{...}' block.
    while (i.* < bytes.len and bytes[i.*] != ';' and bytes[i.*] != '{') : (i.* += 1) {}
    if (i.* >= bytes.len) return;
    if (bytes[i.*] == ';') {
        i.* += 1;
        return;
    }
    if (bytes[i.*] != '{') return;
    i.* += 1; // consume '{'
    var depth: usize = 1;
    while (i.* < bytes.len and depth != 0) : (i.* += 1) {
        if (bytes[i.*] == '{') depth += 1 else if (bytes[i.*] == '}') depth -= 1;
    }
}

fn skipToDeclEnd(bytes: []const u8, i: *usize) void {
    while (i.* < bytes.len) : (i.* += 1) {
        const c = bytes[i.*];
        if (c == ';') {
            i.* += 1;
            return;
        }
        if (c == '}') return;
    }
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

test "css: parse body colors" {
    const alloc = std.testing.allocator;
    var rules: std.ArrayListUnmanaged(Rule) = .{};
    defer rules.deinit(alloc);

    parseAppend(alloc, &rules, "body { background: #fff; color: #000 } a { color: #00f }", 64);
    try std.testing.expect(rules.items.len >= 2);

    const body = computeForElement(rules.items, .body, null, null);
    try std.testing.expectEqual(@as(?u32, 0xFFFFFFFF), body.background);
    try std.testing.expectEqual(@as(?u32, 0xFF000000), body.color);
}

test "css: class + id specificity" {
    const alloc = std.testing.allocator;
    var rules: std.ArrayListUnmanaged(Rule) = .{};
    defer rules.deinit(alloc);

    parseAppend(alloc, &rules, "p { color: #000 } .x { color: #0f0 } #y { color: #f00 }", 64);
    try std.testing.expect(rules.items.len >= 3);

    const c1 = computeForElement(rules.items, .p, null, "x");
    try std.testing.expectEqual(@as(?u32, 0xFF00FF00), c1.color);

    const c2 = computeForElement(rules.items, .p, "y", "x");
    try std.testing.expectEqual(@as(?u32, 0xFFFF0000), c2.color);
}

test "css: margin + padding length parse" {
    const alloc = std.testing.allocator;
    var rules: std.ArrayListUnmanaged(Rule) = .{};
    defer rules.deinit(alloc);

    parseAppend(alloc, &rules, "p { margin: 8px; padding-left: 16px }", 64);
    try std.testing.expect(rules.items.len >= 1);

    const d = computeForElement(rules.items, .p, null, null);
    try std.testing.expectEqual(@as(?i32, 8), d.margin.top);
    try std.testing.expectEqual(@as(?i32, 8), d.margin.bottom);
    try std.testing.expectEqual(@as(?i32, 16), d.padding.left);
}
