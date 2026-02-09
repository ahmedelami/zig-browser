const std = @import("std");

const css = @import("css.zig");

pub fn parseInlineStyle(style_raw: []const u8) css.InlineStyle {
    var out: css.InlineStyle = .{};

    var it = std.mem.splitScalar(u8, style_raw, ';');
    while (it.next()) |decl_raw| {
        const decl = std.mem.trim(u8, decl_raw, " \t\r\n");
        if (decl.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
        const prop = std.mem.trim(u8, decl[0..colon], " \t\r\n");
        const val = std.mem.trim(u8, decl[colon + 1 ..], " \t\r\n");
        if (prop.len == 0 or val.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(prop, "color")) {
            if (css.parseColor(val)) |c| out.color = c;
        } else if (std.ascii.eqlIgnoreCase(prop, "background-color")) {
            if (css.parseColor(val)) |c| out.background = c;
        } else if (std.ascii.eqlIgnoreCase(prop, "background")) {
            if (css.parseColor(val)) |c| out.background = c;
        } else if (std.ascii.eqlIgnoreCase(prop, "margin")) {
            if (css.parsePxLength(val)) |px| {
                out.margin.top = px;
                out.margin.right = px;
                out.margin.bottom = px;
                out.margin.left = px;
            }
        } else if (std.ascii.eqlIgnoreCase(prop, "margin-top")) {
            if (css.parsePxLength(val)) |px| out.margin.top = px;
        } else if (std.ascii.eqlIgnoreCase(prop, "margin-right")) {
            if (css.parsePxLength(val)) |px| out.margin.right = px;
        } else if (std.ascii.eqlIgnoreCase(prop, "margin-bottom")) {
            if (css.parsePxLength(val)) |px| out.margin.bottom = px;
        } else if (std.ascii.eqlIgnoreCase(prop, "margin-left")) {
            if (css.parsePxLength(val)) |px| out.margin.left = px;
        } else if (std.ascii.eqlIgnoreCase(prop, "padding")) {
            if (css.parsePxLength(val)) |px| {
                out.padding.top = px;
                out.padding.right = px;
                out.padding.bottom = px;
                out.padding.left = px;
            }
        } else if (std.ascii.eqlIgnoreCase(prop, "padding-top")) {
            if (css.parsePxLength(val)) |px| out.padding.top = px;
        } else if (std.ascii.eqlIgnoreCase(prop, "padding-right")) {
            if (css.parsePxLength(val)) |px| out.padding.right = px;
        } else if (std.ascii.eqlIgnoreCase(prop, "padding-bottom")) {
            if (css.parsePxLength(val)) |px| out.padding.bottom = px;
        } else if (std.ascii.eqlIgnoreCase(prop, "padding-left")) {
            if (css.parsePxLength(val)) |px| out.padding.left = px;
        }
    }

    return out;
}

