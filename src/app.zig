const std = @import("std");
const Mutex = std.Thread.Mutex;
const List = @import("list.zig").List;
const Candidate = @import("trie.zig").Candidate;
const utils = @import("utils.zig");
const MAX_CAP: usize = (1 << 29); // ~500MB
pub const App = @This();

const View = @import("view.zig").View;
const engine_tool = @import("engine.zig");
const Engine = engine_tool.JQEngine;


alloc: std.mem.Allocator,

input_buffer: []const u8,
stdout_buffer: ?[]u8 = null,
stderr_buffer: ?[]u8 = null,
errorBuffer: ?[][]const u8 = null,
parsedBuffer: ?[][]const u8 = null,
suggestions: []Candidate,
lock: Mutex = .{},

view: ?*View = null,
engine: Engine,

pub fn init(alloc: std.mem.Allocator) !App {
    // get the input buffer in here

    var input_buffer = get_input(alloc) catch |err| {
        std.log.err("error {any} ", .{@errorName(err)});
        @panic("error reading the data");
    };
    return App{
        .alloc = alloc,
        .input_buffer = input_buffer,
        .stdout_buffer = &[_]u8{},
        .stderr_buffer = &[_]u8{},
        .errorBuffer = &[_][]const u8{},
        .parsedBuffer = &[_][]const u8{},
        .engine = Engine.init(alloc, &input_buffer),
        .suggestions = &[_]Candidate{},
    };
}

pub fn deinit(self: *App) void {
    // std.log.info("closing app\n", .{});
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

    self.engine.deinit();
    if (self.stderr_buffer) |buff| {
        self.alloc.free(buff);
    }
    if (self.stdout_buffer) |buff| {
        self.alloc.free(buff);
    }


    // clean up the suggestion
    for (self.suggestions) |suggestion| {
        self.alloc.free(suggestion.value);
    }
    self.alloc.free(self.suggestions);

    self.alloc.free(self.input_buffer);
}

pub fn get_input(alloc: std.mem.Allocator) ![]const u8 {
    var input_array = std.ArrayList(u8).init(alloc);
    defer input_array.deinit();

    const stdin = std.io.getStdIn();
    var buffer = std.io.bufferedReaderSize((1 << 20), stdin.reader());

    try buffer.reader().readAllArrayList(&input_array, MAX_CAP);

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
    const jq_res = utils.handleJQ(
        self.alloc,
        command,
        self.input_buffer,
    ) catch |err| {
        // std.log.err("{s}\n", .{@errorName(err)});
        self.errorBuffer = try self.split_buffer(@errorName(err));
        return;
    };

    if (jq_res.std_out.len > 0) {
        // if we get std_out result
        self.alloc.free(self.stdout_buffer.?);
        self.stdout_buffer = jq_res.std_out;
        if (self.parsedBuffer) |data| {
            for (data) |part| {
                self.alloc.free(part);
            }
            self.alloc.free(data);
        }
        self.parsedBuffer = try self.split_buffer(self.stdout_buffer.?);
    }

    self.alloc.free(self.stderr_buffer.?);
    self.stderr_buffer = jq_res.std_err;

    if (self.errorBuffer) |data| {
        for (data) |part| {
            self.alloc.free(part);
        }
        self.alloc.free(data);
    }
    if (self.stderr_buffer.?.len == 0) {
        self.errorBuffer = &[_][]const u8{};
    } else {
        self.errorBuffer = try self.split_buffer(self.stderr_buffer.?);
    }
}

pub fn run(self: *App) !void {
    try self.engine.generateCandidates(self.engine.root, 0, self.engine.json_input.*);
    try self.engine.add('.');
    try self.engine.recalc(0, self.input_buffer);
    self.suggestions = self.engine.get_candidate_idx(0, 10) catch unreachable;

    try self.processCommand(self.engine.get_command());

    var v = View.init();
    self.view = &v;

    self.view.?.configureTUI(self);

    // std.log.info("starting tickit window\n", .{});
    self.view.?.run();
}
