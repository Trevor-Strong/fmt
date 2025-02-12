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
    _ = options;
    const mode = comptime FormatMode.parse(spec) catch unreachable;
    const tty_conf: io.tty.Config = ttyForFormatMode(mode, writer) orelse .no_color;
    const dbg_info = std.debug.getSelfDebugInfo() catch |err| {
        try writer.print("Unable to print stack trace: {s}\n", .{@errorName(err)});
        return;
    };
    try writer.writeAll("\n");
    std.debug.writeStackTrace(self.trace, writer, dbg_info, tty_conf) catch |err| {
        try writer.print("Unable to print stack trace: {s}\n", .{@errorName(err)});
    };
}
const FormatMode = enum {
    force_off,
    force_esc,
    use_stdout,
    use_stderr,
    auto,
    auto_or_esc,

    const ParseError = error{InvalidSpecifier};

    fn parse(comptime spec: []const u8) ParseError!FormatMode {
        return if (spec.len == 0)
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
            return error.InvalidSpecifier;
    }
};

fn ttyForFormatMode(comptime mode: FormatMode, writer: anytype) ?std.io.tty.Config {
    return switch (mode) {
        .force_off => null,
        .force_esc => .escape_codes,
        .use_stdout => io.tty.detectConfig(io.getStdOut()),
        .use_stderr => io.tty.detectConfig(io.getStdErr()),
        .auto, .auto_or_esc => switch (@TypeOf(writer)) {
            File.Writer => io.tty.detectConfig(writer.context),
            else => |W| blk: {
                const info = @typeInfo(W);
                if (info == .pointer and
                    info.pointer.child == File.Writer and
                    (info.pointer.size == .One or info.pointer.size == .C))
                {
                    break :blk io.tty.detectConfig(writer.context);
                }
                break :blk switch (mode) {
                    .auto => null,
                    .auto_or_esc => .escape_codes,
                    else => unreachable,
                };
            },
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}

fn expectFmt(
    gpa: std.mem.Allocator,
    expected: []const u8,
    comptime spec: []const u8,
    trace: std.builtin.StackTrace,
) !void {
    const actual = try std.fmt.allocPrint(gpa, "{" ++ spec ++ "}", .{init(trace)});
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

noinline fn initDeepStackTrace(st: *std.builtin.StackTrace) void {
    const Trace = std.builtin.StackTrace;
    const S = struct {
        noinline fn a(s: *Trace) void {
            b(s);
        }
        noinline fn b(s: *Trace) void {
            c(s);
        }
        noinline fn c(s: *Trace) void {
            d(s);
        }
        noinline fn d(s: *Trace) void {
            e(s);
        }
        noinline fn e(s: *Trace) void {
            f(s);
        }
        noinline fn f(s: *Trace) void {
            std.debug.captureStackTrace(@returnAddress(), s);
        }
    };
    S.a(st);
}

test format {
    var addrs: [128]usize = undefined;
    var stack_trace: std.builtin.StackTrace = .{
        .index = 0,
        .instruction_addresses = &addrs,
    };

    initDeepStackTrace(&stack_trace);

    var arena_instance = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const expected_escaped = try std.fmt.allocPrint(arena, "{e}", .{
        init(stack_trace),
    });
    defer arena.free(expected_escaped);
    const expected = try std.fmt.allocPrint(arena, "{}", .{
        init(stack_trace),
    });
    defer arena.free(expected);

    const stdout_config = io.tty.detectConfig(io.getStdOut());
    const stderr_config = io.tty.detectConfig(io.getStdErr());
    const stdout_expected = switch (stdout_config) {
        .escape_codes => expected_escaped,
        else => expected,
    };

    const stderr_expected = switch (stderr_config) {
        .escape_codes => expected_escaped,
        else => expected,
    };

    try expectFmt(arena, expected_escaped, "e", stack_trace);
    try expectFmt(arena, expected, "", stack_trace);
    try expectFmt(arena, stdout_expected, "so", stack_trace);
    try expectFmt(arena, stderr_expected, "se", stack_trace);
    try expectFmt(arena, expected, "a", stack_trace);
    try expectFmt(arena, expected_escaped, "ae", stack_trace);
}

test "FormatMode.parse" {
    const expectEqual = std.testing.expectEqual;
    const parse = FormatMode.parse;
    try expectEqual(FormatMode.force_off, parse(""));
    try expectEqual(FormatMode.force_esc, parse("e"));
    try expectEqual(FormatMode.auto, parse("a"));
    try expectEqual(FormatMode.auto_or_esc, parse("ae"));
    try expectEqual(FormatMode.use_stdout, parse("so"));
    try expectEqual(FormatMode.use_stderr, parse("se"));
    try expectEqual(FormatMode.ParseError.InvalidSpecifier, parse(" "));
    try expectEqual(FormatMode.ParseError.InvalidSpecifier, parse("E"));
}

test ttyForFormatMode {
    const expectEqual = std.testing.expectEqual;
    // we really don't care that this is a directory
    const file = std.fs.File{ .handle = std.fs.cwd().fd };
    const config = io.tty.detectConfig(file);
    const stdout = io.getStdOut();
    const stdout_conf = io.tty.detectConfig(stdout);
    try expectEqual(config, ttyForFormatMode(.auto, file.writer()));
    try expectEqual(stdout_conf, ttyForFormatMode(.auto, stdout.writer()));
    try expectEqual(config, ttyForFormatMode(.auto, &file.writer()));
    try expectEqual(stdout_conf, ttyForFormatMode(.auto, &stdout.writer()));
    try expectEqual(null, ttyForFormatMode(.auto, io.null_writer));
    try expectEqual(io.tty.Config{ .escape_codes = {} }, ttyForFormatMode(.auto_or_esc, io.null_writer));
    const fp = &file;
    try expectEqual(null, ttyForFormatMode(.auto, &fp)); // Doesn't follow double pointers
}
