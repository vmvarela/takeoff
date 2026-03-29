const std = @import("std");

/// Simple progress bar for terminal output
pub const ProgressBar = struct {
    total: usize,
    current: usize,
    width: usize,
    writer: std.io.AnyWriter,

    /// Initialize a new progress bar
    pub fn init(total: usize, width: usize, writer: std.io.AnyWriter) ProgressBar {
        return .{
            .total = total,
            .current = 0,
            .width = width,
            .writer = writer,
        };
    }

    /// Update progress and redraw
    pub fn update(self: *ProgressBar, current: usize) !void {
        self.current = current;
        try self.draw();
    }

    /// Increment progress by one
    pub fn increment(self: *ProgressBar) !void {
        self.current += 1;
        try self.draw();
    }

    /// Draw the progress bar
    fn draw(self: *ProgressBar) !void {
        if (self.total == 0) return;

        const percent = @as(f64, @floatFromInt(self.current)) / @as(f64, @floatFromInt(self.total));
        const filled = @as(usize, @intFromFloat(percent * @as(f64, @floatFromInt(self.width))));

        // Move to beginning of line and clear it
        try self.writer.print("\r\x1b[K", .{});

        // Draw progress bar
        try self.writer.print("[", .{});
        var i: usize = 0;
        while (i < self.width) : (i += 1) {
            if (i < filled) {
                try self.writer.print("█", .{});
            } else {
                try self.writer.print("░", .{});
            }
        }
        try self.writer.print("] {d}/{d} ({d:.1}%)", .{
            self.current,
            self.total,
            percent * 100.0,
        });
    }

    /// Finish and print newline
    pub fn finish(self: *ProgressBar) !void {
        try self.writer.print("\n", .{});
    }
};

test "ProgressBar initializes correctly" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer().any();

    const pb = ProgressBar.init(10, 20, writer);
    try std.testing.expectEqual(@as(usize, 10), pb.total);
    try std.testing.expectEqual(@as(usize, 0), pb.current);
    try std.testing.expectEqual(@as(usize, 20), pb.width);
}
