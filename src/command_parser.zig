const testing = std.testing;

const utitls = @import("utils.zig");
const Trie = @import("trie.zig").Trie;
const Candidate = @import("trie.zig").Candidate;
const Node = @import("trie.zig").Node;

const std = @import("std");
// some sort of majic gpt generated
const Query =
    \\ tostream | select(length==2) | .[0] | map(if type=="number" then "["+tostring+"]" else "."+tostring end) | join("")
;

const JQEngine = struct {
    const This = @This();
    alloc: std.mem.Allocator,
    command: std.ArrayList(u8),
    trie_node_list: std.ArrayList(?*Node),
    trie: Trie,
    suggestion_started: bool = false,

    fn init(alloc: std.mem.Allocator) JQEngine {
        return JQEngine{
            .alloc = alloc,
            .command = std.ArrayList(u8).init(alloc),
            .trie_node_list = std.ArrayList(?*Node).init(alloc),
            .trie = Trie.init(alloc) catch unreachable,
        };
    }

    fn deinit(self: *This) void {
        self.command.deinit();
        self.trie.deinit();
        self.trie_node_list.deinit();
    }

    /// parse cadidate buffer and populate it
    fn parseAndPopulateCandidates(alloc: std.mem.Allocator, trie: *Trie, candidates_buffer: []const u8) !void {
        // populate Trie
        var candidates = std.ArrayList([]const u8).init(alloc);
        defer candidates.deinit();
        var it = std.mem.splitSequence(u8, candidates_buffer, "\n");
        while (it.next()) |part| {
            if (part.len > 0) {
                const start_node = if (part[1] != '.') try trie.gerOrCreateNode(".") else try trie.gerOrCreateNode("");
                try trie.insertWithNode(start_node, part[1 .. part.len - 1]);
            }
        }
    }

    /// This function generate all possibel candidates and populates the Trie.
    ///
    /// generate_candidate is called once for one segment of the command
    /// one segment of command is a jq command that is separated by | character
    /// i.e jq '.user' | '.name'  this example will be two segments
    fn generateCandidates(self: *This, input_buffer: []const u8) !void {
        var query_buffer: [100000]u8 = undefined;
        var new_query: []u8 = undefined;
        // if the command is empty just pass the Query as JQ result.
        if (self.command.items.len == 0) {
            new_query = try std.fmt.bufPrint(&query_buffer, "{s}{s}", .{ self.get_command(), Query });
        } else {
            new_query = try std.fmt.bufPrint(&query_buffer, "{s} | {s}", .{ self.get_command(), Query });
        }
        var jq_res = try utitls.handleJQ(self.alloc, new_query, input_buffer);
        defer jq_res.free(self.alloc);
        if (jq_res.std_out.len >= 0) {
            try parseAndPopulateCandidates(self.alloc, &self.trie, jq_res.std_out);
        }

        var current = std.ArrayList(u8).init(self.alloc);
        defer current.deinit();
        var result = std.ArrayList(Candidate).init(self.alloc);
        defer result.deinit();
    }

    fn get_candidate_idx(self: *This, idx: usize, n: usize) ![]Candidate {
        if (self.trie_node_list.items.len > idx) {
            if (self.trie_node_list.items[idx]) |node| {
                var result = std.ArrayList(Candidate).init(self.alloc);
                defer result.deinit();
                try self.trie.getCandidatesBFS(node, &result, n);

                return try result.toOwnedSlice();
            }
        }
        return &[_]Candidate{};
    }

    fn add(self: *This, ch: u8) !void {
        try self.insert(ch, self.command.items.len);
    }

    fn insert(self: *This, ch: u8, idx: ?usize) !void {
        std.debug.print("adding {c}\n", .{ch});
        try self.command.append(ch);
        // if giving suggestion is not started start a new one which is the root node is appended
        // this code need a little some refactoring
        if (!self.suggestion_started and ch == '.') {
            self.suggestion_started = true;
            try self.trie_node_list.append(self.trie.root.children.get(ch).?);
        } else if (self.suggestion_started) {
            const last_idx = idx.? - 1;
            if (self.trie_node_list.items.len == 0 or self.trie_node_list.items[last_idx] == null) {
                try self.trie_node_list.append(null);
            } else {
                const last_node = self.trie_node_list.items[last_idx]; // last node can be null
                if (last_node) |node| {
                    try self.trie_node_list.append(node.children.get(ch));
                }

            }
        }

        if (idx) |i| {
            if (i >= self.command.items.len) {
                return error.OutOfBounds;
            }
            @memcpy(self.command.items[i + 1 ..], self.command.items[i .. self.command.items.len - 1]);
            self.command.items[i] = ch;
            return;
        }
        try self.trie_node_list.append(try self.trie.gerOrCreateNode(self.command.items));
    }

    fn get_command(self: *This) []u8 {
        return self.command.items;
    }
};

fn free_candidates(alloc: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |candidate| {
        alloc.free(candidate.value);
    }
    alloc.free(candidates);
}

fn checkCandidates(
    alloc: std.mem.Allocator,
    actual_candidates: []const Candidate,
    expected_values: []const []const u8,
) !void {
    _ = alloc;
    try testing.expectEqual(expected_values.len, actual_candidates.len);
    for (actual_candidates, 0..) |actual, i| {
        try testing.expectEqualStrings(expected_values[i], actual.value);
    }
}

test "test command parser" {
    const alloc = testing.allocator;

    {
        // const json = std.fs.cwd().readFileAlloc(alloc, "test.json", std.math.maxInt(usize)) catch |err| {
        //     std.debug.print("Error: {s}\n", .{@errorName(err)});
        //     return;
        // };
        const json =
            \\{
            \\    "name": "John",
            \\    "age": 30,
            \\    "city": "New York",
            \\    "cars": [
            \\        {
            \\          "model": "Ford",
            \\          "mpg": 25.1
            \\        },
            \\        {
            \\          "model": "BMW",
            \\          "mpg": 27.5
            \\        }
            \\    ]
            \\}
            \\
        ;

        var std_out: []u8 = &[_]u8{};
        var std_err: []u8 = &[_]u8{};
        _ = &std_out;
        _ = &std_err;
        defer {
            alloc.free(std_out);
            alloc.free(std_err);
        }
        // for suggestion use the previous data and give them sometihgn

        var engine = JQEngine.init(alloc);
        defer engine.deinit();
        try engine.generateCandidates(json);

        // Command: "."
        try engine.add('.');
        {
            // User log showed 5 candidates even though `count` was 4.
            // We will assert against the 5 logged candidates.
            const candidates_after_dot = try engine.get_candidate_idx(0, 4);
            defer free_candidates(engine.alloc, candidates_after_dot);

            // std.debug.print("\nCandidates after '.': (command: '{s}', idx: 0)\n", .{engine.get_command()});
            // for (candidates_after_dot) |part| {
            //     std.debug.print("  Value: '{s}'\n", .{part.value});
            // }

            const expected_after_dot = [_][]const u8{
                "age",
                "name",
                "city",
                "cars[1].mpg",
            };
            try checkCandidates(alloc, candidates_after_dot, &expected_after_dot);
        }

        // Test 2: After adding 'c'
        // Command: ".c"
        try engine.add('c');
        {
            const candidates_after_c = try engine.get_candidate_idx(1, 4); // idx=1 refers to 'c'
            defer free_candidates(engine.alloc, candidates_after_c);

            // std.debug.print("\nCandidates after '.c': (command: '{s}', idx: 1)\n", .{engine.get_command()});
            // for (candidates_after_c) |part| {
            //     std.debug.print("  Value: '{s}'\n", .{part.value});
            // }

            const expected_after_c = [_][]const u8{
                "ity",
                "ars[1].mpg",
                "ars[0].mpg",
                "ars[1].model",
            };
            try checkCandidates(alloc, candidates_after_c, &expected_after_c);
        }

        // Test 3: After adding 'b'
        // Command: ".cb"
        try engine.add('b');
        {
            const candidates_after_b = try engine.get_candidate_idx(engine.command.items.len, 4);
            defer free_candidates(engine.alloc, candidates_after_b);

            // std.debug.print("\nCandidates after '.cb': (command: '{s}', idx: {d})\n", .{ engine.get_command(), engine.command.items.len });
            for (candidates_after_b) |part| {
                std.debug.print("  Value: '{s}'\n", .{part.value});
            }

            const expected_after_b = [_][]const u8{}; // No paths start with ".cb"
            try checkCandidates(alloc, candidates_after_b, &expected_after_b);
        }
    }
}
