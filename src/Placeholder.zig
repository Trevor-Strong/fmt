//! Token in a template string that is replaced with a format argument
const std = @import("std");
const fmt = @import("fmt.zig");
const utf8 = @import("utf8.zig");

const assert = std.debug.assert;

const Placeholder = @This();

/// The raw text of the placeholder
raw: []const u8,
/// Name of the argument that fills in this placeholder. If `anonymous` the
/// argument is implied by the parser context
arg: Name = .anonymous,
/// The format specifier. This points to a substring of `raw`.
spec: []const u8,
/// Standard format options to apply to the placeholder
options: ?Options = null,

pub fn rawArg(self: Placeholder) []const u8 {
    const len = self.spec.ptr - self.raw.ptr;
    return self.raw[0..len];
}

pub fn rawOptions(self: Placeholder) ?[]const u8 {
    if (self.options == null) return null;
    const spec_offset = self.spec.ptr - self.raw.ptr;
    const delim = spec_offset + self.spec.len;
    assert(self.raw[delim] == ':');
    return self.raw[delim + 1 ..];
}

pub const ParseError = error{
    InvalidUtf8,
    InvalidOptions,
    InvalidArgument,
};

pub fn parse(s: []const u8) ParseError!Placeholder {
    if (s.len == 0) {
        return .{ .raw = s, .spec = s };
    }
    var self: Placeholder = .{ .raw = s, .spec = undefined };
    var i: usize = undefined;
    if (s[0] == '[') {
        const end = indexOfCharPos(s, 1, ']') orelse return error.InvalidArgument;
        self.arg = .{ .string = s[1..end] };
        i = end + 1;
    } else if (std.ascii.isDigit(s[0])) {
        self.arg = .{ .number = s[0] - '0' };
        i = 1;
    } else {
        i = 0;
    }

    const spec_end = indexOfCharPos(s, i, ':') orelse s.len;
    self.spec = s[i..spec_end];
    if (spec_end != s.len) {
        self.options = try Options.parse(s[spec_end + 1 ..]);
    }
    return self;
}

/// Options section of the placeholder
pub const Options = struct {
    /// Alignment option specified in the placeholder
    alignment: ?fmt.Alignment = null,
    /// Fill character
    fill: ?u21 = null,
    /// Minimum width
    min_width: Size = .none,
    /// Precision of the formatted value
    precision: Size = .none,

    /// Describes the `min_width` and `precision` option values
    pub const Size = union(enum) {
        /// No value for the option was provided
        none,
        /// Name of the argument that contains the value of the option
        arg: []const u8,
        /// Literal value encoded in the text of the template string
        literal: usize,

        pub fn format(
            self: @This(),
            comptime spec: []const u8,
            options: fmt.Options,
            writer: anytype,
        ) !void {
            if (spec.len != 0) std.fmt.invalidFmtError(spec, self);
            switch (self) {
                .none => try std.fmt.formatBuf(".none", options, writer),
                .arg => |arg| {
                    try writer.writeAll(".{ .arg = ");
                    try std.zig.fmtEscapes(arg).format("", options, writer);
                    try writer.writeAll(" }");
                },
                .literal => |literal| {
                    try writer.writeAll(".{ .literal = ");
                    try std.fmt.formatInt(literal, 10, .lower, options, writer);
                    try writer.writeAll(" }");
                },
            }
        }
    };

    pub const ParseError = error{
        InvalidOptions,
        InvalidUtf8,
    };

    pub fn format(
        self: Options,
        comptime spec: []const u8,
        options: fmt.Options,
        writer: anytype,
    ) !void {
        _ = options;
        if (spec.len != 0) std.fmt.invalidFmtError(spec, self);
        try writer.print(".{{ .alignment = {?s}, .fill = {?u}, .min_width = {}, .precision = {} }}", .{
            if (self.alignment) |a| @tagName(a) else null,
            self.fill,
            self.min_width,
            self.precision,
        });
    }

    pub fn parse(s: []const u8) Options.ParseError!Options {
        if (s.len == 0) return .{};
        var options: Options = .{
            .fill = undefined,
            .alignment = undefined,
        };
        var i: usize = 0;
        errdefer if (@import("builtin").is_test) {
            if (@inComptime()) {
                const x = s[0..].*;
                @compileLog(s, x, i, options);
            } else {
                std.debug.print("\n\"{}\", {d}, {}\n", .{
                    std.zig.fmtEscapes(s),
                    i,
                    options,
                });
            }
        };
        const first_fill, i = utf8.decode(s) catch return error.InvalidUtf8;
        const first_alignment = parseAlignment(s[0]);
        if (i < s.len) {
            if (parseAlignment(s[i])) |alignment| {
                options.alignment = alignment;
                options.fill = first_fill;
                i += 1;
            } else {
                options.fill = null;
                options.alignment = first_alignment;
                i = @intFromBool(first_alignment != null);
            }
            assert(s.len >= i);
        } else {
            if (!std.ascii.isAscii(std.math.lossyCast(u8, first_fill))) return error.InvalidOptions;
            options.fill = null;
            options.alignment = first_alignment;
            i = @intFromBool(first_alignment != null);
        }

        if (s.len == i) return options;

        if (std.ascii.isDigit(s[i])) {
            if (options.fill == null and s[0] == '0') {
                options.fill = '0';
            }
            const start = i;
            const end = while (true) {
                i += 1;
                if (s.len == i) break i;
                switch (s[i]) {
                    '.' => break i,
                    '0'...'9' => {},
                    else => return error.InvalidOptions,
                }
            };
            options.min_width = .{
                .literal = std.fmt.parseInt(usize, s[start..end], 10) catch |err| switch (err) {
                    error.InvalidCharacter => unreachable,
                    error.Overflow => return error.InvalidOptions,
                },
            };
        } else if (s[i] == '[') {
            const start = i + 1;
            const end = indexOfCharPos(s, start, ']') orelse return error.InvalidOptions;
            options.min_width = .{ .arg = s[start..end] };
            i = end + 1;
        }

        if (s.len == i) return options;
        if (s[i] != '.') return error.InvalidOptions;
        i += 1;
        if (s.len == i) return options;
        if (s[i] == '[') {
            const start = i + 1;
            const end = indexOfCharPos(s, i, ']') orelse return error.InvalidOptions;
            options.precision = .{ .arg = s[start..end] };
            i = end + 1;
        } else {
            const start = i;
            const end: usize = while (std.ascii.isDigit(s[i])) {
                i += 1;
                if (s.len == i) break i;
            } else return error.InvalidOptions; // extra trailing characters
            options.precision = .{
                .literal = std.fmt.parseUnsigned(
                    usize,
                    s[start..end],
                    10,
                ) catch |err| switch (err) {
                    error.InvalidCharacter => unreachable,
                    error.Overflow => return error.InvalidOptions,
                },
            };
        }
        return options;
    }

    fn parseAlignment(ch: u8) ?fmt.Alignment {
        return switch (ch) {
            '<' => .left,
            '>' => .right,
            '^' => .center,
            else => null,
        };
    }

    test parseAlignment {
        const expectEql = std.testing.expectEqual;

        try expectEql(.left, parseAlignment('<'));
        try expectEql(.right, parseAlignment('>'));
        try expectEql(.center, parseAlignment('^'));
        try expectEql(null, parseAlignment('8'));
        try expectEql(null, parseAlignment(0x84));
    }
};

pub const Name = union(enum) {
    /// No name given
    anonymous,
    /// Numeric name when the context requires the name be a number
    number: usize,
    /// String name
    string: []const u8,
};
fn indexOfCharPos(s: []const u8, start: usize, ch: u8) ?usize {
    return std.mem.indexOfScalarPos(u8, s, start, ch);
}

const t = std.testing;

fn testParse(placeholder_string: []const u8, expected: Placeholder) !void {
    const actual: Placeholder = try .parse(placeholder_string);
    try t.expectEqualDeep(expected, actual);
}

test parse {
    try testParse("", .{
        .raw = "",
        .arg = .anonymous,
        .spec = "",
        .options = null,
    });
    try testParse(":", .{
        .raw = ":",
        .arg = .anonymous,
        .spec = "",
        .options = .{},
    });
    try testParse("0", .{
        .raw = "0",
        .arg = .{ .number = 0 },
        .spec = "",
        .options = null,
    });
    try testParse("something:", .{
        .raw = "something:",
        .arg = .anonymous,
        .spec = "something",
        .options = .{},
    });
    try testParse("9something:", .{
        .raw = "9something:",
        .arg = .{ .number = 9 },
        .spec = "something",
        .options = .{},
    });
    try testParse("34something", .{
        .raw = "34something",
        .arg = .{ .number = 3 },
        .spec = "4something",
        .options = null,
    });
    try testParse("[argname]", .{
        .raw = "[argname]",
        .arg = .{ .string = "argname" },
        .spec = "",
        .options = null,
    });
    try testParse("[argname]spec", .{
        .raw = "[argname]spec",
        .arg = .{ .string = "argname" },
        .spec = "spec",
        .options = null,
    });
    try testParse("[argname]spec:<", .{
        .raw = "[argname]spec:<",
        .arg = .{ .string = "argname" },
        .spec = "spec",
        .options = .{ .alignment = .left },
    });
    try testParse(":-^15.32", .{
        .raw = ":-^15.32",
        .spec = "",
        .options = .{
            .fill = '-',
            .alignment = .center,
            .min_width = .{ .literal = 15 },
            .precision = .{ .literal = 32 },
        },
    });
    try testParse("[argname]spec:-^15.32", .{
        .raw = "[argname]spec:-^15.32",
        .arg = .{ .string = "argname" },
        .spec = "spec",
        .options = .{
            .fill = '-',
            .alignment = .center,
            .min_width = .{ .literal = 15 },
            .precision = .{ .literal = 32 },
        },
    });
}

fn testParseOptions(placeholder_string: []const u8, expected: Options.ParseError!Options) !void {
    const actual = Options.parse(placeholder_string);
    try t.expectEqualDeep(expected, actual);
}
const parseOptions = Options.parse;

test parseOptions {
    try testParseOptions("", .{});
    try testParseOptions("0", .{ .fill = '0', .min_width = .{ .literal = 0 } });
    //  try testParseOptions("<", .{ .alignment = .left });
    try testParseOptions("0>", .{ .alignment = .right, .fill = '0' });
    try testParseOptions("0>1", .{ .alignment = .right, .fill = '0', .min_width = .{ .literal = 1 } });
    try testParseOptions("\u{1024}>.1", .{ .alignment = .right, .fill = '\u{1024}', .precision = .{ .literal = 1 } });
    try testParseOptions("0>34.12", .{
        .alignment = .right,
        .fill = '0',
        .min_width = .{
            .literal = 34,
        },
        .precision = .{ .literal = 12 },
    });
}
