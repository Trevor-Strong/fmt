//! Iterator parsing a format template string into tokens.
const std = @import("std");
const builtin = @import("builtin");
const fmt = @import("fmt.zig");
const utf8 = @import("utf8.zig");

const assert = std.debug.assert;

const Parser = @This();

/// The format string being parsed
str: []const u8,
/// Current position of the parser
pos: usize,

/// Checks if the given string is a valid format string.
pub fn validate(str: []const u8) Error!void {
    var parser = Parser.init(str);
    while (try parser.next()) |_| {}
}

/// Create a parser for the given format string
pub fn init(str: []const u8) Parser {
    return .{ .str = str, .pos = 0 };
}

/// Reset the parser to the beginning of the string
pub fn reset(parser: *Parser) void {
    parser.pos = 0;
}

/// Returns the remainder of the string that is currently un parsed
pub fn unparsed(parser: *const Parser) []const u8 {
    return parser.str[parser.pos..];
}

/// Parsing error. Occurs when the string being parsed is invalid.
pub const Error = error{
    /// A '{' was found that was not escaped and didn't have a '}' after it in
    /// the string or a '}' was found that was not escaped and wasn't paired
    /// with an initial '{'.
    UnmatchedBrace,
} || fmt.Placeholder.ParseError;

/// Returns `true` if `next()` would return `null` the next time it's called
pub fn isDone(parser: *const Parser) bool {
    return parser.pos == parser.str.len;
}

/// Parses and returns the next token from the format string
pub fn next(parser: *Parser) Error!?Token {
    const str = parser.str;
    const pos = parser.pos;
    if (pos == str.len) return null;
    switch (str[pos]) {
        '{', '}' => |c| {
            const next_i = pos + 1;
            if (next_i == str.len) {
                return error.UnmatchedBrace;
            }
            if (c == str[next_i]) {
                parser.pos = next_i + 1;
                return .{ .escaped = c };
            }
            if (c == '}') {
                return error.UnmatchedBrace;
            }
            assert(c == '{');
            const start = pos + 1;
            assert(start < str.len);
            const end = indexOfCharPos(str, pos, '}') orelse return error.UnmatchedBrace;
            parser.pos = end + 1;
            return .{ .placeholder = try fmt.Placeholder.parse(str[start..end]) };
        },
        else => {
            const start = pos;
            const end = std.mem.indexOfAnyPos(u8, str, pos, "{}") orelse str.len;
            parser.pos = end;
            return .{ .text = str[start..end] };
        },
    }
    var end = pos;
    while (str[end] != '{' and str[end] != '}') {
        end += 1;
        if (end == str.len) break;
    }
    parser.pos = end;
    return str[pos..end];
}

pub fn nextAssumeValid(parser: *Parser) ?Token {
    return parser.next() catch |err| {
        const format_line_1 = ": Unexpected invalid format string: \"";
        const err_name = @errorName(err);
        const pad = pad: {
            var amt: usize = err_name.len + "error.".len;
            amt += format_line_1.len;
            amt += @intCast(std.fmt.count("{}", .{std.zig.fmtEscapes(parser.str[0..parser.pos])}));
            break :pad amt;
        };
        std.debug.panic("error.{[err]s}" ++ format_line_1 ++ "{[str]}\"\n{[pt]c:[pad]}", .{
            .err = err_name,
            .str = std.zig.fmtEscapes(parser.str),
            .pad = pad,
            .pt = '^',
        });
    };
}

/// Peek at the kind of the next token without checking for validity. If all
/// tokens have already been parsed, returns `null`.
///
/// This function does not ensure that the next token is valid, so calling
/// `next()` may return an error. If `next()` does not return an error, then the
/// next token will be of the kind indicated by this function
pub fn peekKind(parser: *const Parser) ?Token.Kind {
    const pos = parser.pos;
    const str = parser.str;
    if (str.len == pos) return null;
    switch (str[pos]) {
        '}' => return .escaped,
        '{' => if (str.len != pos + 1) {
            return if (str[pos + 1] == '{')
                .escaped
            else
                .placeholder;
        } else return .placeholder,
        else => return .text,
    }
}

/// Tokens in a format template string.
pub const Token = union(enum) {
    /// A sequence of raw text
    text: []const u8,
    /// An escaped character
    escaped: u8,
    /// A placeholder token
    placeholder: fmt.Placeholder,

    pub const Kind = @typeInfo(Token).@"union".tag_type.?;

    pub inline fn kind(token: Token) Kind {
        return token;
    }

    pub fn format(
        token: Token,
        comptime spec: []const u8,
        options: fmt.Options,
        writer: anytype,
    ) !void {
        _ = options;
        if (spec.len == 0) {
            try writer.writeAll("fmt.Parser.Token{ .");
            switch (token) {
                .text => |s| try writer.print("text = \"{}\" }}", .{
                    std.zig.fmtEscapes(s),
                }),
                .escaped => |c| try writer.print("escaped = '{'}' }}", .{
                    std.zig.fmtEscapes(&.{c}),
                }),
                .placeholder => |placeholder| try writer.print(
                    "placeholder = \"{{{}}}\" }}",
                    .{std.zig.fmtEscapes(placeholder.raw)},
                ),
            }
        } else if (comptime std.mem.eql(u8, spec, "raw")) {
            switch (token) {
                .text => |s| try writer.writeAll(s),
                .escaped => |c| try writer.writeAll(&.{ c, c }),
                .placeholder => |placeholder| try writer.print("{{{s}}}", .{placeholder.raw}),
            }
        }
    }

    test "format({})" {
        try t.expectFmt("fmt.Parser.Token{ .text = \"Hello There\" }", "{}", .{Token{ .text = "Hello There" }});
        try t.expectFmt("fmt.Parser.Token{ .escaped = '{' }", "{}", .{Token{ .escaped = '{' }});
        try t.expectFmt("fmt.Parser.Token{ .placeholder = \"{[arg]spec}\" }", "{}", .{
            Token{ .placeholder = fmt.Placeholder.parse("[arg]spec") catch unreachable },
        });
    }

    test "format({raw})" {
        try t.expectFmt("Hello There", "{raw}", .{Token{ .text = "Hello There" }});
        try t.expectFmt("{{", "{raw}", .{Token{ .escaped = '{' }});
        try t.expectFmt("{[arg]spec}", "{raw}", .{
            Token{ .placeholder = fmt.Placeholder.parse("[arg]spec") catch unreachable },
        });
    }
};

fn indexOfCharPos(slice: []const u8, start_index: usize, ch: u8) ?usize {
    return std.mem.indexOfScalarPos(u8, slice, start_index, ch);
}

const t = std.testing;

test {
    t.refAllDecls(@This());
    t.refAllDecls(Token);
}

fn testParser(format: []const u8, expected: []const Error!Token) !void {
    const last_index = expected.len -| 1;
    for (expected[0..last_index]) |x| {
        if (std.meta.isError(x)) @panic("Invalid expected parser tokens");
    }
    var parser = Parser.init(format);
    var tokens = try t.allocator.alloc(Error!Token, expected.len);
    defer t.allocator.free(tokens);
    for (tokens[0..last_index]) |*token| {
        token.* = parser.next() catch unreachable orelse unreachable;
    }
    if (tokens.len > 0)
        tokens[last_index] = if (parser.next()) |token| token.? else |err| err;
    try t.expectEqual(null, parser.next());
    try t.expectEqualDeep(expected, tokens);
}

test "basic" {
    try testParser("text only", &.{.{ .text = "text only" }});
    try testParser("first {format} second", &.{
        .{ .text = "first " },
        .{ .placeholder = .{ .raw = "format", .spec = "format" } },
        .{ .text = " second" },
    });

    try testParser("first {#1} second {#2}", &.{
        .{ .text = "first " },
        .{ .placeholder = .{ .raw = "#1", .spec = "#1" } },
        .{ .text = " second " },
        .{ .placeholder = .{ .raw = "#2", .spec = "#2" } },
    });
}

test "named options" {
    const template = "{s:~^[1]}";
    try testParser(template, &.{
        .{
            .placeholder = .{
                .raw = template[1 .. template.len - 1],
                .arg = .anonymous,
                .spec = template[1..2],
                .options = .{
                    .fill = '~',
                    .alignment = .center,
                    .min_width = .{ .arg = "1" },
                },
            },
        },
    });
}
