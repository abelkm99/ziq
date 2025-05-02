const t = @cImport({
    @cInclude("/usr/local/include/tickit.h");
});

pub const View = @This();

const std = @import("std");
const App = @import("app.zig").App;
const THROTTLE_INTERVAL = 30;
const CURSOR_JUMP = 3;
const ERROR_RATIO = NormalizedStruct{
    .nx = 0.7,
    .ny = 0.3,
    .nw = 0.3,
    .nh = 0.5,
};

const NormalizedStruct = struct {
    nx: f32,
    ny: f32,
    nw: f32,
    nh: f32,
};

cursor_loc: c_int = 0,
tickit: *t.Tickit,
root: *t.TickitWindow,
command_window: *t.TickitWindow,
errorWindow: *t.TickitWindow,
resultWindow: *t.TickitWindow,
last_scroll_event: i64 = 0,
state: bool = true,


fn thread_test(view: *View) void {
    std.log.info("thread entered", .{});
    std.time.sleep(2 * std.time.ns_per_s);
    std.log.info("exposing window", .{});
    t.tickit_window_show(view.errorWindow);
    t.tickit_window_expose(view.errorWindow, null);
    t.tickit_tick(view.tickit, t.TICKIT_RUN_NOHANG);
    // t.tickit_watch_later(
    //     view.tickit,
    //     0,
    //     thread_call_back,
    //     null,
    // );
    std.log.info("thread job completed", .{});
}

fn normalizeWindow(
    parentRect: t.TickitRect,
    normalizedRect: NormalizedStruct,
) t.TickitRect {
    const parent_top_f: f32 = @floatFromInt(parentRect.top);
    const parent_left_f: f32 = @floatFromInt(parentRect.left);
    const parent_lines_f: f32 = @floatFromInt(parentRect.lines);
    const parent_cols_f: f32 = @floatFromInt(parentRect.cols);

    const child_top_f = parent_top_f + (parent_lines_f * normalizedRect.ny);
    const child_left_f = parent_left_f + (parent_cols_f * normalizedRect.nx);
    const child_lines_f = parent_lines_f * normalizedRect.nh;
    const child_cols_f = parent_cols_f * normalizedRect.nw;

    return t.TickitRect{
        .top = @intFromFloat(child_top_f),
        .left = @intFromFloat(child_left_f),
        .lines = @intFromFloat(child_lines_f),
        .cols = @intFromFloat(child_cols_f),
    };
}

fn keyboardClickEventHandler(
    _: ?*t.TickitWindow,
    _: t.TickitEventFlags,
    _info: ?*anyopaque,
    _ctx: ?*anyopaque,
) callconv(.c) c_int {
    const ctx: *App = if (_ctx != null) @ptrCast(@alignCast(_ctx)) else {
        return 0;
    };

    const info: *t.TickitKeyEventInfo = if (_info != null) @ptrCast(@alignCast(_info)) else {
        return 0;
    };

    const input: [:0]const u8 = std.mem.span(info.str);

    if (std.mem.eql(u8, input, "Backspace")) {
        _ = ctx.command.pop();
    }

    if (input.len == 1) {
        if (std.ascii.isPrint(input[0])) {
            _ = ctx.command.append(input[0]) catch {};
        }
    }
    const command = ctx.command.all();

    std.log.debug("command is {s}", .{command});
    ctx.processCommand(command) catch {
        std.log.err("error processing command", .{});
    };

    if (ctx.stderr_buffer.?.len > 0) {
        std.debug.print("---> std error is {?s}", .{ctx.stderr_buffer});
        t.tickit_window_show(ctx.view.?.errorWindow);
    } else {
        t.tickit_window_hide(ctx.view.?.errorWindow);
    }
    t.tickit_window_expose(ctx.view.?.resultWindow, null);
    t.tickit_window_expose(ctx.view.?.errorWindow, null);
    t.tickit_window_expose(ctx.view.?.command_window, null);

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
        return 0;
    };
    defer ctx.alloc.free(command);

    t.tickit_renderbuffer_clear(rb);
    _ = t.tickit_renderbuffer_text_at(rb, 0, 0, command.ptr);

    t.tickit_window_set_cursor_position(win, 0, @intCast(command.len));

    return 1;
}

fn mouseScrollEventHandler(
    _: ?*t.TickitWindow,
    _: t.TickitEventFlags,
    _info: ?*anyopaque,
    _ctx: ?*anyopaque,
) callconv(.c) c_int {
    const ctx: *App = if (_ctx != null) @ptrCast(@alignCast(_ctx)) else {
        return 0;
    };

    const current_time = std.time.milliTimestamp();

    if (current_time - ctx.view.?.last_scroll_event < THROTTLE_INTERVAL) {
        // std.log.debug("throatle\n", .{});
        return 1;
    }

    _ = &_info;

    ctx.view.?.last_scroll_event = current_time;

    const info: *t.TickitMouseEventInfo = if (_info != null) @ptrCast(@alignCast(_info)) else {
        return 0;
    };
    _ = &info;

    if (info.type == t.TICKIT_MOUSEEV_WHEEL) {
        // std.log.err("mouse event -> {any}", .{info});
        switch (info.button) {
            (2) => {
                // std.log.err("scrolling down", .{});
                ctx.view.?.cursor_loc += CURSOR_JUMP;
                if (ctx.view.?.cursor_loc > ctx.parsedBuffer.?.len) {
                    ctx.view.?.cursor_loc = @intCast(ctx.parsedBuffer.?.len); // stack at max
                } else {
                    t.tickit_window_expose(ctx.view.?.resultWindow, null);
                }
            },
            (1) => {
                // std.log.err("scrolling up", .{});
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

fn onErrorWindowExposeHandler(
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

    t.tickit_renderbuffer_clear(rb);

    {
        const pen: *t.TickitPen = t.tickit_pen_new().?;
        defer t.tickit_pen_unref(pen);

        t.tickit_pen_set_colour_attr(pen, t.TICKIT_PEN_FG, 1);
        t.tickit_renderbuffer_setpen(rb, pen);

        const lines: c_int = t.tickit_window_lines(win);
        const cols: c_int = t.tickit_window_cols(win);

        t.tickit_renderbuffer_goto(rb, 0, 0);
        _ = t.tickit_renderbuffer_text(rb, "┌");
        t.tickit_renderbuffer_goto(rb, 0, cols - 1);
        _ = t.tickit_renderbuffer_text(rb, "┐");
        t.tickit_renderbuffer_goto(rb, lines - 1, 0);
        _ = t.tickit_renderbuffer_text(rb, "└");
        t.tickit_renderbuffer_goto(rb, lines - 1, cols - 1);
        _ = t.tickit_renderbuffer_text(rb, "┘");

        t.tickit_renderbuffer_hline_at(
            rb,
            0,
            1,
            cols - 2,
            t.TICKIT_LINE_SINGLE,
            0,
        );
        t.tickit_renderbuffer_hline_at(
            rb,
            lines - 1,
            1,
            cols - 2,
            t.TICKIT_LINE_SINGLE,
            0,
        );

        t.tickit_renderbuffer_vline_at(
            rb,
            1,
            lines - 2,
            0,
            t.TICKIT_LINE_SINGLE,
            0,
        );
        t.tickit_renderbuffer_vline_at(
            rb,
            1,
            lines - 2,
            cols - 1,
            t.TICKIT_LINE_SINGLE,
            0,
        );

        const error_lines: usize = @intCast(t.tickit_window_lines(ctx.view.?.errorWindow));
        if (error_lines <= 0) {
            return 1;
        }
        var idx: u16 = 1;
        for (ctx.errorBuffer.?) |row| {
            // even for 1 i could go twice
            if (row.len == 0) {
                continue;
            }

            var j: usize = 0;
            while (j < row.len) {
                _ = t.tickit_renderbuffer_textn_at(
                    rb,
                    @intCast(idx),
                    1,
                    row[j..].ptr,
                    error_lines,
                );
                j += error_lines;
                idx += 1;
            }

            idx += 2;

            // break

        }
    }

    // Draw border lines
    // Horizontal lines

    // Vertical lines

    // tickit_pen_unref(pen);

    return 1;
}

fn resultWindowExposeHandler(
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

        _ = t.tickit_renderbuffer_textn_at(
            rb,
            @intCast(j),
            0,
            ctx.parsedBuffer.?[i].ptr,
            ctx.parsedBuffer.?[i].len,
        );
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
        // std.log.err("error getting the context", .{});
        return 0;
    };

    t.tickit_window_set_geometry(ctx.view.?.command_window, t.TickitRect{
        .top = 0,
        .left = 0,
        .lines = 2,
        .cols = t.tickit_window_cols(rootWindow),
    });
    t.tickit_window_expose(ctx.view.?.command_window, null);

    const parent_rect = t.TickitRect{
        .top = 2,
        .left = 0,
        .lines = t.tickit_window_lines(rootWindow),
        .cols = t.tickit_window_cols(rootWindow),
    };

    t.tickit_window_set_geometry(ctx.view.?.resultWindow, parent_rect);
    t.tickit_window_expose(ctx.view.?.resultWindow, null);

    t.tickit_window_set_geometry(
        ctx.view.?.errorWindow,
        normalizeWindow(parent_rect, ERROR_RATIO),
    );
    t.tickit_window_expose(ctx.view.?.errorWindow, null);
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

    const parent_rect = t.tickit_window_get_geometry(resultWindow);

    const errorWindow = t.tickit_window_new(
        resultWindow,
        normalizeWindow(parent_rect, ERROR_RATIO),
        0,
    ).?;

    return View{
        .tickit = tk,
        .root = root,
        .resultWindow = resultWindow,
        .command_window = top_window,
        .errorWindow = errorWindow,
    };
}

pub fn attach_events(self: *View, app: *App) void {
    // expose windows
    _ = t.tickit_window_bind_event(
        self.resultWindow,
        t.TICKIT_WINDOW_ON_EXPOSE,
        0,
        resultWindowExposeHandler,
        app,
    );

    // if the error window does not have any error, hide it
    if (app.stderr_buffer.?.len > 0) {
        t.tickit_window_show(self.errorWindow);
    } else {
        t.tickit_window_hide(self.errorWindow);
    }

    _ = t.tickit_window_bind_event(
        self.errorWindow,
        t.TICKIT_WINDOW_ON_EXPOSE,
        0,
        onErrorWindowExposeHandler,
        app,
    );

    _ = t.tickit_window_bind_event(
        self.command_window,
        t.TICKIT_WINDOW_ON_EXPOSE,
        0,
        commandWindowExposeHandler,
        app,
    );

    // bind event's

    _ = t.tickit_window_bind_event(
        self.resultWindow,
        t.TICKIT_WINDOW_ON_MOUSE,
        0,
        mouseScrollEventHandler,
        app,
    );

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

    _ = std.Thread.spawn(.{}, thread_test, .{self}) catch unreachable;

    t.tickit_run(self.tickit);
}

pub fn deinit(self: *View) void {
    t.tickit_unref(self.tickit);
}
