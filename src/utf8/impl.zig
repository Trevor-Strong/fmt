const std = @import("std");
const assert = std.debug.assert;

/// Returns the number of bytes required to encode `codepoint` in UTF-8.
pub fn encodedLen(codepoint: u21) error{CodepointTooLarge}!u3 {
    return switch (codepoint) {
        0x00...0x7F => 1,
        0x80...0x7FF => 2,
        0x800...0xFFFF => 3,
        0x10000...0x10FFFF => 4,
        0x110000...std.math.maxInt(u21) => error.CodepointTooLarge,
    };
}

pub const DecodeOptions = struct {
    /// Check that we don't decode a surrogate codepoint. When `false`, `decode`
    /// assumes that the input contains no surrogate codepoints
    check_surrogates: bool,
    /// Check that the codepoint is not overlong encoded. When `false`, `decode`
    /// assumes the input doesn't contain codepoints in overlong encodings.
    check_overlong: bool = true,

    pub const utf8: DecodeOptions = .{ .check_overlong = true, .check_surrogates = true };
    pub const wtf8: DecodeOptions = .{ .check_overlong = true, .check_surrogates = false };
};

/// Returns the number of bytes required to decode a codepoint with the given
/// leading byte.
pub fn decodeRequiredBytes(first: u8) !u3 {
    switch (first) {
        0x00...0x7F => return 1,
        0xC0...0xDF => return 2,
        0xE0...0xEF => return 3,
        0xF0...0xF7 => return 4,
        0x80...0xBF => return error.LeadingContinuation,
        0xF8...0xFF => return error.InvalidCodeunit,
    }
}

pub fn decodeExtra(bytes: []const u8, comptime options: DecodeOptions) !struct { u21, u3 } {
    assert(bytes.len != 0);
    const n = try decodeRequiredBytes(bytes[0]);
    switch (n) {
        1 => return .{ bytes[0], 1 },
        2 => if (bytes.len >= 2)
            return .{ try decode2Extra(bytes[0..2], options), 2 }
        else if (options.check_overlong and bytes[0] < 0xC2)
            return error.OverlongEncoding
        else
            return error.CodepointTruncated,
        3 => if (bytes.len >= 3) {
            return .{ try decode3Extra(bytes[0..3], options), 3 };
        } else {
            if (bytes.len >= 2) {
                const c = bytes[1];
                if (!isContinuation(c)) return error.ExpectedContinuation;
                if (options.check_overlong and bytes[0] == ByteKind.mask(.lead3) and c < 0b1010_0000) {
                    return error.OverlongEncoding;
                }
                if (options.check_surrogates and bytes[0] == 0b1110_1101 and c > 0b1001_1111) {
                    return error.SurrogateCodepoint;
                }
            }
            return error.CodepointTruncated;
        },
        4 => if (bytes.len >= 4) {
            return .{ try decode4Extra(bytes[0..4], options), 4 };
        } else {
            const c0 = bytes[0];
            if (c0 > 0b1111_0100) return error.CodepointTooLarge;
            if (bytes.len >= 2) {
                const c1 = bytes[1];
                if (!isContinuation(1)) return error.ExpectedContinuation;
                if (c0 == 0b1111_0100 and c1 > 0b1000_1111) {
                    return error.CodepointTooLarge;
                }
                if (options.check_overlong and c0 == ByteKind.mask(.lead4) and c1 > 0b1001_0000) {
                    return error.OverlongEncoding;
                }
            }
            return error.CodepointTruncated;
        },
        else => unreachable,
    }
}

pub fn decode2Extra(bytes: *const [2]u8, comptime options: DecodeOptions) !u21 {
    const c0 = bytes[0];
    assert(ByteKind.is(.lead2, c0));
    if (options.check_overlong) {
        if (c0 < 0b1100_0010) return error.OverlongEncoding;
    }

    if (bytes.len < 2) return error.CodepointTruncated;

    const c1 = bytes[1];
    if (!isContinuation(c1)) return error.ExpectedContinuation;
    var cp: u21 = @as(u5, @truncate(c0));
    cp <<= 6;
    cp |= @as(u6, @truncate(c1));
    return cp;
}

pub fn decode3Extra(bytes: *const [3]u8, comptime options: DecodeOptions) !u21 {
    const c0 = bytes[0];

    assert(ByteKind.is(.lead3, c0));

    const c1 = bytes[1];
    if (!isContinuation(c1)) return error.ExpectedContinuation;
    if (options.check_overlong) {
        if (c0 == 0xE0 and c1 < 0b1010_0000) return error.OverlongEncoding;
    }
    if (options.check_surrogates) {
        if (c0 == (0xE0 | 0b1101) and c1 >= 0b1010_0000) {
            return error.SurrogateCodepoint;
        }
    }

    const c2 = bytes[2];

    if (!isContinuation(c2)) return error.ExpectedContinuation;

    var cp: u21 = extractBits(.lead3, c0);
    cp <<= 6;
    cp |= extractBits(.continuation, c1);
    cp <<= 6;
    cp |= extractBits(.continuation, c2);
    return cp;
}

pub fn decode4Extra(bytes: *const [4]u8, comptime options: DecodeOptions) !u21 {
    const c0 = bytes[0];

    assert(ByteKind.is(.lead4, c0));

    if (c0 > 0b1111_0100) return error.CodepointTooLarge;

    const c1 = bytes[1];
    if (!isContinuation(c1)) return error.ExpectedContinuation;
    if (c0 == 0b1111_0100 and c1 > 0b1000_1111) {
        return error.CodepointTooLarge;
    } else if (options.check_overlong) {
        if (c0 == 0xf0 and c1 < 0b1001_0000) {
            return error.OverlongEncoding;
        }
    }

    const c2 = bytes[2];

    if (!isContinuation(c2)) return error.ExpectedContinuation;

    const c3 = bytes[3];

    if (!isContinuation(c3)) return error.ExpectedContinuation;

    var cp: u21 = extractBits(.lead4, c0);
    inline for ([_]u8{ c1, c2, c3 }) |c| {
        cp <<= 6;
        cp |= extractBits(.continuation, c);
    }
    return cp;
}

pub fn encode3(codepoint: u21) [3]u8 {
    assert(codepoint >= 0x800 and codepoint <= 0xFFFF);
    return .{
        @as(u4, @intCast(codepoint >> 12)) | ByteKind.mask(.lead3),
        @as(u6, @truncate(codepoint >> 6)) | ByteKind.mask(.continuation),
        @as(u6, @truncate(codepoint)) | ByteKind.mask(.continuation),
    };
}

inline fn isContinuation(c: u8) bool {
    return c & 0xC0 == 0x80;
}

pub const ByteKind = enum {
    continuation,
    lead2,
    lead3,
    lead4,

    inline fn is(kind: ByteKind, byte: u8) bool {
        const check_mask = switch (kind) {
            .continuation => 0xC0,
            .lead2 => 0xE0,
            .lead3 => 0xF0,
            .lead4 => 0xF8,
        };
        return (byte & check_mask) == mask(kind);
    }

    inline fn mask(kind: ByteKind) u8 {
        return switch (kind) {
            .lead2 => 0xc0,
            .lead3 => 0xe0,
            .lead4 => 0xf0,
            .continuation => 0x80,
        };
    }

    inline fn bits(kind: ByteKind) u3 {
        return @as(u3, 6) - @intFromEnum(kind);
    }
};

pub inline fn extractBits(comptime kind: ByteKind, byte: u8) std.meta.Int(.unsigned, kind.bits()) {
    return @truncate(byte);
}

/// Checks if `T` is a byte slice
fn isSliceOrArrayPtr(comptime T: type, comptime min_len: usize) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .Slice => info.child == u8,
            .One => switch (@typeInfo(info.child)) {
                .array => |array_info| array_info.child == u8 and array_info.len >= min_len,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}
