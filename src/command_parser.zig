const testing = std.testing;

const utitls = @import("utils.zig");
const Candidate = @import("trie.zig").Candidate;
const Node = @import("trie.zig").Node;

const std = @import("std");
// some sort of majic gpt generated
const OldQuery =
    \\ tostream | select(length==2) | .[0] | map(if type=="number" then "["+tostring+"]" else "."+tostring end) | join("")
;

// TODO: make the length dynamic with `paths | select(length <= n)` so it can handle larger inputs n == 0 means disbale suggestion
const Query =
    \\ paths | map(if type=="number" then ".[\(. )]" elif test("^[A-Za-z_][A-Za-z0-9_]*$") then ".\(.)" else ".\(@json)" end) | join("\u001F")
;

const SuggestError = error{
    InvalidIndex,
    InvalidCommand,
};

const Command = struct {
    is_root_node: bool = false,
    prev_node: ?*Node, // is null if it's a new node
    current_node: ?*Node,
    sroot_node: *Node, //segment root node.

    fn deinit(self: *Command, alloc: std.mem.Allocator) void {
        if (self.is_root_node) {
            self.sroot_node.deinit(alloc);
        }
    }
};

const JQEngine = struct {
    /// current implementation doesn't support suggestions for json keys that has `|` inside
    /// and are treated as pipes instead.
    const This = @This();
    alloc: std.mem.Allocator,
    query: std.ArrayList(u8),
    commands: std.ArrayList(Command),
    root: *Node,
    json_input: *[]const u8,

    fn init(alloc: std.mem.Allocator, json: *[]const u8) JQEngine {
        return JQEngine{
            .alloc = alloc,
            .query = std.ArrayList(u8).init(alloc),
            .commands = std.ArrayList(Command).init(alloc),
            .root = Node.new_node(alloc) catch unreachable,
            .json_input = json,
        };
    }

    fn deinit(self: *This) void {
        std.debug.print("got {d} elemnts\n", .{self.commands.items.len});
        self.query.deinit();
        for (self.commands.items) |*command| {
            command.deinit(self.alloc);
        }
        self.commands.deinit();
        if (self.commands.items.len == 0) {
            self.root.deinit(self.alloc); // this is a roll back function that if the the root node is deinited by the command iterator
            // it has to be deinited manuall.
        }
    }

    /// parse cadidate buffer and populate the trie into the Node
    fn parseAndPopulateCandidates(alloc: std.mem.Allocator, node: *Node, candidates_buffer: []const u8) !void {

        // remove the sepratator
        // might move it to util's or not

        const ln = std.mem.replacementSize(u8, candidates_buffer, "\\u001f", "");
        var clean_stdout = try alloc.alloc(u8, ln);
        defer alloc.free(clean_stdout);
        _ = std.mem.replace(u8, candidates_buffer, "\\u001f", "", clean_stdout[0..]);

        var candidates = std.ArrayList([]const u8).init(alloc);
        defer candidates.deinit();
        var it = std.mem.splitSequence(u8, clean_stdout, "\n");
        while (it.next()) |part| {
            if (part.len > 0) {
                const start_node = try Node.gerOrCreateNode(alloc, node, part[1..1]);
                try Node.insert(alloc, start_node, part[1 .. part.len - 1]);
            }
        }
    }

    /// This function generate all possibel candidates and generates a trie node
    /// generate_candidate is called once for one segment of the command
    /// one segment of command is a jq command that is separated by | character
    /// i.e jq '.user' | '.name'  this example will be two segments
    fn generateCandidates(self: *This, node: *Node, idx: usize, input_buffer: []const u8) !void {
        var new_query: []u8 = &[_]u8{};
        defer self.alloc.free(new_query);

        // if the command is empty just pass the Query as JQ result.
        if (self.query.items.len == 0) {
            new_query = try std.fmt.allocPrint(self.alloc, "{s}", .{Query});
        } else {
            new_query = try std.fmt.allocPrint(self.alloc, "{s} | {s}", .{ self.query.items[0..idx], Query });
        }
        var jq_res = try utitls.handleJQ(self.alloc, new_query, input_buffer);
        defer jq_res.free(self.alloc);

        if (jq_res.status) {
            try parseAndPopulateCandidates(self.alloc, node, jq_res.std_out);
        }

        var current = std.ArrayList(u8).init(self.alloc);
        defer current.deinit();
        var result = std.ArrayList(Candidate).init(self.alloc);
        defer result.deinit();
    }

    fn get_candidate_idx(self: *This, idx: usize, n: usize) ![]Candidate {
        if (idx < self.commands.items.len) {
            if (self.commands.items[idx].current_node) |node| {
                var result = std.ArrayList(Candidate).init(self.alloc);
                defer result.deinit();
                try Node.getCandidatesBFS(self.alloc, node, &result, n);

                return try result.toOwnedSlice();
            }
        }
        return &[_]Candidate{};
    }

    fn add(self: *This, ch: u8) !void {
        // push it to the last item
        try self.insert(ch, self.query.items.len);
    }

    fn updateCandidatesForIdx(self: *This, idx: usize) !Command {
        if (idx >= self.query.items.len) {
            return error.InvalidIndex;
        }
        const ch = self.query.items[idx];

        if (idx == 0) {
            return .{
                // regardless
                .is_root_node = true,
                .prev_node = null,
                .current_node = self.root.children.get(ch),
                .sroot_node = self.root,
            };
        }
        // if it's a pipe means i need to do calculations
        if (ch == '|') {
            const new_node = try Node.new_node(self.alloc);
            try self.generateCandidates(new_node, idx - 1, self.json_input.*);
            return .{
                .is_root_node = true,
                .prev_node = null,
                .current_node = new_node,
                .sroot_node = new_node,
            };
        }
        // if ch == "." -> and prev_node is null start giving suggestion.
        const s_root_node = self.commands.items[idx - 1].sroot_node;
        if (ch == '.' and self.commands.items[idx - 1].current_node == null) {
            // start from the current segment root node
            return .{
                .is_root_node = true,
                .prev_node = null,
                .current_node = s_root_node.children.get(ch),
                .sroot_node = s_root_node,
            };
        }

        const prev_node = self.commands.items[idx - 1].current_node;
        const current_node = if (prev_node == null) null else prev_node.?.children.get(ch);
        return .{
            .is_root_node = false,
            .prev_node = prev_node,
            .current_node = current_node,
            .sroot_node = s_root_node,
        };
    }

    fn insert(self: *This, ch: u8, idx: usize) !void {
        // increase the capacity regardless
        try self.query.insert(idx, ch);
        try self.recalc(idx);
    }

    fn get_command(self: *This) []u8 {
        return self.query.items;
    }

    fn recalc(self: *This, idx: usize) !void {
        for (idx..self.query.items.len) |i| {
            const command = try self.updateCandidatesForIdx(i);
            if (i < self.commands.items.len) {
                self.commands.items[i] = command;
            } else {
                try self.commands.append(command);
            }
        }
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
        var json: []const u8 =
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

        var engine = JQEngine.init(alloc, &json);
        defer engine.deinit();
        try engine.generateCandidates(engine.root, 0, engine.json_input.*);

        // Command: "."
        try engine.add('.');
        {
            const candidates_after_dot = try engine.get_candidate_idx(0, 5);
            defer free_candidates(engine.alloc, candidates_after_dot);

            // std.debug.print("\nCandidates after '.': (command: '{s}', idx: 0)\n", .{engine.get_command()});
            // for (candidates_after_dot) |part| {
            //     std.debug.print("  Value: '{s}'\n", .{part.value});
            // }

            const expected_after_dot = [_][]const u8{
                "age",
                "name",
                "cars",
                "city",
                "cars.[1]",
            };
            try checkCandidates(alloc, candidates_after_dot, &expected_after_dot);
        }

        // Test 2: After adding 'c'
        // Command: ".c"
        try engine.add('c');
        {
            const candidates_after_c = try engine.get_candidate_idx(1, 5); // idx=1 refers to 'c'
            defer free_candidates(engine.alloc, candidates_after_c);

            // std.debug.print("\nCandidates after '.c': (command: '{s}', idx: 1)\n", .{engine.get_command()});
            // for (candidates_after_c) |part| {
            //     std.debug.print("  Value: '{s}'\n", .{part.value});
            // }

            const expected_after_c = [_][]const u8{
                "ars",
                "ity",
                "ars.[1]",
                "ars.[0]",
                "ars.[1].mpg",
            };
            try checkCandidates(alloc, candidates_after_c, &expected_after_c);
        }

        // Test 3: After adding 'b'
        // Command: ".cb"
        try engine.add('b');
        {
            const candidates_after_b = try engine.get_candidate_idx(engine.query.items.len, 4);
            defer free_candidates(engine.alloc, candidates_after_b);

            // std.debug.print("\nCandidates after '.cb': (command: '{s}', idx: {d})\n", .{ engine.get_command(), engine.command.items.len });
            for (candidates_after_b) |part| {
                std.debug.print("  Value: '{s}'\n", .{part.value});
            }

            const expected_after_b = [_][]const u8{}; // No paths start with ".cb"
            try checkCandidates(alloc, candidates_after_b, &expected_after_b);
        }

        // pop cases
        //
        //
        //
        // insert in the middle cases and many others
    }
}
