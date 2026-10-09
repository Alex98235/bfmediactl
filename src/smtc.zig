//! Windows System Media Transport Controls (SMTC) bindings.
//!
//! Wraps `Windows.Media.Control.*` over the raw vtable layout documented in
//! the module comments. Slot indices sit after IInspectable's six methods
//! (0..5), so interface-specific members start at 6.

const std = @import("std");
const winrt = @import("winrt.zig");

const HRESULT = winrt.HRESULT;
const HSTRING = winrt.HSTRING;
const WINAPI = winrt.WINAPI;

pub const MaxSessions = 32;

/// Fixed-capacity UTF-8 string buffer (avoids allocator/API churn).
fn Fixed(comptime N: usize) type {
    return struct {
        data: [N]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, N);
            @memcpy(self.data[0..n], s[0..n]);
            self.len = n;
        }

        pub fn get(self: *const Self) []const u8 {
            return self.data[0..self.len];
        }
    };
}

pub const Status = enum(u32) {
    closed = 0,
    opened = 1,
    changing = 2,
    stopped = 3,
    playing = 4,
    paused = 5,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .closed => "closed",
            .opened => "opened",
            .changing => "changing",
            .stopped => "stopped",
            .playing => "playing",
            .paused => "paused",
        };
    }
};

pub const Info = struct {
    source: Fixed(256) = .{},
    status: Status = .closed,
    title: Fixed(512) = .{},
    artist: Fixed(512) = .{},
    album: Fixed(512) = .{},
    album_artist: Fixed(512) = .{},
    track_number: i32 = 0,
    position_ticks: i64 = 0,
    duration_ticks: i64 = 0,

    pub fn positionMs(self: *const Info) i64 {
        return @divTrunc(self.position_ticks, 10_000);
    }

    pub fn durationMs(self: *const Info) i64 {
        return @divTrunc(self.duration_ticks, 10_000);
    }
};

const Slot = struct {
    // IGlobalSystemMediaTransportControlsSessionManagerStatics
    const statics_request_async = 6;
    // IGlobalSystemMediaTransportControlsSessionManager
    const mgr_get_current = 6;
    const mgr_get_sessions = 7;
    // IVectorView<T>
    const vec_get_at = 6;
    const vec_size = 7;
    // IGlobalSystemMediaTransportControlsSession
    const get_source_aumid = 6;
    const try_get_media_properties = 7;
    const get_timeline = 8;
    const get_playback_info = 9;
    const try_play = 10;
    const try_pause = 11;
    const try_stop = 12;
    const try_skip_next = 16;
    const try_skip_previous = 17;
    const try_toggle = 20;
    const try_change_repeat = 21;
    const try_change_shuffle = 23;
    const try_change_position = 24;
    // IGlobalSystemMediaTransportControlsSessionMediaProperties
    const mp_title = 6;
    const mp_artist = 9;
    const mp_album_title = 10;
    const mp_track_number = 11;
    const mp_album_artist = 8;
    // IGlobalSystemMediaTransportControlsSessionPlaybackInfo
    const pi_status = 7;
    // IGlobalSystemMediaTransportControlsSessionTimelineProperties
    const tl_start = 6;
    const tl_end = 7;
    const tl_position = 10;
};

/// Activate the session manager (RequestAsync -> manager). Caller releases.
pub fn acquireManager() !*anyopaque {
    const factory = try winrt.activationFactory(
        "Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager",
        &winrt.IID.session_manager_statics,
    );
    defer winrt.release(factory);

    const RequestAsync = winrt.method(factory, Slot.statics_request_async, *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT);
    var op: ?*anyopaque = null;
    if (RequestAsync(factory, &op) < 0) return error.RequestAsyncFailed;
    const op_ptr = op orelse return error.NullAsyncOp;
    defer winrt.release(op_ptr);
    return winrt.awaitAndGet(op_ptr);
}

pub fn currentSession(manager: *anyopaque) ?*anyopaque {
    const GetCurrent = winrt.method(manager, Slot.mgr_get_current, *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT);
    var s: ?*anyopaque = null;
    if (GetCurrent(manager, &s) < 0) return null;
    return s;
}

/// Enumerate all sessions into `out`; returns the populated prefix.
pub fn sessions(manager: *anyopaque, out: *[MaxSessions]?*anyopaque) []?*anyopaque {
    const GetSessions = winrt.method(manager, Slot.mgr_get_sessions, *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT);
    var view: ?*anyopaque = null;
    if (GetSessions(manager, &view) < 0) return out[0..0];
    const view_ptr = view orelse return out[0..0];
    defer winrt.release(view_ptr);

    const Size = winrt.method(view_ptr, Slot.vec_size, *const fn (*anyopaque, *u32) callconv(WINAPI) HRESULT);
    const At = winrt.method(view_ptr, Slot.vec_get_at, *const fn (*anyopaque, u32, *?*anyopaque) callconv(WINAPI) HRESULT);
    var size: u32 = 0;
    if (Size(view_ptr, &size) < 0) return out[0..0];
    const n = @min(size, out.len);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var s: ?*anyopaque = null;
        if (At(view_ptr, i, &s) >= 0) out[i] = s;
    }
    return out[0..n];
}

pub fn sourceAumid(session: *anyopaque, out: []u8) []const u8 {
    const Get = winrt.method(session, Slot.get_source_aumid, *const fn (*anyopaque, *HSTRING) callconv(WINAPI) HRESULT);
    var hs: HSTRING = undefined;
    if (Get(session, &hs) < 0) return out[0..0];
    defer winrt.hstringDelete(hs);
    return winrt.hstringToUtf8(hs, out);
}

fn readHstring(obj: *anyopaque, comptime slot: usize, dest: anytype) void {
    const Get = winrt.method(obj, slot, *const fn (*anyopaque, *HSTRING) callconv(WINAPI) HRESULT);
    var hs: HSTRING = undefined;
    if (Get(obj, &hs) < 0) return;
    defer winrt.hstringDelete(hs);
    var buf: [512]u8 = undefined;
    dest.set(winrt.hstringToUtf8(hs, &buf));
}

fn getPlaybackInfo(session: *anyopaque) ?*anyopaque {
    const Get = winrt.method(session, Slot.get_playback_info, *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT);
    var out: ?*anyopaque = null;
    if (Get(session, &out) < 0) return null;
    return out;
}

fn getTimeline(session: *anyopaque) ?*anyopaque {
    const Get = winrt.method(session, Slot.get_timeline, *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT);
    var out: ?*anyopaque = null;
    if (Get(session, &out) < 0) return null;
    return out;
}

fn getMediaProperties(session: *anyopaque) ?*anyopaque {
    const TryGet = winrt.method(session, Slot.try_get_media_properties, *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT);
    var op: ?*anyopaque = null;
    if (TryGet(session, &op) < 0) return null;
    const op_ptr = op orelse return null;
    defer winrt.release(op_ptr);
    return winrt.awaitAndGet(op_ptr) catch null;
}

/// Read the full media snapshot for one session.
pub fn readInfo(session: *anyopaque) Info {
    var info = Info{};
    var aumid_buf: [512]u8 = undefined;
    info.source.set(sourceAumid(session, &aumid_buf));

    if (getPlaybackInfo(session)) |pi| {
        defer winrt.release(pi);
        const GetStatus = winrt.method(pi, Slot.pi_status, *const fn (*anyopaque, *u32) callconv(WINAPI) HRESULT);
        var st: u32 = 0;
        if (GetStatus(pi, &st) >= 0 and st <= 5) info.status = @enumFromInt(st);
    }

    if (getMediaProperties(session)) |mp| {
        defer winrt.release(mp);
        readHstring(mp, Slot.mp_title, &info.title);
        readHstring(mp, Slot.mp_artist, &info.artist);
        readHstring(mp, Slot.mp_album_title, &info.album);
        readHstring(mp, Slot.mp_album_artist, &info.album_artist);
        const GetTrack = winrt.method(mp, Slot.mp_track_number, *const fn (*anyopaque, *i32) callconv(WINAPI) HRESULT);
        _ = GetTrack(mp, &info.track_number);
    }

    if (getTimeline(session)) |tl| {
        defer winrt.release(tl);
        const GetStart = winrt.method(tl, Slot.tl_start, *const fn (*anyopaque, *i64) callconv(WINAPI) HRESULT);
        const GetEnd = winrt.method(tl, Slot.tl_end, *const fn (*anyopaque, *i64) callconv(WINAPI) HRESULT);
        const GetPos = winrt.method(tl, Slot.tl_position, *const fn (*anyopaque, *i64) callconv(WINAPI) HRESULT);
        var start: i64 = 0;
        var end: i64 = 0;
        var pos: i64 = 0;
        _ = GetStart(tl, &start);
        _ = GetEnd(tl, &end);
        _ = GetPos(tl, &pos);
        info.position_ticks = pos - start;
        info.duration_ticks = end - start;
    }
    return info;
}

// -- Transport controls ------------------------------------------------------

fn invokeTryBool(session: *anyopaque, comptime slot: usize) bool {
    const Try = winrt.method(session, slot, *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT);
    var op: ?*anyopaque = null;
    if (Try(session, &op) < 0) return false;
    const op_ptr = op orelse return false;
    defer winrt.release(op_ptr);
    winrt.awaitAsync(op_ptr) catch return false;
    const GetResults = winrt.method(op_ptr, 8, *const fn (*anyopaque, *i32) callconv(WINAPI) HRESULT);
    var result: i32 = 0;
    _ = GetResults(op_ptr, &result);
    return result != 0;
}

pub const Action = enum { play, pause, toggle, next, previous, stop };

pub fn action(session: *anyopaque, a: Action) bool {
    return switch (a) {
        .play => invokeTryBool(session, Slot.try_play),
        .pause => invokeTryBool(session, Slot.try_pause),
        .toggle => invokeTryBool(session, Slot.try_toggle),
        .next => invokeTryBool(session, Slot.try_skip_next),
        .previous => invokeTryBool(session, Slot.try_skip_previous),
        .stop => invokeTryBool(session, Slot.try_stop),
    };
}

pub fn seek(session: *anyopaque, ms: i64) bool {
    const Try = winrt.method(session, Slot.try_change_position, *const fn (*anyopaque, i64, *?*anyopaque) callconv(WINAPI) HRESULT);
    var op: ?*anyopaque = null;
    if (Try(session, ms * 10_000, &op) < 0) return false;
    const op_ptr = op orelse return false;
    defer winrt.release(op_ptr);
    winrt.awaitAsync(op_ptr) catch return false;
    return true;
}

pub fn setShuffle(session: *anyopaque, on: bool) bool {
    const Try = winrt.method(session, Slot.try_change_shuffle, *const fn (*anyopaque, i32, *?*anyopaque) callconv(WINAPI) HRESULT);
    var op: ?*anyopaque = null;
    if (Try(session, if (on) 1 else 0, &op) < 0) return false;
    const op_ptr = op orelse return false;
    defer winrt.release(op_ptr);
    winrt.awaitAsync(op_ptr) catch return false;
    return true;
}

pub const RepeatMode = enum(i32) { none = 0, track = 1, list = 2 };

pub fn setRepeat(session: *anyopaque, mode: RepeatMode) bool {
    const Try = winrt.method(session, Slot.try_change_repeat, *const fn (*anyopaque, i32, *?*anyopaque) callconv(WINAPI) HRESULT);
    var op: ?*anyopaque = null;
    if (Try(session, @intFromEnum(mode), &op) < 0) return false;
    const op_ptr = op orelse return false;
    defer winrt.release(op_ptr);
    winrt.awaitAsync(op_ptr) catch return false;
    return true;
}
