// SPDX-License-Identifier: GPL-3.0-or-later
//! QR code rendering for the login screen (spec §5.3): qrcodegen, Unicode half blocks, two module
//! rows per text line, 4-module quiet zone. Like upstream (qrcode crate `Dense1x2` with swapped
//! colors), light modules are drawn as blocks, so on a dark terminal the code reads dark-on-light.
const std = @import("std");
const c = @import("c");

pub const quiet_zone = 4;
const buffer_len = 3918; // qrcodegen_BUFFER_LEN_FOR_VERSION(40)

pub const Code = struct {
    buf: [buffer_len]u8,
    size: usize,

    pub fn dark(q: *const Code, x: usize, y: usize) bool {
        return c.qrcodegen_getModule(&q.buf, @intCast(x), @intCast(y));
    }
};

/// Encodes `text` at error correction level M (the qrcode crate default), smallest version.
pub fn encode(text: [:0]const u8) error{QrTooLong}!Code {
    var tmp: [buffer_len]u8 = undefined;
    var q: Code = .{ .buf = undefined, .size = 0 };
    if (!c.qrcodegen_encodeText(text.ptr, &tmp, &q.buf, c.qrcodegen_Ecc_MEDIUM, 1, 40, c.qrcodegen_Mask_AUTO, false))
        return error.QrTooLong;
    q.size = @intCast(c.qrcodegen_getSize(&q.buf));
    return q;
}

/// Writes the code as text lines.
pub fn render(q: *const Code, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const edge = q.size + 2 * quiet_zone;
    var y: usize = 0;
    while (y < edge) : (y += 2) {
        for (0..edge) |x| {
            const top = lit(q, x, y);
            const bottom = y + 1 < edge and lit(q, x, y + 1);
            try w.writeAll(if (top and bottom) "█" else if (top) "▀" else if (bottom) "▄" else " ");
        }
        try w.writeByte('\n');
    }
}

/// A block is drawn for light modules, including the quiet zone.
fn lit(q: *const Code, x: usize, y: usize) bool {
    if (x < quiet_zone or y < quiet_zone) return true;
    const mx = x - quiet_zone;
    const my = y - quiet_zone;
    if (mx >= q.size or my >= q.size) return true;
    return !q.dark(mx, my);
}

test "encode and render" {
    const q = try encode("https://example.com/x");
    try std.testing.expectEqual(@as(usize, 25), q.size); // version 2 at level M
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&q, &out.writer);
    const text = out.written();
    try std.testing.expectEqual(@as(usize, (25 + 8 + 1) / 2), std.mem.count(u8, text, "\n"));
    // First line is all quiet zone; the finder pattern corner is dark, i.e. not a full block.
    var lines = std.mem.splitScalar(u8, text, '\n');
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "████"));
    _ = lines.next();
    const third = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, third, "████ "));
}
