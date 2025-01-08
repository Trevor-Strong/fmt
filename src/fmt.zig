const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const extras = @import("extras.zig");
pub const Options = std.fmt.FormatOptions;
pub const Alignment = std.fmt.Alignment;
pub const Case = std.fmt.Case;
pub const Parser = @import("Parser.zig");
pub const Placeholder = @import("Placeholder.zig");

pub const default_alignment: Alignment = .right;
pub const default_fill_char = ' ';

pub const filter = @import("filter.zig");
pub const bind = extras.bind;
pub const BoundFormatter = extras.BoundFormatter;
pub const AnyFormatter = extras.AnyFormatter;

pub const AnyFormatFn = @TypeOf(struct {
    fn f(self: anytype, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        _ = self;
        _ = fmt;
        _ = options;
    }
}.f);

pub fn FormatFn(comptime T: type) type {
    return @TypeOf(struct {
        fn f(self: T, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
            _ = self;
            _ = fmt;
            _ = options;
        }
    }.f);
}

pub const @"struct" = extras.@"struct";

pub const optional = extras.optional;
pub const formatOptional = extras.formatOptional;

pub const StackTraceFormatter = @import("StackTraceFormatter.zig");

pub fn stackTrace(trace: anytype) switch (@TypeOf(trace)) {
    std.builtin.StackTrace,
    *std.builtin.StackTrace,
    *const std.builtin.StackTrace,
    => StackTraceFormatter,
    ?std.builtin.StackTrace,
    ?*std.builtin.StackTrace,
    ?*const std.builtin.StackTrace,
    => std.fmt.Formatter(formatOptional(?StackTraceFormatter)),
    else => unreachable,
} {
    if (@typeInfo(@TypeOf(trace)) == .optional) {
        return .{ .data = if (trace) |t| .{ .trace = t } else null };
    }
    if (@typeInfo(@TypeOf(trace)) == .pointer) {
        return .{ .trace = trace.* };
    }
}

pub const StructFormatter = extras.StructFormatter;
pub const StructFormatOptions = extras.StructFormatOptions;

test {
    std.testing.refAllDecls(@This());
}
