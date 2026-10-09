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

    const command: []const u8 = if (pos_n == 0) "info" else positionals[0];
    const rest = positionals[1..pos_n];

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
