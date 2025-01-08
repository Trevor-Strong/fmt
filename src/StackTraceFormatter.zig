const std = @import("std");
const builtin = @import("builtin");
const fmt = @import("fmt.zig");

const assert = std.debug.assert;
const io = std.io;
const File = std.fs.File;
const StackTrace = std.builtin.StackTrace;

pub const Formatter = @This();

trace: StackTrace,

pub fn init(trace: StackTrace) Formatter {
    return .{ .trace = trace };
}

pub fn format(
    self: Formatter,
    comptime spec: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    const mode: enum {
        force_off,
        force_esc,
        auto,
        auto_or_esc,
        use_stdout,
        use_stderr,
    } = comptime mode: {
        break :mode if (spec.len == 0)
            .force_off
        else if (std.mem.eql(u8, spec, "e"))
            .force_esc
        else if (std.mem.eql(u8, spec, "a"))
            .auto
        else if (std.mem.eql(u8, spec, "ae"))
            .auto_or_esc
        else if (std.mem.eql(u8, spec, "so"))
            .use_stdout
        else if (std.mem.eql(u8, spec, "se"))
            .use_stderr
        else
            @compileError("Invalid stack trace format string: '" ++ spec ++ "'");
    };
    _ = options;
    const dbg_info = std.debug.getSelfDebugInfo() catch return;
    const tty_conf: io.tty.Config = switch (mode) {
        .force_off => .no_color,
        .force_esc => .escape_codes,
        .use_stdout => io.tty.detectConfig(io.getStdOut()),
        .use_stderr => io.tty.detectConfig(io.getStdErr()),
        .auto, .auto_or_esc => switch (@TypeOf(writer)) {
            File.Writer => io.tty.detectConfig(writer.context),
            else => |W| blk: {
                const info = @typeInfo(W);
                if (info == .pointer and
                    info.child == File.Writer and
                    (info.pointer.size == .One or info.pointer.size == .C))
                {
                    break :blk io.tty.detectConfig(writer.context);
                }
                break :blk switch (mode) {
                    .auto => .no_color,
                    .auto_or_esc => .escape_codes,
                    else => unreachable,
                };
            },
        },
    };
    try writer.writeAll("\n");
    std.debug.writeStackTrace(self.trace, writer, dbg_info, tty_conf) catch |err| {
        try writer.print("Unable to print stack trace: {s}\n", .{@errorName(err)});
    };
}

test {
    std.testing.refAllDecls(@This());
}

fn expectFmt(
    expected: []const u8,
    comptime spec: []const u8,
    trace: std.builtin.StackTrace,
) !void {
    try std.testing.expectFmt(expected, "{" ++ spec ++ "}", .{init(trace)});
}

test format {
    var addrs: [128]usize = undefined;
    var stack_trace: std.builtin.StackTrace = .{
        .index = 0,
        .instruction_addresses = &addrs,
    };

    std.debug.captureStackTrace(null, &stack_trace);

    const xterm_str = try std.fmt.allocPrint(std.testing.allocator, "{e}", .{
        init(stack_trace),
    });
    defer std.testing.allocator.free(xterm_str);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{}", .{
        init(stack_trace),
    });
    defer std.testing.allocator.free(xterm_str);

    const stdout_config = io.tty.detectConfig(io.getStdOut());
    const stderr_config = io.tty.detectConfig(io.getStdErr());

    const stdout_expected = switch (stdout_config) {
        .escape_codes => xterm_str,
        else => expected,
    };

    const stderr_expected = switch (stderr_config) {
        .escape_codes => xterm_str,
        else => expected,
    };

    try expectFmt(xterm_str, "e", stack_trace);
    try expectFmt(expected, "", stack_trace);
    try expectFmt(stdout_expected, "so", stack_trace);
    try expectFmt(stderr_expected, "se", stack_trace);
    try expectFmt(expected, "a", stack_trace);
    try expectFmt(xterm_str, "ae", stack_trace);
}

test "auto format to file" {
    var addrs: [128]usize = undefined;
    var stack_trace: std.builtin.StackTrace = .{
        .index = 0,
        .instruction_addresses = &addrs,
    };

    std.debug.captureStackTrace(null, &stack_trace);

    const xterm_str = try std.fmt.allocPrint(std.testing.allocator, "{e}", .{
        init(stack_trace),
    });
    defer std.testing.allocator.free(xterm_str);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{}", .{
        init(stack_trace),
    });
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = tmp_dir.dir;
    const f = try dir.createFile("file.txt", .{ .read = true, .truncate = true });
    defer {
        f.close();
        dir.deleteFile("file.txt") catch {};
    }
    try f.seekTo(0);
    const f_config = io.tty.detectConfig(f);
    const f_expected = switch (f_config) {
        .escape_codes => xterm_str,
        else => expected,
    };

    try f.writer().print("{a}", .{init(stack_trace)});
    const text = try f.readToEndAllocOptions(std.testing.allocator, std.math.maxInt(usize), f_expected.len, 1, null);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(f_expected, text);
}
