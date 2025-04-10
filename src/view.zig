const t = @cImport({
    @cInclude("/opt/homebrew/Cellar/libtickit/0.4.5/include/tickit.h");
});

pub const View = @This();

const std = @import("std");
const App = @import("app.zig").App;
const THROTTLE_INTERVAL = 30;
const CURSOR_JUMP = 2;

cursor_loc: c_int = 0,
tickit: *t.Tickit,
root: *t.TickitWindow,
command_window: *t.TickitWindow,
resultWindow: *t.TickitWindow,
last_scroll_event: i64 = 0,

fn keyboardClickEventHandler(
    _: ?*t.TickitWindow,
    _: t.TickitEventFlags,
    _info: ?*anyopaque,
    _ctx: ?*anyopaque,
) callconv(.c) c_int {
    const ctx: *App = if (_ctx != null) @ptrCast(@alignCast(_ctx)) else {
        return 0;
    };
    _ = ctx;

    const info: *t.TickitKeyEventInfo = if (_info != null) @ptrCast(@alignCast(_info)) else {
        return 0;
    };

    std.log.info("keyboard clicked, {any} {s}", .{ info, info.str });
    return 1;
}

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

    const current_time = std.time.milliTimestamp();

    if (current_time - ctx.view.?.last_scroll_event < THROTTLE_INTERVAL) {
        std.log.debug("throatle\n", .{});
        return 0;
    }
    ctx.view.?.last_scroll_event = current_time;

    const info: *t.TickitMouseEventInfo = if (_info != null) @ptrCast(@alignCast(_info)) else {
        return 0;
    };

    // std.log.err("mouse event -> {any}", .{info});

    if (info.type == t.TICKIT_MOUSEEV_PRESS and info.button == 3) {
        // std.log.err("mouse event -> {any}", .{info});
        switch (info.col) {
            (20) => {
                std.log.err("scrolling down", .{});
                ctx.view.?.cursor_loc += CURSOR_JUMP;
                if (ctx.view.?.cursor_loc > ctx.parsedBuffer.?.len) {
                    ctx.view.?.cursor_loc = @intCast(ctx.parsedBuffer.?.len); // stack at max
                } else {
                    t.tickit_window_expose(ctx.view.?.resultWindow, null);
                }
            },
            (19) => {
                std.log.err("scrolling up", .{});
                ctx.view.?.cursor_loc -= CURSOR_JUMP;
                if (ctx.view.?.cursor_loc < 0) {
                    ctx.view.?.cursor_loc = 0;
                } else {
                    t.tickit_window_expose(ctx.view.?.resultWindow, null); // stack at min
                }
            },
            else => {},
        }
    }

    return 1;
}

fn commandWindowExposeHandler(
    win: ?*t.TickitWindow,
    _: t.TickitEventFlags,
    _info: ?*anyopaque,
    _ctx: ?*anyopaque,
) callconv(.c) c_int {
    const info: *t.TickitExposeEventInfo = if (_info != null) @ptrCast(@alignCast(_info)) else {
        return 0;
    };

    const ctx: *App = if (_ctx != null) @ptrCast(@alignCast(_ctx)) else {
        return 0;
    };

    const rb = info.rb.?;

    const command = std.fmt.allocPrint(ctx.alloc, "jq > {s}", .{ctx.command.all()}) catch {
        std.log.err("error allocating command", .{});
        return 0;
    };
    defer ctx.alloc.free(command);

    std.log.debug("command window expose {s}", .{command});

    t.tickit_renderbuffer_clear(rb);
    _ = t.tickit_renderbuffer_text_at(rb, 0, 0, command.ptr);

    t.tickit_window_set_cursor_position(win, 0, @intCast(command.len));

    return 1;
}

fn childWindowExposeHandler(
    _: ?*t.TickitWindow,
    _: t.TickitEventFlags,
    _info: ?*anyopaque,
    _ctx: ?*anyopaque,
) callconv(.c) c_int {
    const info: *t.TickitExposeEventInfo = if (_info != null) @ptrCast(@alignCast(_info)) else {
        return 0;
    };

    const ctx: *App = if (_ctx != null) @ptrCast(@alignCast(_ctx)) else {
        return 0;
    };

    const available_rows = t.tickit_window_lines(ctx.view.?.resultWindow);
    const rb = info.rb.?;

    const render_start: c_int = ctx.view.?.cursor_loc;
    const capacity: c_int = render_start + @as(c_int, @intCast(available_rows));
    var render_end: c_int = capacity;
    if (render_end > ctx.parsedBuffer.?.len) {
        render_end = @intCast(ctx.parsedBuffer.?.len);
    }

    t.tickit_renderbuffer_clear(rb);

    for (@intCast(render_start)..@intCast(render_end), 0..) |i, j| {
        if (ctx.parsedBuffer.?[i].len == 0) {
            continue;
        }
        _ = t.tickit_renderbuffer_text_at(rb, @intCast(j), 0, ctx.parsedBuffer.?[i].ptr);
    }

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

    t.tickit_window_set_geometry(ctx.view.?.command_window, t.TickitRect{
        .top = 0,
        .left = 0,
        .lines = 2,
        .cols = t.tickit_window_cols(rootWindow),
    });
    t.tickit_window_expose(ctx.view.?.command_window, null);

    t.tickit_window_set_geometry(ctx.view.?.resultWindow, t.TickitRect{
        .top = 2,
        .left = 0,
        .lines = t.tickit_window_lines(rootWindow),
        .cols = t.tickit_window_cols(rootWindow),
    });

    t.tickit_window_expose(ctx.view.?.resultWindow, null);
    return 1;
}

pub fn init() View {
    const tk: *t.Tickit = t.tickit_new_stdtty().?;

    const root = t.tickit_get_rootwin(tk).?;

    const top_window = t.tickit_window_new(
        root,
        t.TickitRect{
            .top = 0,
            .left = 0,
            .lines = 2,
            .cols = t.tickit_window_cols(root),
        },
        0,
    ).?;

    const resultWindow = t.tickit_window_new(
        root,
        t.TickitRect{
            .top = 2,
            .left = 0,
            .lines = t.tickit_window_lines(root),
            .cols = t.tickit_window_cols(root),
        },
        0,
    ).?;

    return View{
        .tickit = tk,
        .root = root,
        .resultWindow = resultWindow,
        .command_window = top_window,
    };
}

pub fn attach_events(self: *View, app: *App) void {
    _ = t.tickit_window_bind_event(
        self.resultWindow,
        t.TICKIT_WINDOW_ON_EXPOSE,
        0,
        childWindowExposeHandler,
        app,
    );

    _ = t.tickit_window_bind_event(
        self.command_window,
        t.TICKIT_WINDOW_ON_EXPOSE,
        0,
        commandWindowExposeHandler,
        app,
    );

    // _ = t.tickit_window_bind_event(
    //     self.root,
    //     t.TICKIT_WINDOW_ON_MOUSE,
    //     0,
    //     mouseClickHandler,
    //     app,
    // );

    _ = t.tickit_window_bind_event(
        self.command_window,
        t.TICKIT_WINDOW_ON_KEY,
        0,
        keyboardClickEventHandler,
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
    t.tickit_window_take_focus(self.command_window);
    t.tickit_run(self.tickit);
}

pub fn deinit(self: *View) void {
    t.tickit_unref(self.tickit);
}
