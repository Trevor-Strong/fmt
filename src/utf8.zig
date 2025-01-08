const std = @import("std");
const assert = std.debug.assert;
const impl = @import("utf8/impl.zig");

pub const decodeRequiredBytes = impl.decodeRequiredBytes;

pub const DecodeError = Decode2Error || Decode3Error || Decode4Error || error{
    /// Input did not contain enough bytes for the next codepoint to be decoded.
    CodepointTruncated,
    /// First byte in `bytes` was a continuation.
    LeadingContinuation,
    /// First byte in `bytes` is an illegal UTF-8 codeunit.
    InvalidCodeunit,
};

pub fn decode(bytes: []const u8) DecodeError!struct { u21, u3 } {
    return try impl.decodeExtra(bytes, .utf8);
}

pub const Decode2Error = error{
    /// Found a non-continuation byte where one was expected
    ExpectedContinuation,
    /// The encoded value could have been encoded in fewer bytes
    OverlongEncoding,
};

/// Decodes first codepoint in the byte slice or array pointer `bytes`,
/// asserting that the first codepoint in `bytes` is encoded in 2 bytes
pub fn decode2(bytes: anytype) Decode2Error!u21 {
    return try impl.decode2Extra(bytes, .utf8);
}

pub const Decode3Error = Decode2Error || error{
    /// The first codepoint encoded in `bytes` is a surrogate codepoint.
    /// (Encodes a value in the range [0xD800, 0xDFFF])
    SurrogateCodepoint,
};

pub fn decode3(bytes: anytype) Decode3Error!u21 {
    return try impl.decode3Extra(bytes, .utf8);
}

pub const Decode4Error = Decode2Error || error{
    /// The first codepoint encoded in `bytes` is larger than the maximum
    /// codepoint value (`0x10FFFF`).
    CodepointTooLarge,
};
pub fn decode4(bytes: anytype) Decode4Error!u21 {
    return try impl.decode4Extra(bytes, .utf8);
}

/// Returns the number of bytes required to encode `codepoint` in UTF-8.
///
/// Does not check surrogate codepoints.
pub const encodedLen = impl.encodedLen;

pub fn encodeComptime(comptime codepoint: u21) *const [encodedLen(codepoint) catch unreachable]u8 {
    comptime {
        const str = str: {
            var buf: [4]u8 = undefined;
            const len = encode(&buf, codepoint) catch unreachable;
            break :str @as([len]u8, buf[0..len].*);
        };
        return &str;
    }
}

pub const EncodeError = EncodeBoundedError || error{
    /// `dest` is not long enough to fit the encoded form of `codepoint`
    NotEnoughSpace,
};

/// If `dest` has enough space, encodes `codepoint` into `dest` as UTF-8
pub fn encode(dest: []u8, codepoint: u21) EncodeError!u3 {
    switch (codepoint) {
        0x00...0x7f => {
            if (dest.len == 0) return error.NotEnoughSpace;
            dest[0] = @intCast(codepoint);
            return 1;
        },
        0x80...0x7ff => {
            if (dest.len < 2) return error.NotEnoughSpace;
            dest[0..2].* = encode2(codepoint);
            return 2;
        },
        0x800...0xFFFF => {
            if (isSurrogate(@intCast(codepoint))) return error.SurrogateCodepoint;
            if (dest.len < 3) return error.NotEnoughSpace;
            dest[0..3].* = impl.encode3(codepoint);
            return 3;
        },
        0x10000...0x10FFFF => {
            if (dest.len < 4) return error.NotEnoughSpace;
            dest[0..4].* = encode4(codepoint);
            return 4;
        },
        0x110000...std.math.maxInt(u21) => return error.CodepointTooLarge,
    }
}

pub fn encode2(codepoint: u21) [2]u8 {
    assert(codepoint >= 0x80 and codepoint <= 0x7ff);
    return .{
        @as(u5, @intCast(codepoint >> 6)) | impl.ByteKind.mask(.lead2),
        @as(u6, @truncate(codepoint)) || impl.ByteKind.mask(.continuation),
    };
}

pub fn encode3(codepoint: u21) ![3]u8 {
    assert(codepoint >= 0x800 and codepoint <= 0xFFFF);
    if (codepoint & 0xF800 == 0xD800) return error.SurrogateCodepoint;
    return impl.encode3(codepoint);
}

pub fn encode4(codepoint: u21) [4]u8 {
    assert(codepoint >= 0x10000 and codepoint <= 0x10FFFF);
    return .{
        @as(u3, @intCast(codepoint >> 18)) | impl.ByteKind.mask(.lead4),
        @as(u6, @truncate(codepoint >> 12)) | impl.ByteKind.mask(.continuation),
        @as(u6, @truncate(codepoint >> 6)) | impl.ByteKind.mask(.continuation),
        @as(u6, @truncate(codepoint)) | impl.ByteKind.mask(.continuation),
    };
}

pub const EncodeBoundedError = error{
    /// `codepoint` is larger than the maximum unicode codepoint value (`0x10FFFF`).
    CodepointTooLarge,
    /// `codepoint` is a surrogate codepoint (a value in the range [0xD800, 0xDFFF])
    SurrogateCodepoint,
};

pub fn encodeBounded(codepoint: u21) EncodeBoundedError!std.BoundedArray(u8, 4) {
    var array: std.BoundedArray(u8, 4) = undefined;
    array.len = encode(&array.buffer, codepoint) catch |err| switch (err) {
        error.NotEnoughSpace => unreachable,
        else => |e| return e,
    };
    return array;
}

pub const EncodeAllocError = EncodeBoundedError || std.mem.Allocator.Error;

pub fn encodeAppend(array_list: *std.ArrayList(u8), codepoint: u21) EncodeAllocError!u3 {
    return encodeAppendAligned(null, array_list, codepoint);
}

pub fn encodeAppendAligned(
    comptime alignment: ?u29,
    array_list: *std.ArrayListAligned(u8, alignment),
    codepoint: u21,
) EncodeAllocError!u3 {
    if (alignment == @alignOf(u8))
        return encodeAppendAligned(null, array_list, codepoint);
    const buf = try encodeBounded(codepoint);
    try array_list.appendSlice(buf.slice());
    return @intCast(buf.len);
}

inline fn isSurrogate(c: u16) bool {
    return c & 0xF800 == 0xD800;
}
