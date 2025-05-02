const std = @import("std");
const List = @import("list.zig").List;
pub const App = @This();

const View = @import("view.zig").View;

alloc: std.mem.Allocator,

MAX_CAP: usize = (1 << 29), // ~500MB

input_buffer: ?[]u8 = null,
command: List(u8),

stdout_buffer: ?[]const u8 = null,
stderr_buffer: ?[]const u8 = null,
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

pub fn handleJQ(self: *App, command: []const u8) !void {
    const argv: []const []const u8 = &[_][]const u8{
        "jq",
        command,
    };

    std.log.debug("input command --> {s}", .{argv});
    var childProcess = std.process.Child.init(argv[0..], self.alloc);

    childProcess.stdin_behavior = .Pipe;
    childProcess.stdout_behavior = .Pipe;
    childProcess.stderr_behavior = .Pipe;

    try childProcess.spawn();

    errdefer {
        _ = childProcess.kill() catch {};
    }

    defer if (childProcess.stdin != null) childProcess.stdin.?.close();
    defer if (childProcess.stdout != null) childProcess.stdout.?.close();
    defer if (childProcess.stderr != null) childProcess.stderr.?.close();

    errdefer _ = childProcess.kill() catch {}; // Attempt to kill if setup fails after spawn

    if (self.input_buffer) |input_buffer| {
        var index: usize = 0;
        while (index < input_buffer.len) {
            index += childProcess.stdin.?.write(input_buffer) catch break; // if it fails (BrokenPipe or anything) it breaks;
        }
    }

    childProcess.stdin.?.close();
    childProcess.stdin = null;

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stdout.deinit(self.alloc);
    var stderr: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stderr.deinit(self.alloc);

    try childProcess.collectOutput(
        self.alloc,
        &stdout,
        &stderr,
        self.MAX_CAP,
    );

    self.alloc.free(self.stdout_buffer.?);
    self.alloc.free(self.stderr_buffer.?);
    // free the previous values before storing the new ones
    self.stdout_buffer = try stdout.toOwnedSlice(self.alloc);
    self.stderr_buffer = try stderr.toOwnedSlice(self.alloc);
    _ = try childProcess.wait();
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
    self.handleJQ(command) catch |err| {
        std.log.err("{s}\n", .{@errorName(err)});
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
        std.debug.print("->\n{?s}\n<-\n", .{self.stderr_buffer});
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

    std.log.info("starting tickit window\n", .{});
    self.view.?.run();
}
