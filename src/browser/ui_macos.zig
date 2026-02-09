const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");

const input_queue = @import("input_queue.zig");
const objc = @import("objc.zig");

const TraceWriter = shared.trace.TraceWriter;

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };

const id = objc.id;
const SEL = objc.SEL;
const Class = objc.Class;
const BOOL = objc.BOOL;

const objc_getClass = objc.objc_getClass;
const objc_allocateClassPair = objc.objc_allocateClassPair;
const objc_registerClassPair = objc.objc_registerClassPair;
const class_addMethod = objc.class_addMethod;

const getClass = objc.getClass;
const classId = objc.classId;
const sel = objc.sel;

const msgSend0 = objc.msgSend0;
const msgSend1 = objc.msgSend1;
const msgSend2 = objc.msgSend2;
const msgSend3 = objc.msgSend3;
const msgSend4 = objc.msgSend4;
const msgSend5 = objc.msgSend5;
const msgSend9 = objc.msgSend9;
extern "c" fn MTLCreateSystemDefaultDevice() id;
extern "c" fn IOSurfaceLookup(surface_id: u32) id;
extern "c" fn IOSurfaceGetWidth(buffer: id) usize;
extern "c" fn IOSurfaceGetHeight(buffer: id) usize;
extern "c" fn CFRelease(obj: id) void;
extern "c" fn CFAbsoluteTimeGetCurrent() f64;
extern "c" fn CFRunLoopGetCurrent() id;
extern "c" fn CFRunLoopAddTimer(rl: id, timer: id, mode: id) void;
extern const kCFRunLoopCommonModes: id;
extern const kCFRunLoopDefaultMode: id;

const ProcessSerialNumber = extern struct {
    highLongOfPSN: u32,
    lowLongOfPSN: u32,
};
extern "c" fn GetCurrentProcess(psn: *ProcessSerialNumber) i32;
extern "c" fn TransformProcessType(psn: *ProcessSerialNumber, transform_state: u32) i32;
extern "c" fn SetFrontProcess(psn: *ProcessSerialNumber) i32;
const kProcessTransformToForegroundApplication: u32 = 1;

const NSBackingStoreBuffered: u64 = 2;

const NSWindowStyleMaskTitled: u64 = 1 << 0;
const NSWindowStyleMaskClosable: u64 = 1 << 1;
const NSWindowStyleMaskMiniaturizable: u64 = 1 << 2;
const NSWindowStyleMaskResizable: u64 = 1 << 3;

const NSApplicationActivationPolicyRegular: i64 = 0;
const NSTerminateCancel: i64 = 0;

const MTLPixelFormatBGRA8Unorm: u64 = 80;
const MTLLoadActionClear: u64 = 2;
const MTLStoreActionStore: u64 = 1;

const MTLClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

const NSUInteger = usize;
const NSEventTypeApplicationDefined: NSUInteger = 15;

const MTLOrigin = extern struct { x: NSUInteger, y: NSUInteger, z: NSUInteger };
const MTLSize = extern struct { width: NSUInteger, height: NSUInteger, depth: NSUInteger };

const MTLTextureUsageShaderRead: u64 = 1;
const MTLStorageModeShared: u64 = 0;

const RenderState = struct {
    device: id,
    queue: id,
    layer: id,
    surface_tex: ?id,
    surface_w: NSUInteger,
    surface_h: NSUInteger,
    trace: ?*TraceWriter,
};

var g_render_state: ?RenderState = null;
var g_first_present_sent: bool = false;
var g_render_driver: ?id = null;
var g_repaint_pending = std.atomic.Value(bool).init(false);
var g_app_for_quit: id = null;
var g_input: ?*input_queue.Queue = null;

pub fn requestRepaint() void {
    g_repaint_pending.store(true, .release);

    const driver = g_render_driver orelse return;
    g_repaint_pending.store(false, .release);

    msgSend3(
        void,
        SEL,
        id,
        BOOL,
        driver,
        sel("performSelectorOnMainThread:withObject:waitUntilDone:"),
        sel("tick:"),
        null,
        0,
    );
}

pub fn run(
    title: []const u8,
    width: f64,
    height: f64,
    quit_after_ms: ?u64,
    trace: ?*TraceWriter,
    surface_id: u32,
    input: ?*input_queue.Queue,
) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedOS;

    // When launched from a plain terminal (not an .app bundle), macOS may treat
    // the process as background-only, which makes the window effectively
    // invisible to the user. Force-transform to a foreground GUI process.
    ensureForegroundProcess();

    g_input = input;

    const pool = msgSend0(id, classId("NSAutoreleasePool"), sel("new"));
    defer msgSend0(void, pool, sel("drain"));
    if (trace) |t| t.instant("ui_pool_ready", "ui") catch {};

    const app = msgSend0(id, classId("NSApplication"), sel("sharedApplication"));
    _ = msgSend1(BOOL, i64, app, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);
    if (trace) |t| t.instant("ui_app_ready", "ui") catch {};

    const delegate = try makeAppDelegate();
    msgSend1(void, id, app, sel("setDelegate:"), delegate);

    const window = try createWindow(title, width, height);
    if (trace) |t| t.instant("ui_window_ready", "ui") catch {};
    try setupMetal(window, width, height, surface_id, trace);

    if (quit_after_ms) |ms| {
        const delay_s: f64 = @as(f64, @floatFromInt(ms)) / 1000.0;
        scheduleQuitTimer(app, delay_s);
    }

    msgSend1(void, BOOL, app, sel("activateIgnoringOtherApps:"), 1);
    msgSend0(void, app, sel("run"));
}

fn ensureForegroundProcess() void {
    var psn: ProcessSerialNumber = .{ .highLongOfPSN = 0, .lowLongOfPSN = 0 };
    if (GetCurrentProcess(&psn) != 0) return;
    _ = TransformProcessType(&psn, kProcessTransformToForegroundApplication);
    _ = SetFrontProcess(&psn);
}

const CFRunLoopTimerContext = extern struct {
    version: isize,
    info: ?*anyopaque,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copy_description: ?*const anyopaque,
};

const CFRunLoopTimerCallBack = *const fn (timer: id, info: ?*anyopaque) callconv(.c) void;
extern "c" fn CFRunLoopTimerCreate(
    alloc: id,
    fire_date: f64,
    interval: f64,
    flags: usize,
    order: isize,
    callout: CFRunLoopTimerCallBack,
    context: ?*CFRunLoopTimerContext,
) id;

fn quitTimerFired(_: id, info: ?*anyopaque) callconv(.c) void {
    _ = info;
    const app = g_app_for_quit orelse return;
    msgSend1(void, id, app, sel("stop:"), null);
    postStopEvent(app);
}

fn postStopEvent(app: id) void {
    const event = msgSend9(
        id,
        NSUInteger,
        NSPoint,
        NSUInteger,
        f64,
        isize,
        id,
        i16,
        isize,
        isize,
        classId("NSEvent"),
        sel("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:"),
        NSEventTypeApplicationDefined,
        .{ .x = 0, .y = 0 },
        0,
        0,
        0,
        null,
        0,
        0,
        0,
    );
    if (event == null) return;
    msgSend2(void, id, BOOL, app, sel("postEvent:atStart:"), event, 1);
}

fn scheduleQuitTimer(app: id, delay_s: f64) void {
    const now = CFAbsoluteTimeGetCurrent();
    g_app_for_quit = app;

    const timer = CFRunLoopTimerCreate(
        null,
        now + delay_s,
        0,
        0,
        0,
        quitTimerFired,
        null,
    );
    if (timer == null) return;
    const rl = CFRunLoopGetCurrent();
    CFRunLoopAddTimer(rl, timer, kCFRunLoopDefaultMode);
    CFRunLoopAddTimer(rl, timer, kCFRunLoopCommonModes);
    // Keep a reference; this also avoids relying on CFRunLoop retaining behavior.
}

fn createWindow(title: []const u8, width: f64, height: f64) !id {
    const rect = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = width, .height = height },
    };

    const style_mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

    const window_alloc = msgSend0(id, classId("NSWindow"), sel("alloc"));
    const window = msgSend4(id, NSRect, u64, u64, BOOL, window_alloc, sel("initWithContentRect:styleMask:backing:defer:"), rect, style_mask, NSBackingStoreBuffered, 0);

    const ns_title = try nsString(title);
    msgSend1(void, id, window, sel("setTitle:"), ns_title);
    msgSend0(void, window, sel("center"));
    msgSend1(void, id, window, sel("makeKeyAndOrderFront:"), null);
    msgSend0(void, window, sel("displayIfNeeded"));
    return window;
}

fn setupMetal(window: id, width: f64, height: f64, surface_id: u32, trace: ?*TraceWriter) !void {
    const device = MTLCreateSystemDefaultDevice() orelse return error.MetalDeviceUnavailable;

    const layer = msgSend0(id, classId("CAMetalLayer"), sel("layer"));
    if (layer == null) return error.MetalLayerUnavailable;

    msgSend1(void, id, layer, sel("setDevice:"), device);
    msgSend1(void, u64, layer, sel("setPixelFormat:"), MTLPixelFormatBGRA8Unorm);
    msgSend1(void, BOOL, layer, sel("setFramebufferOnly:"), 0);

    const drawable_size = NSSize{ .width = width, .height = height };
    msgSend1(void, NSSize, layer, sel("setDrawableSize:"), drawable_size);

    const rect = NSRect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = width, .height = height },
    };

    const view = try makeInputView(rect);
    msgSend1(void, id, window, sel("setContentView:"), view);
    msgSend1(void, id, window, sel("makeFirstResponder:"), view);

    msgSend1(void, BOOL, view, sel("setWantsLayer:"), 1);
    msgSend1(void, id, view, sel("setLayer:"), layer);
    if (trace) |t| t.instant("ui_metal_layer_attached", "ui") catch {};

    try initRenderState(device, layer, width, height, surface_id, trace);
    g_render_driver = try makeRenderDriver();
    if (g_repaint_pending.load(.acquire)) requestRepaint();
    presentFrame();
}

fn viewAcceptsFirstResponder(_: id, _: SEL) callconv(.c) BOOL {
    return 1;
}

fn viewIsFlipped(_: id, _: SEL) callconv(.c) BOOL {
    // Keep coordinate system consistent with our display list (top-left origin, y down).
    return 1;
}

fn viewKeyDown(_: id, _: SEL, event: id) callconv(.c) void {
    const q = g_input orelse return;
    if (event == null) return;

    const chars = msgSend0(id, event, sel("characters"));
    if (chars == null) return;

    const cstr_opt = msgSend0(?[*:0]const u8, chars, sel("UTF8String"));
    const cstr = cstr_opt orelse return;

    const bytes = std.mem.span(cstr);
    for (bytes) |b| {
        switch (b) {
            '\r', '\n' => q.push(.enter),
            0x7F => q.push(.backspace),
            else => q.push(.{ .byte = b }),
        }
    }
}

fn viewScrollWheel(_: id, _: SEL, event: id) callconv(.c) void {
    const q = g_input orelse return;
    if (event == null) return;

    const dy = msgSend0(f64, event, sel("scrollingDeltaY"));
    if (dy == 0) return;

    var delta_i32: i32 = @intFromFloat(dy);
    if (delta_i32 > 200) delta_i32 = 200;
    if (delta_i32 < -200) delta_i32 = -200;
    if (delta_i32 == 0) return;

    q.push(.{ .scroll = delta_i32 });
}

fn viewMouseDown(view: id, _: SEL, event: id) callconv(.c) void {
    const q = g_input orelse return;
    if (event == null or view == null) return;

    const p_window = msgSend0(NSPoint, event, sel("locationInWindow"));
    const p_view = msgSend2(NSPoint, NSPoint, id, view, sel("convertPoint:fromView:"), p_window, null);

    const x: i32 = @intFromFloat(p_view.x);
    const y: i32 = @intFromFloat(p_view.y);
    q.push(.{ .click = .{ .x = x, .y = y } });
}

fn makeInputView(frame: NSRect) !id {
    const NSView = getClass("NSView");
    const view_name: [:0]const u8 = "ZBMetalView";

    const ViewClass: Class = blk: {
        if (objc_getClass(view_name.ptr) != null) break :blk getClass(view_name);

        const cls: Class = objc_allocateClassPair(NSView, view_name.ptr, 0) orelse return error.ObjCAllocClassFailed;
        if (class_addMethod(cls, sel("acceptsFirstResponder"), @ptrCast(&viewAcceptsFirstResponder), "c@:") == 0) {
            return error.ObjCAddMethodFailed;
        }
        if (class_addMethod(cls, sel("isFlipped"), @ptrCast(&viewIsFlipped), "c@:") == 0) {
            return error.ObjCAddMethodFailed;
        }
        if (class_addMethod(cls, sel("keyDown:"), @ptrCast(&viewKeyDown), "v@:@") == 0) {
            return error.ObjCAddMethodFailed;
        }
        if (class_addMethod(cls, sel("scrollWheel:"), @ptrCast(&viewScrollWheel), "v@:@") == 0) {
            return error.ObjCAddMethodFailed;
        }
        if (class_addMethod(cls, sel("mouseDown:"), @ptrCast(&viewMouseDown), "v@:@") == 0) {
            return error.ObjCAddMethodFailed;
        }
        objc_registerClassPair(cls);
        break :blk cls;
    };

    const view_alloc = msgSend0(id, ViewClass, sel("alloc"));
    return msgSend1(id, NSRect, view_alloc, sel("initWithFrame:"), frame);
}

fn initRenderState(device: id, layer: id, fallback_width: f64, fallback_height: f64, surface_id: u32, trace: ?*TraceWriter) !void {
    const queue = msgSend0(id, device, sel("newCommandQueue")) orelse return error.MetalQueueUnavailable;

    var surface_tex: ?id = null;
    var surface_w: NSUInteger = @intFromFloat(fallback_width);
    var surface_h: NSUInteger = @intFromFloat(fallback_height);

    const surface = IOSurfaceLookup(surface_id);
    if (surface != null) {
        defer CFRelease(surface);
        surface_w = IOSurfaceGetWidth(surface);
        surface_h = IOSurfaceGetHeight(surface);

        const desc = msgSend4(
            id,
            u64,
            NSUInteger,
            NSUInteger,
            BOOL,
            classId("MTLTextureDescriptor"),
            sel("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
            MTLPixelFormatBGRA8Unorm,
            surface_w,
            surface_h,
            0,
        );
        if (desc != null) {
            msgSend1(void, u64, desc, sel("setUsage:"), MTLTextureUsageShaderRead);
            msgSend1(void, u64, desc, sel("setStorageMode:"), MTLStorageModeShared);

            const tex = msgSend3(id, id, id, NSUInteger, device, sel("newTextureWithDescriptor:iosurface:plane:"), desc, surface, 0);
            if (tex != null) surface_tex = tex;
        }
    } else {
        if (trace) |t| t.instant("ui_iosurface_lookup_failed", "ui") catch {};
    }

    g_render_state = .{
        .device = device,
        .queue = queue,
        .layer = layer,
        .surface_tex = surface_tex,
        .surface_w = surface_w,
        .surface_h = surface_h,
        .trace = trace,
    };
    g_first_present_sent = false;
}

fn renderDriverTick(_: id, _: SEL, _: id) callconv(.c) void {
    presentFrame();
}

fn makeRenderDriver() !id {
    const NSObject = getClass("NSObject");
    const driver_name: [:0]const u8 = "ZBRenderDriver";

    if (objc_getClass(driver_name.ptr) != null) {
        return msgSend0(id, classId(driver_name), sel("new"));
    }

    const DriverClass: Class = objc_allocateClassPair(NSObject, driver_name.ptr, 0) orelse return error.ObjCAllocClassFailed;
    const tick_sel = sel("tick:");
    const tick_types: [*:0]const u8 = "v@:@";
    if (class_addMethod(DriverClass, tick_sel, @ptrCast(&renderDriverTick), tick_types) == 0) {
        return error.ObjCAddMethodFailed;
    }
    objc_registerClassPair(DriverClass);
    return msgSend0(id, DriverClass, sel("new"));
}

fn presentFrame() void {
    const state = g_render_state orelse return;

    const drawable = msgSend0(id, state.layer, sel("nextDrawable"));
    if (drawable == null) return;

    const texture = msgSend0(id, drawable, sel("texture"));
    if (texture == null) return;

    if (state.surface_tex) |surface_tex| {
        const queue = state.queue orelse return;
        const command_buffer = msgSend0(id, queue, sel("commandBuffer"));
        if (command_buffer == null) return;

        const blit = msgSend0(id, command_buffer, sel("blitCommandEncoder"));
        if (blit == null) return;

        const origin = MTLOrigin{ .x = 0, .y = 0, .z = 0 };
        const size = MTLSize{ .width = state.surface_w, .height = state.surface_h, .depth = 1 };

        msgSend9(
            void,
            id,
            NSUInteger,
            NSUInteger,
            MTLOrigin,
            MTLSize,
            id,
            NSUInteger,
            NSUInteger,
            MTLOrigin,
            blit,
            sel("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:"),
            surface_tex,
            0,
            0,
            origin,
            size,
            texture,
            0,
            0,
            origin,
        );
        msgSend0(void, blit, sel("endEncoding"));
        msgSend1(void, id, command_buffer, sel("presentDrawable:"), drawable);
        msgSend0(void, command_buffer, sel("commit"));
        if (!g_first_present_sent) {
            g_first_present_sent = true;
            if (state.trace) |t| t.instant("ui_first_present_submitted", "ui") catch {};
        }
        return;
    }

    drawClear(state.device, drawable, texture, state.trace);
}

fn drawClear(device: id, drawable: id, texture: id, trace: ?*TraceWriter) void {
    const rpd = msgSend0(id, classId("MTLRenderPassDescriptor"), sel("renderPassDescriptor"));
    if (rpd == null) return;

    const color_attachments = msgSend0(id, rpd, sel("colorAttachments"));
    if (color_attachments == null) return;

    const color0 = msgSend1(id, u64, color_attachments, sel("objectAtIndexedSubscript:"), 0);
    if (color0 == null) return;

    msgSend1(void, id, color0, sel("setTexture:"), texture);
    msgSend1(void, u64, color0, sel("setLoadAction:"), MTLLoadActionClear);
    msgSend1(void, u64, color0, sel("setStoreAction:"), MTLStoreActionStore);
    msgSend1(void, MTLClearColor, color0, sel("setClearColor:"), .{ .red = 0.08, .green = 0.09, .blue = 0.11, .alpha = 1.0 });

    const queue = msgSend0(id, device, sel("newCommandQueue"));
    if (queue == null) return;
    _ = msgSend0(id, queue, sel("autorelease"));

    const command_buffer = msgSend0(id, queue, sel("commandBuffer"));
    if (command_buffer == null) return;

    const encoder = msgSend1(id, id, command_buffer, sel("renderCommandEncoderWithDescriptor:"), rpd);
    if (encoder == null) return;

    msgSend0(void, encoder, sel("endEncoding"));
    msgSend1(void, id, command_buffer, sel("presentDrawable:"), drawable);
    msgSend0(void, command_buffer, sel("commit"));
    if (!g_first_present_sent) {
        g_first_present_sent = true;
        if (trace) |t| t.instant("ui_first_present_submitted", "ui") catch {};
    }
}

fn nsString(str: []const u8) !id {
    var buf: [1024:0]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{str});
    return msgSend1(id, [*:0]const u8, classId("NSString"), sel("stringWithUTF8String:"), z.ptr);
}

fn makeAppDelegate() !id {
    const NSObject = getClass("NSObject");
    const delegate_name: [:0]const u8 = "ZBAppDelegate";

    // If already registered, just instantiate it.
    if (objc_getClass(delegate_name.ptr) != null) {
        return msgSend0(id, classId(delegate_name), sel("new"));
    }

    const DelegateClass: Class = objc_allocateClassPair(NSObject, delegate_name.ptr, 0) orelse return error.ObjCAllocClassFailed;

    const last_window_closed_sel = sel("applicationShouldTerminateAfterLastWindowClosed:");
    const last_window_closed_types: [*:0]const u8 = "c@:@";
    if (class_addMethod(DelegateClass, last_window_closed_sel, @ptrCast(&applicationShouldTerminateAfterLastWindowClosed), last_window_closed_types) == 0) {
        return error.ObjCAddMethodFailed;
    }

    const should_terminate_sel = sel("applicationShouldTerminate:");
    const should_terminate_types: [*:0]const u8 = "q@:@";
    if (class_addMethod(DelegateClass, should_terminate_sel, @ptrCast(&applicationShouldTerminate), should_terminate_types) == 0) {
        return error.ObjCAddMethodFailed;
    }

    objc_registerClassPair(DelegateClass);
    return msgSend0(id, DelegateClass, sel("new"));
}

fn applicationShouldTerminateAfterLastWindowClosed(_: id, _: SEL, _: id) callconv(.c) BOOL {
    return 1;
}

fn applicationShouldTerminate(_: id, _: SEL, sender: id) callconv(.c) i64 {
    msgSend1(void, id, sender, sel("stop:"), null);
    return NSTerminateCancel;
}
