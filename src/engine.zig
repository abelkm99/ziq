const testing = std.testing;

const utitls = @import("utils.zig");
const Candidate = @import("trie.zig").Candidate;
const Node = @import("trie.zig").Node;

const std = @import("std");
// some sort of majic gpt generated
const OldQuery =
    \\ tostream | select(length==2) | .[0] | map(if type=="number" then "["+tostring+"]" else "."+tostring end) | join("")
;

// FIX: make the length dynamic with `paths | select(length <= n)` so it can handle larger inputs n == 0 means disbale suggestion
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

pub const JQEngine = struct {
    /// current implementation doesn't support suggestions for json keys that has `|` inside
    /// and are treated as pipes instead.
    const This = @This();
    alloc: std.mem.Allocator,
    query: std.ArrayList(u8),
    commands: std.ArrayList(Command),
    root: *Node,
    json_input: *[]const u8,
    root_nodes: std.ArrayList(*Node),

    pub fn init(alloc: std.mem.Allocator, json: *[]const u8) JQEngine {
        return JQEngine{
            .alloc = alloc,
            .query = std.ArrayList(u8).init(alloc),
            .commands = std.ArrayList(Command).init(alloc),
            .root = Node.new_node(alloc) catch unreachable,
            .json_input = json,
            .root_nodes = std.ArrayList(*Node).init(alloc),
        };
    }

    pub fn deinit(self: *This) void {
        self.query.deinit();
        for (self.commands.items) |*command| {
            command.deinit(self.alloc);
        }
        self.commands.deinit();
        if (self.commands.items.len == 0) {
            self.root.deinit(self.alloc); // this is a roll back function that if the the root node is deinited by the command iterator
            // it has to be deinited manuall.
        }
        for (self.root_nodes.items) |node| {
            Node.deinit(node, self.alloc);
        }
        self.root_nodes.deinit();
    }

    /// parse cadidate buffer and populate the trie into the Node
    pub fn parseAndPopulateCandidates(alloc: std.mem.Allocator, node: *Node, candidates_buffer: []const u8) !void {

        // remove the sepratator
        // might move it to util's
        const ln = std.mem.replacementSize(u8, candidates_buffer, "\\u001f", "");
        var clean_stdout = try alloc.alloc(u8, ln);
        defer alloc.free(clean_stdout);
        _ = std.mem.replace(u8, candidates_buffer, "\\u001f", "", clean_stdout[0..]);

        var it = std.mem.splitSequence(u8, clean_stdout, "\n");
        while (it.next()) |part| {
            if (part.len > 0) {
                const start_node = try Node.gerOrCreateNode(alloc, node, part[1..1]);
                try Node.insert(alloc, start_node, part[1 .. part.len - 1]);
            }
        }
    }

    /// This function generate all possible candidates and generates a trie node
    /// generate_candidate is called once for one segment of the command
    /// one segment of command is a jq command that is separated by | character
    /// i.e jq '.user' | '.name'  this example will be two segments
    pub fn generateCandidates(self: *This, node: *Node, idx: usize, input_buffer: []const u8) !void {
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
    }

    pub fn get_candidate_idx(self: *This, idx: usize, n: usize) ![]Candidate {
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

    pub fn add(self: *This, ch: u8) !void {
        // push it to the last item
        try self.insert(ch, self.query.items.len);
    }

    pub fn updateCandidatesForIdx(self: *This, idx: usize, input_buffer: []const u8) !Command {
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
            try self.generateCandidates(new_node, idx - 1, input_buffer);
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
                .is_root_node = false,
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

    pub fn insert(self: *This, ch: u8, idx: usize) !void {
        try self.query.insert(idx, ch);
    }

    pub fn get_command(self: *This) []u8 {
        return self.query.items;
    }

    pub fn pop_back(self: *This) !void {
        try self.pop_idx(self.query.items.len - 1);
    }
    pub fn pop_idx(self: *This, idx: usize) !void {
        if (idx >= self.query.items.len) {
            // ignore pop if list already empty
            return;
        }
        const ln = self.query.items.len;

        if (idx < self.query.items.len) {
            std.mem.copyForwards(u8, self.query.items[idx .. ln - 1], self.query.items[idx + 1 ..]);
            _ = self.query.pop();
        }
        if (idx < self.commands.items.len) {
            const tangling_command = self.commands.items[idx];
            std.mem.copyForwards(Command, self.commands.items[idx .. ln - 1], self.commands.items[idx + 1 ..]);
            // only deinit when it's not tangling window is a root node and is not the first root node since we are using that for other usecases
            if (idx > 0 and tangling_command.is_root_node) {
                try self.root_nodes.append(tangling_command.sroot_node);
                // Node.deinit(tangling_command.sroot_node, self.alloc);
            }
            _ = self.commands.pop();
        }
    }

    pub fn recalc(self: *This, idx: usize, input_buffer: []const u8) !void {
        for (idx..self.query.items.len) |i| {
            const command = try self.updateCandidatesForIdx(i, input_buffer);
            if (i < self.commands.items.len) {
                // if it's root node
                if (self.commands.items[i].is_root_node and i != 0) {
                    try self.root_nodes.append(self.commands.items[i].sroot_node);
                    // self.commands.items[i].deinit(self.alloc); // free the previous node. why exclude zero
                    // for index zero i want to free it at the end. (just a small optimization)
                }
                self.commands.items[i] = command;
            } else {
                try self.commands.append(command);
            }
        }
    }
};

pub fn free_candidates(alloc: std.mem.Allocator, candidates: []Candidate) void {
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

        try engine.add('.');
        try engine.recalc(0, json);
        {
            const candidates_after_dot = try engine.get_candidate_idx(0, 5);
            defer free_candidates(engine.alloc, candidates_after_dot);

            const expected_after_dot = [_][]const u8{
                "age",
                "name",
                "cars",
                "city",
                "cars.[1]",
            };
            try checkCandidates(alloc, candidates_after_dot, &expected_after_dot);
        }

        try engine.add('c');
        try engine.recalc(1, json);
        {
            const candidates_after_c = try engine.get_candidate_idx(1, 5); // idx=1 refers to 'c'
            defer free_candidates(engine.alloc, candidates_after_c);

            const expected_after_c = [_][]const u8{
                "ars",
                "ity",
                "ars.[1]",
                "ars.[0]",
                "ars.[1].mpg",
            };
            try checkCandidates(alloc, candidates_after_c, &expected_after_c);
        }

        for ("ars | .") |ch| {
            try engine.add(ch);
        }
        try engine.recalc(1, json);

        {
            const candidates_after_second_dot = try engine.get_candidate_idx(engine.query.items.len - 1, 4);
            defer free_candidates(engine.alloc, candidates_after_second_dot);

            const expected_after_second_dot = [_][]const u8{
                "[1]",
                "[0]",
                "[1].mpg",
                "[0].mpg",
            };
            try checkCandidates(alloc, candidates_after_second_dot, &expected_after_second_dot);
        }
    }
}

test "insert a node in the middle" {
    const alloc = testing.allocator;
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

    {
        var engine = JQEngine.init(alloc, &json);
        defer engine.deinit();
        try engine.generateCandidates(engine.root, 0, engine.json_input.*);
        const input = " tostring | fromjson | .ar";
        for (input) |ch| {
            try engine.add(ch);
        }
        try engine.recalc(0, json);
        var candidates = try engine.get_candidate_idx(input.len - 1, 5);
        _ = &candidates;
        defer free_candidates(alloc, candidates);

        try checkCandidates(alloc, candidates, &[_][]const u8{});
        // now insert at position 24 (after . the value of c)
        try engine.insert('c', 24);

        try engine.recalc(24, json);
        free_candidates(alloc, candidates); // free the previous ones

        candidates = try engine.get_candidate_idx(engine.query.items.len - 1, 5);
        var expected_candidates = [_][]const u8{
            "s",
            "s.[1]",
            "s.[0]",
            "s.[1].mpg",
            "s.[0].mpg",
        };
        try checkCandidates(alloc, candidates, &expected_candidates);

        for ("| .") |ch| {
            try engine.insert(ch, 0);
        }
        free_candidates(alloc, candidates); // free the previous ones
        try engine.recalc(0, json);
        candidates = try engine.get_candidate_idx(engine.query.items.len - 1, 5);
        try checkCandidates(alloc, candidates, &expected_candidates);
    }
    {
        var engine = JQEngine.init(alloc, &json);
        defer engine.deinit();
        try engine.generateCandidates(engine.root, 0, engine.json_input.*);
        const input = " | .";
        for (input) |ch| {
            try engine.add(ch);
        }
        try engine.insert('.', 0);
        try engine.recalc(0, json);
        var candidates = try engine.get_candidate_idx(engine.query.items.len - 1, 5);
        _ = &candidates;
        var expected_candidates = [_][]const u8{
            "age",
            "name",
            "cars",
            "city",
            "cars.[1]",
        };

        defer free_candidates(alloc, candidates);
        try checkCandidates(alloc, candidates, &expected_candidates);
    }
}

test "pop item from the end" {
    const alloc = testing.allocator;
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
    {
        var engine = JQEngine.init(alloc, &json);
        defer engine.deinit();
        try engine.generateCandidates(engine.root, 0, engine.json_input.*);
        const input = ".cbe";
        for (input, 0..) |ch, i| {
            try engine.add(ch);
            try engine.recalc(i, json);
        }

        var candidates = try engine.get_candidate_idx(input.len - 1, 5);
        _ = &candidates;
        defer free_candidates(alloc, candidates);

        try engine.pop_back();
        try engine.recalc(engine.get_command().len - 1, json);
        try engine.pop_back();
        try engine.recalc(engine.get_command().len - 1, json);

        // pop and check

        var expected_values = [_][]const u8{
            "ars",
            "ity",
            "ars.[1]",
            "ars.[0]",
            "ars.[1].mpg",
        };

        free_candidates(alloc, candidates); // free the previous ones
        candidates = try engine.get_candidate_idx(engine.query.items.len - 1, 5);

        try checkCandidates(alloc, candidates, &expected_values);
    }
    {
        var engine = JQEngine.init(alloc, &json);
        defer engine.deinit();
        try engine.generateCandidates(engine.root, 0, engine.json_input.*);
        const input = "dars";
        for (input, 0..) |ch, i| {
            try engine.add(ch);
            try engine.recalc(i, json);
        }

        var candidates = try engine.get_candidate_idx(engine.get_command().len, 5);
        _ = &candidates;
        defer free_candidates(alloc, candidates);
        try checkCandidates(alloc, candidates, &[_][]const u8{});

        try engine.pop_idx(0);
        try engine.insert('c', 0);
        try engine.recalc(0, json);
        try engine.insert('.', 0);
        try engine.recalc(0, json);

        free_candidates(alloc, candidates);
        candidates = try engine.get_candidate_idx(engine.get_command().len - 1, 5);

        var expected_values = [_][]const u8{
            ".[1]",
            ".[0]",
            ".[1].mpg",
            ".[0].mpg",
            ".[1].model",
        };
        try checkCandidates(alloc, candidates, &expected_values);
    }
    // test with pop a segment node and see how it's going to to react
    {
        var engine = JQEngine.init(alloc, &json);
        defer engine.deinit();
        try engine.generateCandidates(engine.root, 0, engine.json_input.*);
        const input = ".cars | .[0]";
        for (input, 0..) |ch, i| {
            try engine.add(ch);
            try engine.recalc(i, json);
        }

        try engine.pop_idx(5);
        try engine.recalc(5, json);
        try engine.pop_idx(5);
        try engine.recalc(5, json);
        try engine.pop_idx(5);
        try engine.recalc(5, json);

        var candidates = try engine.get_candidate_idx(engine.get_command().len - 1, 100);
        _ = &candidates;
        defer free_candidates(alloc, candidates);

        var expected_candidate = [_][]const u8{
            ".mpg",
            ".model",
        };

        try checkCandidates(alloc, candidates, &expected_candidate);

        // pop everything
        for (0..engine.get_command().len) |_| {
            try engine.pop_back();
            if (engine.get_command().len > 0) {
                try engine.recalc(engine.get_command().len - 1, json);
            }
        }
        for (".nam") |ch| {
            try engine.add(ch);
            try engine.recalc(engine.get_command().len - 1, json);
        }
        free_candidates(alloc, candidates);
        candidates = try engine.get_candidate_idx(engine.get_command().len - 1, 100);
        try checkCandidates(alloc, candidates, &[_][]const u8{"e"});
    }
}
