const std = @import("std");
const App = @import("app.zig").App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();

    defer {
        if (gpa.deinit() == .leak) {
            @panic("memory leak detected\n");
        }
    }

    var app = try App.init(allocator);
    defer {
        app.deinit();
    }

    try app.run();
}
