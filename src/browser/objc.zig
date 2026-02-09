const std = @import("std");

pub const id = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const BOOL = i8;

pub extern "c" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
pub extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extraBytes: usize) Class;
pub extern "c" fn objc_registerClassPair(cls: Class) void;
pub extern "c" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) BOOL;
pub extern "c" fn objc_msgSend() callconv(.c) void;

pub fn getClass(name: [:0]const u8) Class {
    return objc_getClass(name.ptr) orelse @panic("objc_getClass returned null");
}

pub fn classId(name: [:0]const u8) id {
    return getClass(name);
}

pub fn sel(name: [:0]const u8) SEL {
    return sel_registerName(name.ptr);
}

pub fn msgSend0(comptime Ret: type, receiver: anytype, selector: SEL) Ret {
    const Fn = *const fn (@TypeOf(receiver), SEL) callconv(.c) Ret;
    const f: Fn = @ptrCast(&objc_msgSend);
    return f(receiver, selector);
}

pub fn msgSend1(comptime Ret: type, comptime A0: type, receiver: anytype, selector: SEL, a0: A0) Ret {
    const Fn = *const fn (@TypeOf(receiver), SEL, A0) callconv(.c) Ret;
    const f: Fn = @ptrCast(&objc_msgSend);
    return f(receiver, selector, a0);
}

pub fn msgSend2(
    comptime Ret: type,
    comptime A0: type,
    comptime A1: type,
    receiver: anytype,
    selector: SEL,
    a0: A0,
    a1: A1,
) Ret {
    const Fn = *const fn (@TypeOf(receiver), SEL, A0, A1) callconv(.c) Ret;
    const f: Fn = @ptrCast(&objc_msgSend);
    return f(receiver, selector, a0, a1);
}

pub fn msgSend3(
    comptime Ret: type,
    comptime A0: type,
    comptime A1: type,
    comptime A2: type,
    receiver: anytype,
    selector: SEL,
    a0: A0,
    a1: A1,
    a2: A2,
) Ret {
    const Fn = *const fn (@TypeOf(receiver), SEL, A0, A1, A2) callconv(.c) Ret;
    const f: Fn = @ptrCast(&objc_msgSend);
    return f(receiver, selector, a0, a1, a2);
}

pub fn msgSend4(
    comptime Ret: type,
    comptime A0: type,
    comptime A1: type,
    comptime A2: type,
    comptime A3: type,
    receiver: anytype,
    selector: SEL,
    a0: A0,
    a1: A1,
    a2: A2,
    a3: A3,
) Ret {
    const Fn = *const fn (@TypeOf(receiver), SEL, A0, A1, A2, A3) callconv(.c) Ret;
    const f: Fn = @ptrCast(&objc_msgSend);
    return f(receiver, selector, a0, a1, a2, a3);
}

pub fn msgSend5(
    comptime Ret: type,
    comptime A0: type,
    comptime A1: type,
    comptime A2: type,
    comptime A3: type,
    comptime A4: type,
    receiver: anytype,
    selector: SEL,
    a0: A0,
    a1: A1,
    a2: A2,
    a3: A3,
    a4: A4,
) Ret {
    const Fn = *const fn (@TypeOf(receiver), SEL, A0, A1, A2, A3, A4) callconv(.c) Ret;
    const f: Fn = @ptrCast(&objc_msgSend);
    return f(receiver, selector, a0, a1, a2, a3, a4);
}

pub fn msgSend9(
    comptime Ret: type,
    comptime A0: type,
    comptime A1: type,
    comptime A2: type,
    comptime A3: type,
    comptime A4: type,
    comptime A5: type,
    comptime A6: type,
    comptime A7: type,
    comptime A8: type,
    receiver: anytype,
    selector: SEL,
    a0: A0,
    a1: A1,
    a2: A2,
    a3: A3,
    a4: A4,
    a5: A5,
    a6: A6,
    a7: A7,
    a8: A8,
) Ret {
    const Fn = *const fn (@TypeOf(receiver), SEL, A0, A1, A2, A3, A4, A5, A6, A7, A8) callconv(.c) Ret;
    const f: Fn = @ptrCast(&objc_msgSend);
    return f(receiver, selector, a0, a1, a2, a3, a4, a5, a6, a7, a8);
}

