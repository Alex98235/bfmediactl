//! bfmediactl - read and control the Windows media session from the command line.

const std = @import("std");
const winrt = @import("winrt.zig");
const smtc = @import("smtc.zig");

extern "kernel32" fn GetCommandLineW() callconv(winrt.WINAPI) [*:0]const u16;

const usage =
    \\bfmediactl - read and control the Windows media session
    \\
    \\Usage:
    \\  bfmediactl [info] [--source <substr>]      print the current session as JSON
    \\  bfmediactl list                            list sessions as JSON
    \\  bfmediactl play|pause|toggle               transport control
    \\  bfmediactl next|prev|stop                  transport control
    \\  bfmediactl seek <ms>                       seek to a position
    \\  bfmediactl shuffle <on|off>                toggle shuffle
    \\  bfmediactl repeat <none|track|list>        set repeat mode
    \\
    \\Options:
    \\  -s, --source <substr>   pick the session whose AUMID contains <substr>
    \\  -h, --help              show this help
    \\
;

pub fn main() void {
    run() catch |e| {
        std.debug.print("bfmediactl: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
}

/// A resolved command line: the command name plus any trailing arguments.
const Invocation = struct {
    command: []const u8,
    rest: []const []const u8,
};

/// Split parsed positionals into (command, rest), defaulting to "info" when no
/// command was given. Pure (no WinRT), so it is unit-testable.
fn resolveInvocation(args: []const []const u8) Invocation {
    if (args.len == 0) return .{ .command = "info", .rest = args[0..0] };
    return .{ .command = args[0], .rest = args[1..] };
}

fn run() !void {
    try winrt.init();
    defer winrt.deinit();

    const cmd_line = std.mem.span(GetCommandLineW());
    var it = try std.process.Args.Iterator.initAllocator(.{ .vector = cmd_line }, std.heap.page_allocator);
    defer it.deinit();
    _ = it.skip(); // argv[0]

    var positionals: [8][]const u8 = undefined;
    var pos_n: usize = 0;
    var filter: ?[]const u8 = null;

    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--source") or std.mem.eql(u8, a, "-s")) {
            filter = it.next() orelse return error.MissingSourceValue;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            winrt.stdoutWrite(usage);
            return;
        } else if (std.mem.eql(u8, a, "--json")) {
            // info already emits JSON
        } else {
            if (pos_n >= positionals.len) return error.TooManyArguments;
            positionals[pos_n] = a;
            pos_n += 1;
        }
    }

    const inv = resolveInvocation(positionals[0..pos_n]);
    const command = inv.command;
    const rest = inv.rest;

    const manager = try smtc.acquireManager();
    defer winrt.release(manager);

    if (std.mem.eql(u8, command, "list")) {
        var arr: [smtc.MaxSessions]?*anyopaque = undefined;
        const list = smtc.sessions(manager, &arr);
        var out = Buf{};
        out.append("[");
        var buf: [512]u8 = undefined;
        for (list, 0..) |maybe, idx| {
            const s = maybe orelse continue;
            defer winrt.release(s);
            if (idx != 0) out.append(",");
            const info = smtc.readInfo(s);
            out.append("{\"source\":");
            jsonEscape(&out, smtc.sourceAumid(s, &buf));
            out.append(",\"status\":");
            jsonEscape(&out, info.status.name());
            out.append("}");
        }
        out.append("]");
        winrt.stdoutWrite(out.slice());
        winrt.stdoutWrite("\n");
        return;
    }

    const session = selectSession(manager, filter) orelse return error.NoMediaSession;
    defer winrt.release(session);

    if (std.mem.eql(u8, command, "info")) {
        const info = smtc.readInfo(session);
        var out = Buf{};
        emitInfo(&out, &info);
        winrt.stdoutWrite(out.slice());
        winrt.stdoutWrite("\n");
        return;
    }

    if (std.mem.eql(u8, command, "play")) return smtc.action(session, .play);
    if (std.mem.eql(u8, command, "pause")) return smtc.action(session, .pause);
    if (std.mem.eql(u8, command, "toggle")) return smtc.action(session, .toggle);
    if (std.mem.eql(u8, command, "next")) return smtc.action(session, .next);
    if (std.mem.eql(u8, command, "prev") or std.mem.eql(u8, command, "previous"))
        return smtc.action(session, .previous);
    if (std.mem.eql(u8, command, "stop")) return smtc.action(session, .stop);

    if (std.mem.eql(u8, command, "seek")) {
        if (rest.len < 1) return error.MissingValue;
        const ms = std.fmt.parseInt(u64, rest[0], 10) catch return error.InvalidValue;
        return smtc.seek(session, ms);
    }

    if (std.mem.eql(u8, command, "shuffle")) {
        if (rest.len < 1) return error.MissingValue;
        const on = if (std.mem.eql(u8, rest[0], "on"))
            true
        else if (std.mem.eql(u8, rest[0], "off"))
            false
        else
            return error.InvalidValue;
        return smtc.setShuffle(session, on);
    }

    if (std.mem.eql(u8, command, "repeat")) {
        if (rest.len < 1) return error.MissingValue;
        const mode: smtc.RepeatMode = if (std.mem.eql(u8, rest[0], "none"))
            .none
        else if (std.mem.eql(u8, rest[0], "track"))
            .track
        else if (std.mem.eql(u8, rest[0], "list"))
            .list
        else
            return error.InvalidValue;
        return smtc.setRepeat(session, mode);
    }

    return error.UnknownCommand;
}

fn selectSession(manager: *anyopaque, filter: ?[]const u8) ?*anyopaque {
    if (filter) |f| {
        var arr: [smtc.MaxSessions]?*anyopaque = undefined;
        const list = smtc.sessions(manager, &arr);
        var buf: [512]u8 = undefined;
        for (list) |maybe| {
            const s = maybe orelse continue;
            const aumid = smtc.sourceAumid(s, &buf);
            if (containsIgnoreCase(aumid, f)) return s;
        }
        return null;
    }
    return smtc.currentSession(manager);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn emitInfo(out: *Buf, info: *const smtc.Info) void {
    out.append("{\"source\":");
    jsonEscape(out, info.source.get());
    out.append(",\"status\":");
    jsonEscape(out, info.status.name());
    out.append(",\"title\":");
    jsonEscape(out, info.title.get());
    out.append(",\"artist\":");
    jsonEscape(out, info.artist.get());
    out.append(",\"album\":");
    jsonEscape(out, info.album.get());
    out.append(",\"albumArtist\":");
    jsonEscape(out, info.album_artist.get());
    out.print(",\"trackNumber\":{d}", .{info.track_number});
    out.print(",\"positionMs\":{d}", .{info.positionMs()});
    out.print(",\"durationMs\":{d}", .{info.durationMs()});

    out.append(",\"rate\":");
    if (info.rate) |r| out.print("{d}", .{r}) else out.append("null");
    out.append(",\"shuffle\":");
    if (info.shuffle) |s| out.append(if (s) "true" else "false") else out.append("null");
    out.append(",\"repeat\":");
    if (info.repeat) |m| jsonEscape(out, m.name()) else out.append("null");
    out.append(",\"playbackType\":");
    if (info.playback_type) |t| jsonEscape(out, t.name()) else out.append("null");

    emitCapabilities(out, info.capabilities);

    out.append("}");
}

fn emitCapabilities(out: *Buf, caps: smtc.Capabilities) void {
    const fields = .{
        .{ "play", caps.play },
        .{ "pause", caps.pause },
        .{ "stop", caps.stop },
        .{ "next", caps.next },
        .{ "previous", caps.previous },
        .{ "toggle", caps.toggle },
        .{ "shuffle", caps.shuffle },
        .{ "repeat", caps.repeat },
        .{ "rate", caps.rate },
        .{ "position", caps.position },
        .{ "record", caps.record },
        .{ "fastForward", caps.fast_forward },
        .{ "rewind", caps.rewind },
        .{ "channelUp", caps.channel_up },
        .{ "channelDown", caps.channel_down },
    };
    out.append(",\"capabilities\":{");
    inline for (fields, 0..) |f, i| {
        if (i != 0) out.append(",");
        jsonEscape(out, f[0]);
        out.append(":");
        out.append(if (f[1]) "true" else "false");
    }
    out.append("}");
}

/// Fixed-capacity output buffer. Bar output is small; overflow is not a concern.
const Buf = struct {
    data: [16384]u8 = undefined,
    len: usize = 0,

    fn append(self: *Buf, s: []const u8) void {
        if (self.len + s.len > self.data.len) return;
        @memcpy(self.data[self.len .. self.len + s.len], s);
        self.len += s.len;
    }

    fn appendByte(self: *Buf, c: u8) void {
        if (self.len >= self.data.len) return;
        self.data[self.len] = c;
        self.len += 1;
    }

    fn print(self: *Buf, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.data[self.len..], fmt, args) catch return;
        self.len += s.len;
    }

    fn slice(self: *const Buf) []const u8 {
        return self.data[0..self.len];
    }
};

fn jsonEscape(out: *Buf, s: []const u8) void {
    out.appendByte('"');
    for (s) |c| {
        switch (c) {
            '"' => out.append("\\\""),
            '\\' => out.append("\\\\"),
            '\n' => out.append("\\n"),
            '\r' => out.append("\\r"),
            '\t' => out.append("\\t"),
            else => if (c < 0x20) out.print("\\u{x:0>4}", .{c}) else out.appendByte(c),
        }
    }
    out.appendByte('"');
}

// -- Tests -------------------------------------------------------------------

const testing = std.testing;

test "resolveInvocation defaults to info and splits args" {
    const none = resolveInvocation(&[_][]const u8{});
    try testing.expectEqualStrings("info", none.command);
    try testing.expectEqual(@as(usize, 0), none.rest.len);

    const argv = [_][]const u8{ "seek", "1500" };
    const inv = resolveInvocation(&argv);
    try testing.expectEqualStrings("seek", inv.command);
    try testing.expectEqual(@as(usize, 1), inv.rest.len);
    try testing.expectEqualStrings("1500", inv.rest[0]);
}

test "containsIgnoreCase matches substrings case-insensitively" {
    try testing.expect(containsIgnoreCase("Spotify.exe", "spotify"));
    try testing.expect(containsIgnoreCase("SpotifyAB.SpotifyMusic_x!Spotify", "SPOTIFY"));
    try testing.expect(containsIgnoreCase("anything", ""));
    try testing.expect(!containsIgnoreCase("chrome.exe", "spotify"));
    try testing.expect(!containsIgnoreCase("edge", "edgemore"));
}

test "jsonEscape quotes and escapes control characters" {
    var out = Buf{};
    jsonEscape(&out, "a\"b\\c\nd");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\"", out.slice());
}

test "emitInfo produces an object with nullable fields and capabilities" {
    var info = smtc.Info{};
    info.capabilities.play = true;
    var out = Buf{};
    emitInfo(&out, &info);
    const s = out.slice();
    try testing.expectEqual(@as(u8, '{'), s[0]);
    try testing.expectEqual(@as(u8, '}'), s[s.len - 1]);
    try testing.expect(std.mem.indexOf(u8, s, "\"rate\":null") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"repeat\":null") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"capabilities\":{\"play\":true,") != null);
}
