const std = @import("std");

pub const Tag = enum(u8) {
    document,
    unknown,

    html,
    head,
    body,
    title,

    // Metadata / resources
    meta,
    link,

    // Scripting / styling
    script,
    style,

    // Grouping / flow
    div,
    span,
    p,
    br,
    a,
    pre,
    code,
    blockquote,
    hr,

    // Lists
    ul,
    ol,
    li,

    // Headings
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,

    // Tables (subset)
    table,
    thead,
    tbody,
    tfoot,
    tr,
    td,
    th,

    // Media
    img,
};

pub fn fromNameLower(name_lower: []const u8) Tag {
    if (name_lower.len == 0) return .unknown;

    // Fast path for common short tags.
    if (std.mem.eql(u8, name_lower, "html")) return .html;
    if (std.mem.eql(u8, name_lower, "head")) return .head;
    if (std.mem.eql(u8, name_lower, "body")) return .body;
    if (std.mem.eql(u8, name_lower, "title")) return .title;

    if (std.mem.eql(u8, name_lower, "div")) return .div;
    if (std.mem.eql(u8, name_lower, "span")) return .span;
    if (std.mem.eql(u8, name_lower, "p")) return .p;
    if (std.mem.eql(u8, name_lower, "br")) return .br;
    if (std.mem.eql(u8, name_lower, "a")) return .a;
    if (std.mem.eql(u8, name_lower, "pre")) return .pre;
    if (std.mem.eql(u8, name_lower, "code")) return .code;
    if (std.mem.eql(u8, name_lower, "blockquote")) return .blockquote;
    if (std.mem.eql(u8, name_lower, "hr")) return .hr;

    if (std.mem.eql(u8, name_lower, "ul")) return .ul;
    if (std.mem.eql(u8, name_lower, "ol")) return .ol;
    if (std.mem.eql(u8, name_lower, "li")) return .li;

    if (std.mem.eql(u8, name_lower, "h1")) return .h1;
    if (std.mem.eql(u8, name_lower, "h2")) return .h2;
    if (std.mem.eql(u8, name_lower, "h3")) return .h3;
    if (std.mem.eql(u8, name_lower, "h4")) return .h4;
    if (std.mem.eql(u8, name_lower, "h5")) return .h5;
    if (std.mem.eql(u8, name_lower, "h6")) return .h6;

    if (std.mem.eql(u8, name_lower, "meta")) return .meta;
    if (std.mem.eql(u8, name_lower, "link")) return .link;
    if (std.mem.eql(u8, name_lower, "script")) return .script;
    if (std.mem.eql(u8, name_lower, "style")) return .style;

    if (std.mem.eql(u8, name_lower, "table")) return .table;
    if (std.mem.eql(u8, name_lower, "thead")) return .thead;
    if (std.mem.eql(u8, name_lower, "tbody")) return .tbody;
    if (std.mem.eql(u8, name_lower, "tfoot")) return .tfoot;
    if (std.mem.eql(u8, name_lower, "tr")) return .tr;
    if (std.mem.eql(u8, name_lower, "td")) return .td;
    if (std.mem.eql(u8, name_lower, "th")) return .th;

    if (std.mem.eql(u8, name_lower, "img")) return .img;

    return .unknown;
}

pub fn isVoid(tag: Tag) bool {
    return switch (tag) {
        .meta, .link, .br, .hr, .img => true,
        else => false,
    };
}

pub fn isBlock(tag: Tag) bool {
    return switch (tag) {
        .document,
        .html,
        .head,
        .body,
        .div,
        .p,
        .pre,
        .blockquote,
        .hr,
        .ul,
        .ol,
        .li,
        .h1,
        .h2,
        .h3,
        .h4,
        .h5,
        .h6,
        .table,
        .thead,
        .tbody,
        .tfoot,
        .tr,
        => true,
        else => false,
    };
}

pub fn isHeading(tag: Tag) bool {
    return switch (tag) {
        .h1, .h2, .h3, .h4, .h5, .h6 => true,
        else => false,
    };
}

pub fn isPreformatted(tag: Tag) bool {
    return tag == .pre;
}

pub fn name(tag: Tag) []const u8 {
    return switch (tag) {
        .document => "#document",
        .unknown => "unknown",
        .html => "html",
        .head => "head",
        .body => "body",
        .title => "title",
        .meta => "meta",
        .link => "link",
        .script => "script",
        .style => "style",
        .div => "div",
        .span => "span",
        .p => "p",
        .br => "br",
        .a => "a",
        .pre => "pre",
        .code => "code",
        .blockquote => "blockquote",
        .hr => "hr",
        .ul => "ul",
        .ol => "ol",
        .li => "li",
        .h1 => "h1",
        .h2 => "h2",
        .h3 => "h3",
        .h4 => "h4",
        .h5 => "h5",
        .h6 => "h6",
        .table => "table",
        .thead => "thead",
        .tbody => "tbody",
        .tfoot => "tfoot",
        .tr => "tr",
        .td => "td",
        .th => "th",
        .img => "img",
    };
}
