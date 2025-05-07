const std = @import("std");

const JQResult = struct {
    std_out: []u8,
    std_err: []u8,

    pub fn free(self: *JQResult, alloc: std.mem.Allocator) void {
        alloc.free(self.std_out);
        alloc.free(self.std_err);
    }
};

pub fn handleJQ(
    alloc: std.mem.Allocator,
    command: []const u8,
    input_buffer: []const u8,
) !JQResult {
    const argv: []const []const u8 = &[_][]const u8{
        "jq",
        command,
    };

    var childProcess = std.process.Child.init(argv[0..], alloc);

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

    var index: usize = 0;
    while (index < input_buffer.len) {
        index += childProcess.stdin.?.write(input_buffer) catch break; // if it fails (BrokenPipe or anything) it breaks;
    }

    childProcess.stdin.?.close();
    childProcess.stdin = null;

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stdout.deinit(alloc);
    var stderr: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stderr.deinit(alloc);

    try childProcess.collectOutput(
        alloc,
        &stdout,
        &stderr,
        std.math.maxInt(usize),
    );

    // free the previous values before storing the new ones

    const result = JQResult{
        .std_out = try stdout.toOwnedSlice(alloc),
        .std_err = try stderr.toOwnedSlice(alloc),
    };

    _ = try childProcess.wait();
    return result;
}
