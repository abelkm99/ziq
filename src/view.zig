const t = @cImport({
    @cInclude("/opt/homebrew/Cellar/libtickit/0.4.5/include/tickit.h");
});

pub const View = @This();

const std = @import("std");
const App = @import("app.zig").App;

cursor_loc: c_int = 0,
tickit: *t.Tickit,
root: *t.TickitWindow,
child_window: *t.TickitWindow,

fn mouseClickHandler(
    _: ?*t.TickitWindow,
    _: t.TickitEventFlags,
    _info: ?*anyopaque,
    _ctx: ?*anyopaque,
) callconv(.c) c_int {
    // std.log.info("mouse click event\n", .{});

    const ctx: *App = if (_ctx != null) @ptrCast(@alignCast(_ctx)) else {
        return 0;
    };

    const info: *t.TickitMouseEventInfo = if (_info != null) @ptrCast(@alignCast(_info)) else {
        return 0;
    };

    // std.log.err("mouse event -> {any}", .{info});

    if (info.type == t.TICKIT_MOUSEEV_PRESS and info.button == 3) {
        // std.log.err("mouse event -> {any}", .{info});
        switch (info.col) {
            (20) => {
                std.log.err("scrolling down", .{});
                ctx.view.?.cursor_loc += 1;
                if (ctx.view.?.cursor_loc > ctx.parsedBuffer.?.len) {
                    ctx.view.?.cursor_loc = @intCast(ctx.parsedBuffer.?.len); // stack at max
                } else {
                    t.tickit_window_expose(ctx.view.?.child_window, null);
                }
            },
            (19) => {
                std.log.err("scrolling up", .{});
                ctx.view.?.cursor_loc -= 1;
                if (ctx.view.?.cursor_loc < 0) {
                    ctx.view.?.cursor_loc = 0;
                } else {
                    t.tickit_window_expose(ctx.view.?.child_window, null); // stack at min
                }
            },
            else => {},
        }
    }

    return 1;
}

fn windowExposeHandler(
    _: ?*t.TickitWindow,
    _: t.TickitEventFlags,
    _info: ?*anyopaque,
    _ctx: ?*anyopaque,
) callconv(.c) c_int {
    // std.log.info("expose event\n", .{});

    // const info: *t.TickitExposeEventInfo
    const info: *t.TickitExposeEventInfo = if (_info != null) @ptrCast(@alignCast(_info)) else {
        return 0;
    };

    const ctx: *App = if (_ctx != null) @ptrCast(@alignCast(_ctx)) else {
        return 0;
    };
    // _ = info;

    const available_rows = t.tickit_window_lines(ctx.view.?.child_window);
    const rb = info.rb.?;

    // std.log.debug("info at render window  {any}\n", .{info});

    // std.log.err("cursor loc is  {any} \n", .{ctx.view.?.cursor_loc});

    // std.log.err("available rows are {} \n", .{available_rows});

    const render_start: c_int = ctx.view.?.cursor_loc;
    const capacity: c_int = render_start + @as(c_int, @intCast(available_rows));
    var render_end: c_int = capacity;
    if (render_end > ctx.parsedBuffer.?.len) {
        render_end = @intCast(ctx.parsedBuffer.?.len);
    }

    t.tickit_renderbuffer_clear(rb);

    for (@intCast(render_start)..@intCast(render_end), 0..) |i, j| {
        const copy: []const u8 = ctx.alloc.dupe(u8, ctx.parsedBuffer.?[i]) catch return 0;
        defer ctx.alloc.free(copy);
        _ = t.tickit_renderbuffer_text_at(rb, @intCast(j), 0, @as([*]const u8, copy.ptr));
    }

    // for (@intCast(render_end - render_start)..@intCast(available_rows)) |i| {
    //     std.log.err("resetting {}", .{i});
    //     _ = t.tickit_renderbuffer_text_at(rb, @intCast(i), 0, "bella man");
    //     // t.tickit_renderbuffer_text_at
    // }

    return 1;
}

fn resizeCallback(
    rootWindow: ?*t.TickitWindow,
    _: c_uint,
    _: ?*anyopaque,
    _ctx: ?*anyopaque,
) callconv(.c) c_int {
    // std.log.debug("window resized", .{});

    const ctx: *App = if (_ctx != null) @ptrCast(@alignCast(_ctx)) else {
        std.log.err("error getting the context", .{});
        return 0;
    };

    t.tickit_window_set_geometry(ctx.view.?.child_window, t.TickitRect{
        .top = 0,
        .left = 0,
        .lines = t.tickit_window_lines(rootWindow),
        .cols = t.tickit_window_cols(rootWindow),
    });

    t.tickit_window_expose(ctx.view.?.child_window, null);
    return 1;
}

pub fn init() View {
    const tk: *t.Tickit = t.tickit_new_stdtty().?;

    const root = t.tickit_get_rootwin(tk).?;

    // t.tickit_window_set_geometry(ctx.tickit.?.bottomWindow, t.TickitRect{
    //     .top = 3,
    //     .left = 0,
    //     .lines = t.tickit_window_lines(rootWindow),
    //     .cols = t.tickit_window_cols(rootWindow),
    // });

    const child_window = t.tickit_window_new(
        root,
        t.tickit_window_get_geometry(root),
        0,
    ).?;

    return View{
        .tickit = tk,
        .root = root,
        .child_window = child_window,
    };
}

pub fn attach_events(self: *View, app: *App) void {
    _ = t.tickit_window_bind_event(
        self.child_window,
        t.TICKIT_WINDOW_ON_EXPOSE,
        0,
        windowExposeHandler,
        app,
    );

    _ = t.tickit_window_bind_event(
        self.root,
        t.TICKIT_WINDOW_ON_MOUSE,
        0,
        mouseClickHandler,
        app,
    );

    _ = t.tickit_window_bind_event(
        self.root,
        t.TICKIT_WINDOW_ON_GEOMCHANGE,
        0,
        resizeCallback,
        app,
    );
}

pub fn run(self: *View) void {
    t.tickit_run(self.tickit);
}

pub fn deinit(self: *View) void {
    t.tickit_unref(self.tickit);
}
