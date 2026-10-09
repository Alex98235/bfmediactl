//! Minimal WinRT/COM interop layer.
//!
//! Deliberately avoids `std.DynLib` (Windows support is broken in Zig 0.17.0/0.18-dev.131)
//! and `std.Io` (the new sleep interface) by going straight to kernel32. The WinRT ABI is
//! just COM: we resolve `combase.dll` exports at runtime and dispatch vtable slots by index.

const std = @import("std");

pub const HRESULT = i32;
pub const HSTRING = *anyopaque;
pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};
pub const WINAPI = std.builtin.CallingConvention.winapi;

/// Interface IDs, verified against Windows.Media.Control.winmd.
pub const IID = struct {
    pub const session_manager_statics = GUID{
        .Data1 = 0x2050c4ee,
        .Data2 = 0x11a0,
        .Data3 = 0x57de,
        .Data4 = .{ 0xae, 0xd7, 0xc9, 0x7c, 0x70, 0x33, 0x82, 0x45 },
    };
    pub const async_info = GUID{
        .Data1 = 0x00000036,
        .Data2 = 0x0000,
        .Data3 = 0x0000,
        .Data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
    };
};

// -- kernel32 (linked by Zig on Windows) -------------------------------------

extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(WINAPI) ?*const anyopaque;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(WINAPI) void;
extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn WriteFile(hFile: ?*anyopaque, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: ?*u32, lpOverlapped: ?*anyopaque) callconv(WINAPI) i32;

const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5; // (DWORD)-11

// -- combase exports ---------------------------------------------------------

const RoInitializeFn = *const fn (u32) callconv(WINAPI) HRESULT;
const RoUninitializeFn = *const fn () callconv(WINAPI) void;
const RoGetActivationFactoryFn = *const fn (HSTRING, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT;
const WindowsCreateStringFn = *const fn ([*]const u16, u32, *HSTRING) callconv(WINAPI) HRESULT;
const WindowsGetStringRawBufferFn = *const fn (HSTRING, ?*u32) callconv(WINAPI) [*]const u16;
const WindowsDeleteStringFn = *const fn (HSTRING) callconv(WINAPI) HRESULT;

pub const Api = struct {
    RoInitialize: RoInitializeFn,
    RoUninitialize: RoUninitializeFn,
    RoGetActivationFactory: RoGetActivationFactoryFn,
    WindowsCreateString: WindowsCreateStringFn,
    WindowsGetStringRawBuffer: WindowsGetStringRawBufferFn,
    WindowsDeleteString: WindowsDeleteStringFn,

    pub fn load() !Api {
        const combase = LoadLibraryA("combase.dll") orelse return error.LoadCombaseFailed;
        return .{
            .RoInitialize = @ptrCast(GetProcAddress(combase, "RoInitialize") orelse return error.MissingRoInitialize),
            .RoUninitialize = @ptrCast(GetProcAddress(combase, "RoUninitialize") orelse return error.MissingRoUninitialize),
            .RoGetActivationFactory = @ptrCast(GetProcAddress(combase, "RoGetActivationFactory") orelse return error.MissingRoGetActivationFactory),
            .WindowsCreateString = @ptrCast(GetProcAddress(combase, "WindowsCreateString") orelse return error.MissingWindowsCreateString),
            .WindowsGetStringRawBuffer = @ptrCast(GetProcAddress(combase, "WindowsGetStringRawBuffer") orelse return error.MissingWindowsGetStringRawBuffer),
            .WindowsDeleteString = @ptrCast(GetProcAddress(combase, "WindowsDeleteString") orelse return error.MissingWindowsDeleteString),
        };
    }
};

/// Global API table, set once by `init()`.
pub var api: Api = undefined;

/// Initialize WinRT (MTA) and load combase exports. Call once at startup.
pub fn init() !void {
    api = try Api.load();
    const r = api.RoInitialize(1); // RO_INIT_MULTITHREADED
    if (r < 0) return error.RoInitializeFailed;
}

pub fn deinit() void {
    api.RoUninitialize();
}

// -- COM vtable dispatch -----------------------------------------------------

/// Read the vtable pointer at the head of a COM object.
pub fn vtable(obj: *anyopaque) [*]const *const anyopaque {
    return @as(*const [*]const *const anyopaque, @ptrCast(@alignCast(obj))).*;
}

/// Fetch `slot` of `obj`'s vtable typed as the function pointer `Fn`.
pub fn method(obj: *anyopaque, comptime slot: usize, comptime Fn: type) Fn {
    return @ptrCast(vtable(obj)[slot]);
}

pub fn release(obj: ?*anyopaque) void {
    const p = obj orelse return;
    const Release = method(p, 2, *const fn (*anyopaque) callconv(WINAPI) u32);
    _ = Release(p);
}

// -- HSTRING helpers ---------------------------------------------------------

pub fn hstringCreate(utf8: []const u8, scratch: []u16) !HSTRING {
    const n = try std.unicode.utf8ToUtf16Le(scratch, utf8);
    var hs: HSTRING = undefined;
    const r = api.WindowsCreateString(scratch.ptr, @intCast(n), &hs);
    if (r < 0) return error.HStringCreateFailed;
    return hs;
}

pub fn hstringDelete(hs: HSTRING) void {
    _ = api.WindowsDeleteString(hs);
}

/// Copy an HSTRING's UTF-16 payload into `out` as UTF-8; returns the used slice.
pub fn hstringToUtf8(hs: HSTRING, out: []u8) []const u8 {
    var len: u32 = 0;
    const ptr = api.WindowsGetStringRawBuffer(hs, &len);
    if (len == 0) return out[0..0];
    const n = std.unicode.utf16LeToUtf8(out, ptr[0..len]) catch return out[0..0];
    return out[0..n];
}

// -- Activation + async ------------------------------------------------------

pub fn activationFactory(class_name: []const u8, iid: *const GUID) !*anyopaque {
    var scratch: [160]u16 = undefined;
    const hs = try hstringCreate(class_name, &scratch);
    defer hstringDelete(hs);
    var factory: ?*anyopaque = null;
    const r = api.RoGetActivationFactory(hs, iid, &factory);
    if (r < 0) return error.ActivationFactoryFailed;
    return factory orelse error.NullActivationFactory;
}

const AsyncStatus = enum(u32) { started = 0, completed = 1, canceled = 2, err = 3 };

/// Block until an `IAsyncOperation<T>` completes (poll IAsyncInfo::get_Status).
pub fn awaitAsync(async_op: *anyopaque) !void {
    const QueryInterface = method(async_op, 0, *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT);
    var info: ?*anyopaque = null;
    if (QueryInterface(async_op, &IID.async_info, &info) < 0) return error.QiAsyncInfoFailed;
    defer release(info);

    const GetStatus = method(info.?, 7, *const fn (*anyopaque, *u32) callconv(WINAPI) HRESULT);
    var status: u32 = 0;
    var polls: usize = 0;
    while (polls < 2000) : (polls += 1) {
        _ = GetStatus(info.?, &status);
        if (status != 0) break;
        Sleep(5);
    }
    switch (@as(AsyncStatus, @enumFromInt(status))) {
        .completed => return,
        .canceled => return error.AsyncCanceled,
        .err => return error.AsyncFailed,
        .started => return error.AsyncTimedOut,
    }
}

/// Await an `IAsyncOperation<T>` and fetch its `T` result through `GetResults` (slot 8).
pub fn awaitAndGet(async_op: *anyopaque) !*anyopaque {
    try awaitAsync(async_op);
    const GetResults = method(async_op, 8, *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT);
    var out: ?*anyopaque = null;
    if (GetResults(async_op, &out) < 0) return error.GetResultsFailed;
    return out orelse error.NullAsyncResult;
}

// -- Output ------------------------------------------------------------------

pub fn stdoutWrite(bytes: []const u8) void {
    const h = GetStdHandle(STD_OUTPUT_HANDLE) orelse return;
    var written: u32 = 0;
    _ = WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null);
}

pub fn hresult(hr: HRESULT) u32 {
    return @bitCast(hr);
}
