const std = @import("std");
const t = @cImport({
    @cInclude("../../libtickit-0.4.5/include/tickit.h");
});
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
// fn onErrorWindowExposeHandler(
//     w: ?*t.TickitWindow,
//     _: t.TickitEventFlags,
//     _info: ?*anyopaque,
//     _: ?*anyopaque,
// ) callconv(.c) c_int {

//     const info: *t.TickitExposeEventInfo = if (_info != null) @ptrCast(@alignCast(_info)) else {
//         return 0;
//     };
//     const rb = info.rb.?;
//     t.tickit_renderbuffer_clear(rb);

//     std.debug.print("{any}", .{w});
//     return 1;
// }
// var win: *t.TickitWindow = undefined;
// pub fn main() void {
//     const tk = t.tickit_new_stdtty().?;
//     win = t.tickit_get_rootwin(tk).?;

//     _ = t.tickit_window_bind_event(
//         win,
//         t.TICKIT_WINDOW_ON_EXPOSE,
//         0,
//         onErrorWindowExposeHandler,
//         null,
//     );

//     t.tickit_run(tk);

//     t.tickit_unref(tk);
// }
