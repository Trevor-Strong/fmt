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
pub const default_fill = ' ';

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
pub const Optional = extras.Optional;

pub const StackTraceFormatter = @import("StackTraceFormatter.zig");

fn StackTrace(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => StackTraceFormatter,
        .optional => Optional(StackTraceFormatter),
        else => StackTraceFormatter,
    };
}

pub fn stackTrace(trace: anytype) StackTrace(@TypeOf(trace)) {
    const T = @TypeOf(trace);
    if (@typeInfo(T) == .optional) {
        if (@typeInfo(T).optional.child == std.builtin.StackTrace) {
            return .{ .data = if (trace) |t| .{ .trace = t } else null };
        } else {
            return .{ .data = if (trace) |t| .{ .trace = t.* } else null };
        }
    } else if (@typeInfo(@TypeOf(trace)) == .pointer) {
        return .{ .trace = trace.* };
    } else {
        comptime assert(T == std.builtin.StackTrace);
        return .{ .trace = trace };
    }
}

pub const StructFormatter = extras.StructFormatter;
pub const StructFormatOptions = extras.StructFormatOptions;

test {
    std.testing.refAllDecls(@This());
}
