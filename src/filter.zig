const std = @import("std");
const fmt = @import("fmt.zig");
const assert = std.debug.assert;

pub fn Used(comptime template: []const u8, comptime Args: type) type {
    const args_info: std.builtin.Type.Struct = switch (@typeInfo(Args)) {
        .@"struct" => |struct_info| struct_info,
        else => @compileError("expected tuple or struct argument, found " ++ @typeName(Args)),
    };
    const fields = args_info.fields;
    const fieldIndex = struct {
        fn f(comptime name: []const u8) ?usize {
            for (fields, 0..) |field, i| {
                if (std.mem.eql(u8, field.name, name)) return i;
            }
            return null;
        }
    }.f;

    @setEvalBranchQuota(2_000_000);
    const ArgField = std.meta.FieldEnum(Args);
    var parser = fmt.Parser.init(template);
    var next_anon_arg: usize = 0;
    var used_args = std.EnumSet(ArgField).initEmpty();
    var filtered_fields = std.BoundedArray(std.builtin.Type.StructField, fields.len - 1){};

    while (parser.next() catch unreachable) |token| switch (token) {
        .text, .escaped => {},
        .placeholder => |placeholder| {
            const index = switch (placeholder.arg) {
                .anonymous => index: {
                    const i = next_anon_arg;
                    next_anon_arg += 1;
                    break :index i;
                },
                .number => |i| i,
                .string => |name| fieldIndex(name) orelse unreachable,
            };
            const key: ArgField = @enumFromInt(index);
            if (used_args.contains(key)) continue;
            used_args.insert(key);
            filtered_fields.append(fields[index]) catch return Args;
            if (placeholder.options) |options| {
                switch (options.min_width) {
                    .arg => |name| {
                        const i = fieldIndex(name) orelse unreachable;
                        if (!used_args.contains(@enumFromInt(i))) {
                            used_args.insert(@enumFromInt(i));
                            filtered_fields.append(fields[i]) catch return Args;
                        }
                    },
                    .none, .literal => {},
                }
                switch (options.precision) {
                    .arg => |name| {
                        const i = fieldIndex(name) orelse unreachable;
                        if (!used_args.contains(@enumFromInt(i))) {
                            used_args.insert(@enumFromInt(i));
                            filtered_fields.append(fields[i]) catch return Args;
                        }
                    },
                    .none, .literal => {},
                }
            }
        },
    };

    const filtered = filtered_fields.buffer[0..filtered_fields.len].*;

    return @Type(.{
        .@"struct" = .{
            .fields = &filtered,
            .layout = .auto,
            .decls = &.{},
            .backing_integer = null,
            .is_tuple = false,
        },
    });
}

pub inline fn used(comptime template: []const u8, args: anytype) Used(template, @TypeOf(args)) {
    const Out = Used(template, @TypeOf(args));
    if (@TypeOf(args) == Out) return args; // no filtering needed
    var out: Out = undefined;
    const fields = @typeInfo(Out).@"struct".fields;

    inline for (fields) |f| {
        @field(out, f.name) = @field(args, f.name);
    }

    return out;
}

test {
    std.testing.refAllDecls(@This());
}

inline fn testUsed(expected: []const u8, comptime template: []const u8, args: anytype) anyerror!void {
    try std.testing.expectFmt(expected, template, used(template, args));
}

test "partial" {
    try testUsed("1 2 3", "{d} {d} {d}", .{ 1, 2, 3, 4, 5 });
    try testUsed("1 2 3", "{d:} {d} {d}", .{ 1, 2, 3, 4, 5 });
    try testUsed("1 2 3", "{[a]:} {[b]} {[c]}", .{ .a = 1, .b = 2, .c = 3, .d = 4, .xyz = 5 });
}

test "positional" {
    try testUsed("2 1 0", "{2} {1} {0}", .{ @as(usize, 0), @as(usize, 1), @as(usize, 2) });
    try testUsed("2 1 0", "{2} {1} {}", .{ @as(usize, 0), @as(usize, 1), @as(usize, 2) });
    try testUsed("0 0", "{0} {0}", .{@as(usize, 0)});
    try testUsed("0 1", "{} {1}", .{ @as(usize, 0), @as(usize, 1) });
    try testUsed("1 0 0 1", "{1} {} {0} {}", .{ @as(usize, 0), @as(usize, 1) });
}

test "positional with specifier" {
    try testUsed("10.0", "{0d:.1}", .{@as(f64, 9.999)});
}

test "positional/alignment/width/precision" {
    try testUsed("10.0", "{0d: >3.1}", .{@as(f64, 9.999)});
}

test "padding" {
    try testUsed("Simple", "{s}", .{"Simple"});
    try testUsed("      true", "{:10}", .{true});
    try testUsed("      true", "{:>10}", .{true});
    try testUsed("======true", "{:=>10}", .{true});
    try testUsed("true======", "{:=<10}", .{true});
    try testUsed("   true   ", "{:^10}", .{true});
    try testUsed("===true===", "{:=^10}", .{true});
    try testUsed("           Minimum width", "{s:18} width", .{"Minimum"});
    try testUsed("==================Filled", "{s:=>24}", .{"Filled"});
    try testUsed("        Centered        ", "{s:^24}", .{"Centered"});
    try testUsed("-", "{s:-^1}", .{""});
    try testUsed("==crêpe===", "{s:=^10}", .{"crêpe"});
    try testUsed("=====crêpe", "{s:=>10}", .{"crêpe"});
    try testUsed("crêpe=====", "{s:=<10}", .{"crêpe"});
    try testUsed("====a", "{c:=>5}", .{'a'});
    try testUsed("==a==", "{c:=^5}", .{'a'});
    try testUsed("a====", "{c:=<5}", .{'a'});
}

test "padding fill char utf" {
    try testUsed("──crêpe───", "{s:─^10}", .{"crêpe"});
    try testUsed("─────crêpe", "{s:─>10}", .{"crêpe"});
    try testUsed("crêpe─────", "{s:─<10}", .{"crêpe"});
    try testUsed("────a", "{c:─>5}", .{'a'});
    try testUsed("──a──", "{c:─^5}", .{'a'});
    try testUsed("a────", "{c:─<5}", .{'a'});
}

test "decimal float padding" {
    const number: f32 = 3.1415;
    try testUsed("left-pad:   **3.142\n", "left-pad:   {d:*>7.3}\n", .{number});
    try testUsed("center-pad: *3.142*\n", "center-pad: {d:*^7.3}\n", .{number});
    try testUsed("right-pad:  3.142**\n", "right-pad:  {d:*<7.3}\n", .{number});
}

test "sci float padding" {
    const number: f32 = 3.1415;
    try testUsed("left-pad:   ****3.142e0\n", "left-pad:   {e:*>11.3}\n", .{number});
    try testUsed("center-pad: **3.142e0**\n", "center-pad: {e:*^11.3}\n", .{number});
    try testUsed("right-pad:  3.142e0****\n", "right-pad:  {e:*<11.3}\n", .{number});
}

test "padding.zero" {
    try testUsed("zero-pad: '0042'", "zero-pad: '{:04}'", .{42});
    try testUsed("std-pad: '        42'", "std-pad: '{:10}'", .{42});
    try testUsed("std-pad-1: '001'", "std-pad-1: '{:0>3}'", .{1});
    try testUsed("std-pad-2: '911'", "std-pad-2: '{:1<03}'", .{9});
    try testUsed("std-pad-3: '  1'", "std-pad-3: '{:>03}'", .{1});
    try testUsed("center-pad: '515'", "center-pad: '{:5^03}'", .{1});
}

test "named arguments" {
    try testUsed("hello world!", "{s} world{c}", .{ "hello", '!' });
    try testUsed("hello world!", "{[greeting]s} world{[punctuation]c}", .{ .punctuation = '!', .greeting = "hello" });
    try testUsed("hello world!", "{[1]s} world{[0]c}", .{ '!', "hello" });
}

test "runtime width specifier" {
    const width: usize = 9;
    try testUsed("~~hello~~", "{s:~^[1]}", .{ "hello", width });
    try testUsed("~~hello~~", "{s:~^[width]}", .{ .string = "hello", .width = width });
    try testUsed("    hello", "{s:[1]}", .{ "hello", width });
    try testUsed("42     hello", "{d} {s:[2]}", .{ 42, "hello", width });
}

test "runtime precision specifier" {
    const number: f32 = 3.1415;
    const precision: usize = 2;
    try testUsed("3.14e0", "{:1.[1]}", .{ number, precision });
    try testUsed("3.14e0", "{:1.[precision]}", .{ .number = number, .precision = precision });
}

test "recursive format function" {
    const R = union(enum) {
        const R = @This();
        Leaf: i32,
        Branch: struct { left: *const R, right: *const R },

        pub fn format(self: R, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            return switch (self) {
                .Leaf => |n| std.fmt.format(writer, "Leaf({})", .{n}),
                .Branch => |b| std.fmt.format(writer, "Branch({}, {})", .{ b.left, b.right }),
            };
        }
    };

    var r = R{ .Leaf = 1 };
    try testUsed("Leaf(1)\n", "{}\n", .{&r});
}
