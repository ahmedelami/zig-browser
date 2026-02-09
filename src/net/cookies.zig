const std = @import("std");

const http_conn = @import("http_conn.zig");

pub const CookieJar = struct {
    alloc: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cookies: std.ArrayListUnmanaged(Cookie) = .{},

    pub fn init(alloc: std.mem.Allocator) CookieJar {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *CookieJar) void {
        self.mutex.lock();
        for (self.cookies.items) |c| c.deinit(self.alloc);
        self.cookies.deinit(self.alloc);
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn ingestFromHead(self: *CookieJar, scheme: http_conn.Scheme, host: []const u8, req_path: []const u8, head: std.http.Client.Response.Head) void {
        // Store cookies from any network response (including redirects).
        var it = head.iterateHeaders();
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "set-cookie")) continue;
            self.ingestSetCookie(scheme, host, req_path, h.value);
        }
    }

    pub fn ingestSetCookie(self: *CookieJar, scheme: http_conn.Scheme, host: []const u8, req_path: []const u8, header_value: []const u8) void {
        const now_ms: i64 = @intCast(std.time.milliTimestamp());

        var cookie = parseSetCookieOwned(self.alloc, host, req_path, header_value, now_ms) catch return;

        if (cookie.secure and scheme != .https) {
            // Persist the cookie, but it won't be sent on non-HTTPS requests.
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Upsert (domain+path+name).
        const max_cookies: usize = 256;
        var i: usize = 0;
        while (i < self.cookies.items.len) : (i += 1) {
            const prev = &self.cookies.items[i];
            if (!std.mem.eql(u8, prev.name, cookie.name)) continue;
            if (!std.mem.eql(u8, prev.domain, cookie.domain)) continue;
            if (!std.mem.eql(u8, prev.path, cookie.path)) continue;

            if (cookie.isExpired(now_ms)) {
                prev.deinit(self.alloc);
                _ = self.cookies.orderedRemove(i);
                cookie.deinit(self.alloc);
                return;
            }

            prev.deinit(self.alloc);
            prev.* = cookie;
            return;
        }

        if (cookie.isExpired(now_ms)) {
            cookie.deinit(self.alloc);
            return;
        }

        // Evict oldest if full.
        if (self.cookies.items.len >= max_cookies) {
            const evicted = self.cookies.orderedRemove(0);
            evicted.deinit(self.alloc);
        }

        self.cookies.append(self.alloc, cookie) catch {
            cookie.deinit(self.alloc);
        };
    }

    pub fn buildCookieHeader(
        self: *CookieJar,
        alloc: std.mem.Allocator,
        scheme: http_conn.Scheme,
        host: []const u8,
        req_path: []const u8,
    ) ?[]u8 {
        const now_ms: i64 = @intCast(std.time.milliTimestamp());
        var host_buf: [253]u8 = undefined;
        const host_lc = lowerIntoBuf(&host_buf, host);

        self.mutex.lock();
        defer self.mutex.unlock();

        var out = std.ArrayList(u8).initCapacity(alloc, 256) catch return null;
        errdefer out.deinit(alloc);

        const max_header_bytes: usize = 8 * 1024;
        var first: bool = true;

        for (self.cookies.items) |c| {
            if (c.secure and scheme != .https) continue;
            if (c.isExpired(now_ms)) continue;
            if (!domainMatches(host_lc, c.domain, c.host_only)) continue;
            if (!pathMatches(req_path, c.path)) continue;

            const entry_bytes: usize = c.name.len + 1 + c.value.len + @as(usize, if (first) 0 else 2);
            if (out.items.len + entry_bytes > max_header_bytes) break;

            if (!first) out.appendSlice(alloc, "; ") catch break;
            out.appendSlice(alloc, c.name) catch break;
            out.append(alloc, '=') catch break;
            out.appendSlice(alloc, c.value) catch break;
            first = false;
        }

        if (out.items.len == 0) {
            out.deinit(alloc);
            return null;
        }
        return out.toOwnedSlice(alloc) catch {
            out.deinit(alloc);
            return null;
        };
    }
};

const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    host_only: bool,
    path: []const u8,
    secure: bool,
    http_only: bool,
    expires_at_ms: ?i64,

    fn deinit(self: Cookie, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.value);
        alloc.free(self.domain);
        alloc.free(self.path);
    }

    fn isExpired(self: Cookie, now_ms: i64) bool {
        const exp = self.expires_at_ms orelse return false;
        return now_ms >= exp;
    }
};

fn parseSetCookieOwned(
    alloc: std.mem.Allocator,
    host: []const u8,
    req_path: []const u8,
    header_value: []const u8,
    now_ms: i64,
) !Cookie {
    const max_cookie_bytes: usize = 8 * 1024;
    const raw = std.mem.trim(u8, header_value, " \t\r\n");
    if (raw.len == 0 or raw.len > max_cookie_bytes) return error.BadCookie;

    var it = std.mem.splitScalar(u8, raw, ';');
    const first = std.mem.trim(u8, it.first(), " \t\r\n");
    const eq = std.mem.indexOfScalar(u8, first, '=') orelse return error.BadCookie;
    const name_raw = std.mem.trim(u8, first[0..eq], " \t\r\n");
    const value_raw = std.mem.trim(u8, first[eq + 1 ..], " \t\r\n");
    if (name_raw.len == 0 or name_raw.len > 256) return error.BadCookie;

    var host_buf: [253]u8 = undefined;
    const host_lc = lowerIntoBuf(&host_buf, host);

    var domain_lc: []const u8 = host_lc;
    var domain_owned: ?[]const u8 = null;
    errdefer if (domain_owned) |d| alloc.free(d);
    var host_only: bool = true;
    var path = defaultPath(req_path);
    var secure: bool = false;
    var http_only: bool = false;
    var max_age_s: ?i64 = null;
    var expires_ms: ?i64 = null;

    while (it.next()) |seg_raw| {
        const seg = std.mem.trim(u8, seg_raw, " \t\r\n");
        if (seg.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(seg, "secure")) {
            secure = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(seg, "httponly")) {
            http_only = true;
            continue;
        }

        const attr_eq = std.mem.indexOfScalar(u8, seg, '=') orelse continue;
        const a_name = std.mem.trim(u8, seg[0..attr_eq], " \t\r\n");
        const a_val_raw = std.mem.trim(u8, seg[attr_eq + 1 ..], " \t\r\n");
        if (a_val_raw.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(a_name, "domain")) {
            var d = a_val_raw;
            if (d[0] == '.') d = d[1..];
            if (d.len == 0 or d.len > 253) continue;
            const d_lc = lowerAlloc(alloc, d) catch continue;
            if (!domainMatches(host_lc, d_lc, false)) {
                alloc.free(d_lc);
                continue;
            }
            if (domain_owned) |prev| alloc.free(prev);
            domain_owned = d_lc;
            domain_lc = d_lc;
            host_only = false;
        } else if (std.ascii.eqlIgnoreCase(a_name, "path")) {
            if (a_val_raw.len > 1024) continue;
            if (a_val_raw[0] == '/') path = a_val_raw;
        } else if (std.ascii.eqlIgnoreCase(a_name, "max-age")) {
            const n = std.fmt.parseInt(i64, a_val_raw, 10) catch continue;
            max_age_s = n;
        } else if (std.ascii.eqlIgnoreCase(a_name, "expires")) {
            expires_ms = parseExpiresMs(a_val_raw) orelse null;
        } else {
            continue;
        }
    }

    var expires_at_ms: ?i64 = null;
    if (max_age_s) |s| {
        expires_at_ms = now_ms + (s * std.time.ms_per_s);
    } else if (expires_ms) |ms| {
        expires_at_ms = ms;
    }

    const name = try alloc.dupe(u8, name_raw);
    errdefer alloc.free(name);
    const value = try alloc.dupe(u8, value_raw);
    errdefer alloc.free(value);

    const domain_final = domain_owned orelse try alloc.dupe(u8, domain_lc);
    domain_owned = null;
    errdefer alloc.free(domain_final);
    const path_owned = try alloc.dupe(u8, path);
    errdefer alloc.free(path_owned);

    return .{
        .name = name,
        .value = value,
        .domain = domain_final,
        .host_only = host_only,
        .path = path_owned,
        .secure = secure,
        .http_only = http_only,
        .expires_at_ms = expires_at_ms,
    };
}

fn defaultPath(req_path: []const u8) []const u8 {
    if (req_path.len == 0 or req_path[0] != '/') return "/";
    const last_slash = std.mem.lastIndexOfScalar(u8, req_path, '/') orelse return "/";
    if (last_slash == 0) return "/";
    return req_path[0 .. last_slash + 1];
}

fn domainMatches(host_lc: []const u8, cookie_domain: []const u8, host_only: bool) bool {
    if (host_only) return std.mem.eql(u8, host_lc, cookie_domain);
    if (std.mem.eql(u8, host_lc, cookie_domain)) return true;
    if (host_lc.len <= cookie_domain.len) return false;
    const off = host_lc.len - cookie_domain.len;
    if (!std.mem.eql(u8, host_lc[off..], cookie_domain)) return false;
    return host_lc[off - 1] == '.';
}

fn pathMatches(req_path: []const u8, cookie_path: []const u8) bool {
    if (cookie_path.len == 0) return true;
    if (req_path.len < cookie_path.len) return false;
    return std.mem.startsWith(u8, req_path, cookie_path);
}

fn lowerIntoBuf(buf: []u8, host: []const u8) []const u8 {
    const n = @min(host.len, buf.len);
    var changed: bool = false;
    for (host[0..n], 0..) |c, i| {
        const lc = std.ascii.toLower(c);
        buf[i] = lc;
        changed = changed or (lc != c);
    }
    return if (changed) buf[0..n] else host[0..n];
}

fn lowerAlloc(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out = try alloc.alloc(u8, bytes.len);
    for (bytes, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn parseExpiresMs(s: []const u8) ?i64 {
    // Best-effort: only parse a couple of common formats.
    // Examples:
    // - "Mon, 09 Feb 2026 02:55:57 GMT"
    // - "Mon, 09-Feb-2026 02:55:57 GMT"
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len < 20) return null;

    // Skip optional weekday prefix.
    var rest = trimmed;
    if (std.mem.indexOf(u8, rest, ", ")) |comma| {
        if (comma <= 4 and comma + 2 < rest.len) rest = rest[comma + 2 ..];
    }

    var it = std.mem.tokenizeAny(u8, rest, " -");
    const day_s = it.next() orelse return null;
    const mon_s = it.next() orelse return null;
    const year_s = it.next() orelse return null;
    const time_s = it.next() orelse return null;

    const day = std.fmt.parseInt(u8, day_s, 10) catch return null;
    const year = std.fmt.parseInt(i32, year_s, 10) catch return null;
    const mon = monthNumber(mon_s) orelse return null;

    if (time_s.len < 7) return null;
    const h = std.fmt.parseInt(u8, time_s[0..2], 10) catch return null;
    const m = std.fmt.parseInt(u8, time_s[3..5], 10) catch return null;
    const sec = std.fmt.parseInt(u8, time_s[6..8], 10) catch return null;

    const ts_s: i64 = unixSecondsUtc(year, mon, day, h, m, sec) orelse return null;
    return ts_s * std.time.ms_per_s;
}

fn monthNumber(mon: []const u8) ?u8 {
    if (mon.len < 3) return null;
    var buf: [3]u8 = undefined;
    for (mon[0..3], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const m = buf[0..3];
    if (std.mem.eql(u8, m, "jan")) return 1;
    if (std.mem.eql(u8, m, "feb")) return 2;
    if (std.mem.eql(u8, m, "mar")) return 3;
    if (std.mem.eql(u8, m, "apr")) return 4;
    if (std.mem.eql(u8, m, "may")) return 5;
    if (std.mem.eql(u8, m, "jun")) return 6;
    if (std.mem.eql(u8, m, "jul")) return 7;
    if (std.mem.eql(u8, m, "aug")) return 8;
    if (std.mem.eql(u8, m, "sep")) return 9;
    if (std.mem.eql(u8, m, "oct")) return 10;
    if (std.mem.eql(u8, m, "nov")) return 11;
    if (std.mem.eql(u8, m, "dec")) return 12;
    return null;
}

fn unixSecondsUtc(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?i64 {
    if (year < 1970 or year > 2100) return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    // Convert date to days since Unix epoch (1970-01-01), then add seconds-of-day.
    const days = daysSinceEpoch(year, month, day) orelse return null;
    const sod: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    return days * 86400 + sod;
}

fn daysSinceEpoch(year: i32, month: u8, day: u8) ?i64 {
    // Civil-from-days / days-from-civil (Howard Hinnant), proleptic Gregorian.
    // https://howardhinnant.github.io/date_algorithms.html
    var y: i64 = year;
    const m: i64 = month;
    const d: i64 = day;
    y -= if (m <= 2) 1 else 0;
    const era: i64 = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const doy: i64 = @divTrunc(153 * (m + @as(i64, if (m > 2) -3 else 9)) + 2, 5) + d - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    const days_from_civil: i64 = era * 146097 + doe - 719468; // days since 1970-01-01
    return days_from_civil;
}
