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

/// Windows.Media.MediaPlaybackType.
pub const PlaybackType = enum(i32) {
    unknown = 0,
    music = 1,
    video = 2,
    image = 3,

    pub fn name(self: PlaybackType) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .music => "music",
            .video => "video",
            .image => "image",
        };
    }
};

/// Windows.Media.MediaPlaybackAutoRepeatMode.
pub const RepeatMode = enum(i32) {
    none = 0,
    track = 1,
    list = 2,

    pub fn name(self: RepeatMode) []const u8 {
        return switch (self) {
            .none => "none",
            .track => "track",
            .list => "list",
        };
    }
};

/// Which transport controls the source advertises for this session.
pub const Capabilities = struct {
    play: bool = false,
    pause: bool = false,
    stop: bool = false,
    next: bool = false,
    previous: bool = false,
    toggle: bool = false,
    shuffle: bool = false,
    repeat: bool = false,
    rate: bool = false,
    position: bool = false,
    record: bool = false,
    fast_forward: bool = false,
    rewind: bool = false,
    channel_up: bool = false,
    channel_down: bool = false,
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
    /// Null when the source leaves the underlying IReference<T> unset.
    rate: ?f64 = null,
    shuffle: ?bool = null,
    repeat: ?RepeatMode = null,
    playback_type: ?PlaybackType = null,
    capabilities: Capabilities = .{},

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
    const pi_controls = 6;
    const pi_status = 7;
    const pi_playback_type = 8;
    const pi_repeat = 9;
    const pi_rate = 10;
    const pi_shuffle = 11;
    // IGlobalSystemMediaTransportControlsSessionPlaybackControls
    const pc_play = 6;
    const pc_pause = 7;
    const pc_stop = 8;
    const pc_record = 9;
    const pc_fast_forward = 10;
    const pc_rewind = 11;
    const pc_next = 12;
    const pc_previous = 13;
    const pc_channel_up = 14;
    const pc_channel_down = 15;
    const pc_toggle = 16;
    const pc_shuffle = 17;
    const pc_repeat = 18;
    const pc_rate = 19;
    const pc_position = 20;
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

        info.capabilities = readCapabilities(pi);
        info.rate = readNullable(f64, pi, Slot.pi_rate);
        if (readNullable(i32, pi, Slot.pi_shuffle)) |v| info.shuffle = v != 0;
        if (readNullable(i32, pi, Slot.pi_repeat)) |v| {
            info.repeat = switch (v) {
                0 => .none,
                1 => .track,
                2 => .list,
                else => null,
            };
        }
        if (readNullable(i32, pi, Slot.pi_playback_type)) |v| {
            info.playback_type = switch (v) {
                0 => .unknown,
                1 => .music,
                2 => .video,
                3 => .image,
                else => null,
            };
        }
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

// -- Capabilities + nullable fields ------------------------------------------

fn boolProp(obj: *anyopaque, comptime slot: usize) bool {
    const Get = winrt.method(obj, slot, *const fn (*anyopaque, *i32) callconv(WINAPI) HRESULT);
    var v: i32 = 0;
    if (Get(obj, &v) < 0) return false;
    return v != 0;
}

fn readCapabilities(pi: *anyopaque) Capabilities {
    const GetControls = winrt.method(pi, Slot.pi_controls, *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT);
    var ctrl: ?*anyopaque = null;
    if (GetControls(pi, &ctrl) < 0) return .{};
    const c = ctrl orelse return .{};
    defer winrt.release(c);
    return .{
        .play = boolProp(c, Slot.pc_play),
        .pause = boolProp(c, Slot.pc_pause),
        .stop = boolProp(c, Slot.pc_stop),
        .next = boolProp(c, Slot.pc_next),
        .previous = boolProp(c, Slot.pc_previous),
        .toggle = boolProp(c, Slot.pc_toggle),
        .shuffle = boolProp(c, Slot.pc_shuffle),
        .repeat = boolProp(c, Slot.pc_repeat),
        .rate = boolProp(c, Slot.pc_rate),
        .position = boolProp(c, Slot.pc_position),
        .record = boolProp(c, Slot.pc_record),
        .fast_forward = boolProp(c, Slot.pc_fast_forward),
        .rewind = boolProp(c, Slot.pc_rewind),
        .channel_up = boolProp(c, Slot.pc_channel_up),
        .channel_down = boolProp(c, Slot.pc_channel_down),
    };
}

/// Unwrap a nullable `IReference<T>` getter. The out buffer is zero-initialized,
/// so it is correct whether the ABI writes a 1- or 4-byte boolean.
fn readNullable(comptime T: type, iface: *anyopaque, comptime slot: usize) ?T {
    const Get = winrt.method(iface, slot, *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT);
    var ref: ?*anyopaque = null;
    if (Get(iface, &ref) < 0) return null;
    const r = ref orelse return null;
    defer winrt.release(r);
    const GetValue = winrt.method(r, 6, *const fn (*anyopaque, *T) callconv(WINAPI) HRESULT);
    var out: T = std.mem.zeroes(T);
    if (GetValue(r, &out) < 0) return null;
    return out;
}

// -- Transport controls ------------------------------------------------------

/// Control-call failures, shared by every transport command.
pub const ControlError = error{
    /// The source refused the request (the async boolean result was false).
    Rejected,
    /// The call itself failed (bad HRESULT, null operation, or async failure).
    CallFailed,
};

/// Await a completed `IAsyncOperation<bool>` and map its result.
fn finishBool(op: ?*anyopaque) ControlError!void {
    const op_ptr = op orelse return error.CallFailed;
    defer winrt.release(op_ptr);
    winrt.awaitAsync(op_ptr) catch return error.CallFailed;
    const GetResults = winrt.method(op_ptr, 8, *const fn (*anyopaque, *i32) callconv(WINAPI) HRESULT);
    var result: i32 = 0;
    _ = GetResults(op_ptr, &result);
    if (result == 0) return error.Rejected;
}

/// Invoke a no-argument `Try*Async` control and map its result.
fn invokeTry(session: *anyopaque, comptime slot: usize) ControlError!void {
    const Try = winrt.method(session, slot, *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT);
    var op: ?*anyopaque = null;
    if (Try(session, &op) < 0) return error.CallFailed;
    return finishBool(op);
}

pub const Action = enum { play, pause, toggle, next, previous, stop };

pub fn action(session: *anyopaque, a: Action) ControlError!void {
    return switch (a) {
        .play => invokeTry(session, Slot.try_play),
        .pause => invokeTry(session, Slot.try_pause),
        .toggle => invokeTry(session, Slot.try_toggle),
        .next => invokeTry(session, Slot.try_skip_next),
        .previous => invokeTry(session, Slot.try_skip_previous),
        .stop => invokeTry(session, Slot.try_stop),
    };
}

/// Seek failures. `OutOfRange` is seek-specific; the rest are shared.
pub const SeekError = error{OutOfRange} || ControlError;

/// Seek to `ms` milliseconds from the start. `ms` is unsigned: a position is
/// non-negative by definition. The WinRT call takes a signed `Int64` TimeSpan
/// (100 ns ticks), so we range-check before narrowing.
pub fn seek(session: *anyopaque, ms: u64) SeekError!void {
    const max_ms: u64 = @intCast(@divTrunc(std.math.maxInt(i64), 10_000));
    if (ms > max_ms) return error.OutOfRange;
    const ticks: i64 = @intCast(ms * 10_000);

    const Try = winrt.method(session, Slot.try_change_position, *const fn (*anyopaque, i64, *?*anyopaque) callconv(WINAPI) HRESULT);
    var op: ?*anyopaque = null;
    if (Try(session, ticks, &op) < 0) return error.CallFailed;
    return finishBool(op);
}

pub fn setShuffle(session: *anyopaque, on: bool) ControlError!void {
    const Try = winrt.method(session, Slot.try_change_shuffle, *const fn (*anyopaque, i32, *?*anyopaque) callconv(WINAPI) HRESULT);
    var op: ?*anyopaque = null;
    if (Try(session, if (on) 1 else 0, &op) < 0) return error.CallFailed;
    return finishBool(op);
}

pub fn setRepeat(session: *anyopaque, mode: RepeatMode) ControlError!void {
    const Try = winrt.method(session, Slot.try_change_repeat, *const fn (*anyopaque, i32, *?*anyopaque) callconv(WINAPI) HRESULT);
    var op: ?*anyopaque = null;
    if (Try(session, @intFromEnum(mode), &op) < 0) return error.CallFailed;
    return finishBool(op);
}

// -- Tests (pure logic only; live-session paths need a running source) -------

const testing = std.testing;

test "Fixed copies, truncates, and reports its slice" {
    var b = Fixed(4){};
    b.set("abcdef");
    try testing.expectEqualStrings("abcd", b.get());
    b.set("hi");
    try testing.expectEqualStrings("hi", b.get());
    b.set("");
    try testing.expectEqualStrings("", b.get());
}

test "enum names" {
    try testing.expectEqualStrings("playing", Status.playing.name());
    try testing.expectEqualStrings("paused", Status.paused.name());
    try testing.expectEqualStrings("none", RepeatMode.none.name());
    try testing.expectEqualStrings("list", RepeatMode.list.name());
    try testing.expectEqualStrings("music", PlaybackType.music.name());
}

test "tick to millisecond conversion truncates" {
    var info = Info{};
    info.position_ticks = 12_345_678; // 100 ns ticks -> 1234.5678 ms
    info.duration_ticks = 2_100_000_000; // -> 210000 ms
    try testing.expectEqual(@as(i64, 1234), info.positionMs());
    try testing.expectEqual(@as(i64, 210_000), info.durationMs());
}
