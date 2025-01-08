const std = @import("std");
const builtin = @import("builtin");
const fmt = @import("fmt.zig");

const assert = std.debug.assert;

pub fn optional(value: anytype) std.fmt.Formatter(formatOptional(@TypeOf(value))) {
    return .{ .data = value };
}

test optional {
    // const expectFmt = std.testing.expectFmt;

    // try expectFmt("", "{}", .{optional(null)});
    // try expectFmt("null", "{?}", .{optional(@as(?@TypeOf(null), @as(@TypeOf(null), null)))});
    // try expectFmt("32", "{}", .{optional(@as(?i32, 32))});
    // try expectFmt("", "{}", .{optional(@as(?i32, null))});
}

pub fn formatOptional(comptime T: type) fmt.FormatFn(T) {
    return struct {
        fn format(
            maybe_value: T,
            comptime spec: []const u8,
            options: fmt.Options,
            writer: anytype,
        ) !void {
            // if (T == @TypeOf(null)) return;
            const value = maybe_value orelse return;
            try std.fmt.formatType(
                value,
                spec,
                options,
                writer,
                std.options.fmt_max_depth,
            );
        }
    }.format;
}

pub fn bind(
    data: anytype,
    comptime spec: []const u8,
    comptime options: ?fmt.Options,
) BoundFormatter(@TypeOf(data), spec, options) {
    return .{ .data = data };
}

test bind {
    const expectFmt = std.testing.expectFmt;

    try expectFmt("0x00304056", "0x{}", .{
        bind(0x00304056, "x", .{ .fill = '0', .width = 8 }),
    });
}

pub fn BoundFormatter(comptime T: type, comptime bound_spec: []const u8, bind_options: ?fmt.Options) type {
    return struct {
        data: T,

        pub fn format(
            self: @This(),
            comptime spec: []const u8,
            options: fmt.Options,
            writer: anytype,
        ) !void {
            if (spec.len != 0) std.fmt.invalidFmtError(spec, self);

            try std.fmt.formatType(
                self.data,
                bound_spec,
                bind_options orelse options,
                writer,
                std.options.fmt_max_depth,
            );
        }
    };
}

pub const AnyFormatter = struct {
    ptr: ?*const anyopaque,
    formatFn: *const fn (ptr: ?*const anyopaque, options: fmt.Options, writer: std.io.AnyWriter) anyerror!void,

    pub fn format(
        self: AnyFormatter,
        comptime spec: []const u8,
        options: fmt.Options,
        writer: anytype,
    ) !void {
        if (spec.len != 0) std.fmt.invalidFmtError(spec, self);
        const Writer = @TypeOf(writer);
        const Error = @typeInfo(@TypeOf(writer.write("Hello"))).error_union.error_set;
        const any_writer: std.io.AnyWriter = any_writer: {
            if (Writer == std.io.AnyWriter) break :any_writer writer;
            const type_info = @typeInfo(Writer);
            if (type_info == .pointer and type_info.pointer.size == .One and type_info.child == std.io.AnyWriter)
                break :any_writer writer.*;
            break :any_writer writer.any();
        };

        return try @as(Error!void, self.formatFn(self.ptr, options, any_writer));
    }
};

pub fn @"struct"(
    value: anytype,
    comptime options: StructFormatOptions(@TypeOf(value)),
) StructFormatter(@TypeOf(value), options) {
    return .{ .data = value };
}

pub fn StructFormatOptions(comptime T: type) type {
    return struct {
        pub const Format = FormatSpec;
        const Field = std.meta.FieldEnum(T);
        prefix: []const u8 = ".{ ",
        suffix: []const u8 = " }",
        field: struct {
            /// The format to use for each field or `null` to omit the field.
            fmt: std.enums.EnumFieldStruct(Field, ?Format, .{ .spec = "any" }) = .{},

            prefix: []const u8 = "",
            suffix: []const u8 = ", ",
            skip_last_suffix: bool = true,
            name: ?struct {
                prefix: []const u8 = ".",
                suffix: []const u8 = " = ",
                fmt: enum { identifier, string } = .identifier,
            } = .{},
        } = .{},
    };
}

const FormatSpec = struct {
    spec: []const u8,
    options: fmt.Options = .{},
};

pub fn StructFormatter(
    comptime T: type,
    comptime options: StructFormatOptions(T),
) type {
    return struct {
        data: T,

        const FieldEnum = std.meta.FieldEnum;

        const fields: []const std.builtin.Type.StructField = @typeInfo(T).@"struct".fields;

        pub fn format(
            self: @This(),
            comptime spec: []const u8,
            fmt_options: fmt.Options,
            writer: anytype,
        ) !void {
            _ = fmt_options;
            if (spec.len != 0) std.fmt.invalidFmtError(spec, self);

            if (comptime options.prefix.len > 0) {
                try writer.writeAll(options.prefix);
            }

            const field_opts = options.field;

            @setEvalBranchQuota(@intCast(fields.len * 3 + 2));

            inline for (fields, 0..) |f, i| {
                const field: FormatSpec = comptime @field(field_opts.fmt, f.name) orelse continue;
                try writer.writeAll(options.field.prefix);
                if (field_opts.name) |name| {
                    if (name.prefix.len > 0) {
                        try writer.writeAll(name.prefix);
                    }
                    switch (name.fmt) {
                        .string => try writer.writeAll(f.name),
                        .identifier => try std.zig.fmtId(f.name).format("", field.options, writer),
                    }
                    if (comptime name.suffix.len > 0)
                        try writer.writeAll(name.suffix);
                }
                try std.fmt.formatType(
                    @field(self.data, f.name),
                    field.spec,
                    field.options,
                    writer,
                    std.options.fmt_max_depth,
                );

                if (comptime field_opts.suffix.len > 0 and (i < fields.len - 1 or !field_opts.skip_last_suffix)) {
                    try writer.writeAll(field_opts.suffix);
                }
            }

            if (options.suffix.len > 0) {
                try writer.writeAll(options.suffix);
            }
        }
    };
}

test @"struct" {
    const t = std.testing;

    try t.expectFmt(
        \\.{ .a = 64, .b = 1f, .c = hello, .@"complex-field" = null }
    ,
        "{}",
        .{
            @"struct"(.{
                .a = 64,
                .b = 0x1f,
                .c = "hello",
                .@"complex-field" = null,
            }, .{
                .field = .{
                    .fmt = .{ .b = .{ .spec = "x" }, .c = .{ .spec = "s" } },
                },
            }),
        },
    );

    try t.expectFmt(
        "[PREFIX][FIELD_PREFIX][NAME_PREFIX]my-field1[NAME_SUFFIX]beef[FIELD_SUFFIX]" ++
            "[FIELD_PREFIX][NAME_PREFIX]my-field2[NAME_SUFFIX]EAT[FIELD_SUFFIX][SUFFIX]",
        "{}",
        .{
            @"struct"(.{ .@"my-field1" = 0xbeef, .@"my-field2" = 0xEA }, .{
                .prefix = "[PREFIX]",
                .suffix = "[SUFFIX]",
                .field = .{
                    .prefix = "[FIELD_PREFIX]",
                    .suffix = "[FIELD_SUFFIX]",
                    .skip_last_suffix = false,
                    .name = .{
                        .fmt = .string,
                        .prefix = "[NAME_PREFIX]",
                        .suffix = "[NAME_SUFFIX]",
                    },
                    .fmt = .{
                        .@"my-field1" = .{ .spec = "x" },
                        .@"my-field2" = .{
                            .spec = "X",
                            .options = .{
                                .width = 3,
                                .fill = 'T',
                                .alignment = .left,
                            },
                        },
                    },
                },
            }),
        },
    );
}

test {
    std.testing.refAllDecls(@This());
}
