const std = @import("std");
const List = @import("list.zig").List;
const utils = @import("utils.zig");
pub const App = @This();

const View = @import("view.zig").View;

alloc: std.mem.Allocator,

MAX_CAP: usize = (1 << 29), // ~500MB

input_buffer: ?[]u8 = null,
command: List(u8),

stdout_buffer: ?[]u8 = null,
stderr_buffer: ?[]u8 = null,
errorBuffer: ?[][]const u8 = null,
parsedBuffer: ?[][]const u8 = null,
view: ?*View = null,

pub fn init(alloc: std.mem.Allocator) !App {
    return App{
        .alloc = alloc,
        .stdout_buffer = &[_]u8{},
        .stderr_buffer = &[_]u8{},
        .errorBuffer = &[_][]const u8{},
        .parsedBuffer = &[_][]const u8{},

        .command = List(u8).init(alloc),
    };
}

pub fn deinit(self: *App) void {
    std.log.info("closing app\n", .{});
    if (self.view) |v| v.deinit();

    if (self.parsedBuffer) |data| {
        for (data) |part| {
            self.alloc.free(part);
        }
        self.alloc.free(data);
    }

    if (self.errorBuffer) |data| {
        for (data) |part| {
            self.alloc.free(part);
        }
        self.alloc.free(data);
    }

    self.command.deinit();
    if (self.stderr_buffer) |buff| {
        self.alloc.free(buff);
    }
    if (self.stdout_buffer) |buff| {
        self.alloc.free(buff);
    }

    if (self.input_buffer) |buff| {
        self.alloc.free(buff);
    }
}

pub fn get_input(self: *App) ![]u8 {
    var input_array = std.ArrayList(u8).init(self.alloc);
    defer input_array.deinit();

    const stdin = std.io.getStdIn();
    var buffer = std.io.bufferedReaderSize((1 << 20), stdin.reader());

    try buffer.reader().readAllArrayList(&input_array, self.MAX_CAP);

    return try input_array.toOwnedSlice();
}

pub fn split_buffer(
    self: *App,
    current: []const u8,
) ![][]const u8 {
    var splited_data = std.ArrayList([]const u8).init(self.alloc);
    defer splited_data.deinit();

    var iter = std.mem.splitSequence(u8, current, "\n");
    while (iter.next()) |part| {
        try splited_data.append(try self.alloc.dupe(u8, part));
    }
    return splited_data.toOwnedSlice();
}

pub fn processCommand(self: *App, command: []const u8) !void {
    utils.handleJQ(
        self.alloc,
        command,
        self.input_buffer.?,
        &self.stdout_buffer.?,
        &self.stderr_buffer.?,
    ) catch |err| {
        // std.log.err("{s}\n", .{@errorName(err)});
        self.errorBuffer = try self.split_buffer(@errorName(err));
        return;
    };

    if (self.stdout_buffer.?.len > 0) {
        if (self.parsedBuffer) |data| {
            for (data) |part| {
                self.alloc.free(part);
            }
            self.alloc.free(data);
        }
        self.parsedBuffer = try self.split_buffer(self.stdout_buffer.?);
    }

    if (self.stderr_buffer.?.len > 0) {
        // std.debug.print("->\n{?s}\n<-\n", .{self.stderr_buffer});
    }
    if (self.errorBuffer) |data| {
        for (data) |part| {
            self.alloc.free(part);
        }
        self.alloc.free(data);
    }
    self.errorBuffer = try self.split_buffer(self.stderr_buffer.?);
}

pub fn run(self: *App) !void {
    self.input_buffer = self.get_input() catch |err| {
        std.log.err("error {any} ", .{@errorName(err)});
        @panic("error reading the data");
    };

    try self.command.fromArray(".");
    try self.processCommand(self.command.all());

    var v = View.init();
    self.view = &v;

    self.view.?.configureTUI(self);

    // std.log.info("starting tickit window\n", .{});
    self.view.?.run();
}
