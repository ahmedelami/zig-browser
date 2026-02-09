const std = @import("std");

pub const IOSurfaceRef = ?*anyopaque;
pub const IOSurfaceID = u32;
pub const CFTypeRef = ?*anyopaque;
pub const CFAllocatorRef = ?*anyopaque;
pub const CFIndex = isize;
pub const CFStringRef = ?*anyopaque;
pub const CFNumberRef = ?*anyopaque;
pub const CFBooleanRef = ?*anyopaque;
pub const CFDictionaryRef = ?*anyopaque;
pub const CFMutableDictionaryRef = ?*anyopaque;

pub const Surface = struct {
    ref: IOSurfaceRef,
    id: IOSurfaceID,
    width: u32,
    height: u32,
    stride: u32,
};

extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn CFNumberCreate(allocator: CFAllocatorRef, theType: CFIndex, valuePtr: *const anyopaque) CFNumberRef;
extern "c" fn CFDictionaryCreateMutable(
    allocator: CFAllocatorRef,
    capacity: CFIndex,
    keyCallBacks: *const CFDictionaryKeyCallBacks,
    valueCallBacks: *const CFDictionaryValueCallBacks,
) CFMutableDictionaryRef;
extern "c" fn CFDictionarySetValue(dict: CFMutableDictionaryRef, key: *const anyopaque, value: *const anyopaque) void;

extern const kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
extern const kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
extern const kCFBooleanTrue: CFBooleanRef;

pub const CFDictionaryKeyCallBacks = extern struct {
    version: CFIndex,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copyDescription: ?*const anyopaque,
    equal: ?*const anyopaque,
    hash: ?*const anyopaque,
};

pub const CFDictionaryValueCallBacks = extern struct {
    version: CFIndex,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copyDescription: ?*const anyopaque,
    equal: ?*const anyopaque,
};

extern const kIOSurfaceWidth: CFStringRef;
extern const kIOSurfaceHeight: CFStringRef;
extern const kIOSurfaceBytesPerElement: CFStringRef;
extern const kIOSurfacePixelFormat: CFStringRef;
extern const kIOSurfaceIsGlobal: CFStringRef;

extern "c" fn IOSurfaceCreate(properties: CFDictionaryRef) IOSurfaceRef;
extern "c" fn IOSurfaceLookup(csid: IOSurfaceID) IOSurfaceRef;
extern "c" fn IOSurfaceGetID(surface: IOSurfaceRef) IOSurfaceID;
extern "c" fn IOSurfaceGetBytesPerRow(surface: IOSurfaceRef) usize;
extern "c" fn IOSurfaceLock(surface: IOSurfaceRef, options: u32, seed: ?*u32) i32;
extern "c" fn IOSurfaceUnlock(surface: IOSurfaceRef, options: u32, seed: ?*u32) i32;
extern "c" fn IOSurfaceGetBaseAddress(surface: IOSurfaceRef) ?*anyopaque;

const kCFNumberSInt32Type: CFIndex = 3;

pub fn createBgra8Surface(width: u32, height: u32) !Surface {
    // IOSurface pixel format uses traditional OSType fourcc.
    const pixel_format_bgra: u32 = fourcc('B', 'G', 'R', 'A');

    const dict = CFDictionaryCreateMutable(null, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (dict == null) return error.CFAllocFailed;
    defer CFRelease(dict);

    const w_num = try cfNumberS32(width);
    defer CFRelease(w_num);
    CFDictionarySetValue(dict, kIOSurfaceWidth.?, w_num.?);

    const h_num = try cfNumberS32(height);
    defer CFRelease(h_num);
    CFDictionarySetValue(dict, kIOSurfaceHeight.?, h_num.?);

    const bpe_num = try cfNumberS32(4);
    defer CFRelease(bpe_num);
    CFDictionarySetValue(dict, kIOSurfaceBytesPerElement.?, bpe_num.?);

    const fmt_num = try cfNumberS32(pixel_format_bgra);
    defer CFRelease(fmt_num);
    CFDictionarySetValue(dict, kIOSurfacePixelFormat.?, fmt_num.?);

    // Allow cross-process lookup by ID (not secure; acceptable for local dev).
    CFDictionarySetValue(dict, kIOSurfaceIsGlobal.?, kCFBooleanTrue.?);

    const surface = IOSurfaceCreate(dict);
    if (surface == null) return error.IOSurfaceCreateFailed;

    const id = IOSurfaceGetID(surface);
    const stride: u32 = @intCast(IOSurfaceGetBytesPerRow(surface));

    return .{ .ref = surface, .id = id, .width = width, .height = height, .stride = stride };
}

pub fn destroy(surface: *Surface) void {
    if (surface.ref) |r| CFRelease(r);
    surface.* = undefined;
}

pub fn lookup(id: IOSurfaceID) ?IOSurfaceRef {
    return IOSurfaceLookup(id);
}

pub fn lockForWrite(surface: IOSurfaceRef) ![*]u8 {
    if (IOSurfaceLock(surface, 0, null) != 0) return error.IOSurfaceLockFailed;
    const base = IOSurfaceGetBaseAddress(surface) orelse return error.IOSurfaceMissingBaseAddress;
    return @ptrCast(@alignCast(base));
}

pub fn unlock(surface: IOSurfaceRef) void {
    _ = IOSurfaceUnlock(surface, 0, null);
}

fn cfNumberS32(value: u32) !CFNumberRef {
    var v: i32 = @intCast(value);
    const num = CFNumberCreate(null, kCFNumberSInt32Type, &v);
    if (num == null) return error.CFAllocFailed;
    return num;
}

fn fourcc(a: u8, b: u8, c: u8, d: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, c) << 8) | @as(u32, d);
}

