const std = @import("std");
const queue = @import("queue.zig");
const NodeMap = std.AutoHashMap(u8, *Node);

pub const Candidate = struct {
    value: []const u8,
};

pub const Node = struct {
    const Self = @This();
    is_word: bool = false,
    children: NodeMap,

    pub fn new_node(alloc: std.mem.Allocator) !*Node {
        const node = try alloc.create(Node);
        node.children = NodeMap.init(alloc);
        return node;
    }

    pub fn deinit(self: *Node, alloc: std.mem.Allocator) void {
        var it = self.children.valueIterator();
        while (it.next()) |child| {
            child.*.deinit(alloc);
        }
        self.children.deinit(); // deinit the map
        alloc.destroy(self); // free the node
    }

    pub fn insert(alloc: std.mem.Allocator, node: *Node, word: []const u8) !void {
        var current: *Node = node;
        for (word) |c| {
            if (current.children.get(c) == null) {
                try current.children.put(c, try Node.new_node(alloc));
            }
            current = current.children.get(c).?;
        }
        current.is_word = true;
    }

    /// if word is empty, return the root node
    pub fn gerOrCreateNode(alloc: std.mem.Allocator, node: *Node, word: []const u8) !*Node {
        var current: *Node = node;
        for (word) |c| {
            if (current.children.get(c) == null) {
                try current.children.put(c, try Node.new_node(alloc));
            }
            current = current.children.get(c).?;
        }
        return current;
    }

    pub fn insertWithNode(alloc: std.mem.Allocator, node: *Node, word: []const u8) !void {
        var current: *Node = node;
        for (word) |c| {
            if (current.children.get(c) == null) {
                try current.children.put(c, try Node.new_node(alloc));
            }
            current = current.children.get(c).?;
        }
        current.is_word = true;
    }

    pub fn lookup(node: *Node, word: []const u8) bool {
        var current: *Node = node;
        for (word) |c| {
            if (current.children.get(c)) |next| {
                current = next;
            } else {
                return false;
            }
        }
        return current.is_word;
    }

    pub fn getCandidates(
        alloc: std.mem.Allocator,
        node: *Node,
        current: *std.ArrayList(u8),
        result: *std.ArrayList(Candidate),
        n: usize,
    ) !void {
        if (result.items.len == n) {
            return;
        }
        if (node.is_word) {
            try result.append(Candidate{
                .value = try alloc.dupe(u8, current.items),
            });
        }
        var children_iter = node.children.keyIterator();
        while (children_iter.next()) |c| {
            try current.append(c.*);
            defer _ = current.pop();
            const next = node.children.get(c.*).?;
            try Node.getCandidates(alloc, next, current, result, n);
        }
    }

    pub fn getCandidatesBFS(
        alloc: std.mem.Allocator,
        node: *Node,
        result: *std.ArrayList(Candidate),
        n: usize,
    ) !void {
        const QTuple = struct {
            node: *Node,
            value: std.ArrayList(u8),
        };

        var Q: queue.Deque(QTuple) = try .init(alloc);
        defer {
            while (Q.popFront()) |current| {
                current.value.deinit();
            }
            Q.deinit();
        }
        try Q.pushBack(QTuple{
            .node = node,
            .value = std.ArrayList(u8).init(alloc),
        });
        while (result.items.len < n and Q.len() > 0) {
            var current: QTuple = Q.popFront().?;
            defer current.value.deinit();

            if (current.node.is_word) {
                try result.append(.{ .value = try alloc.dupe(u8, current.value.items) });
            }

            var children_iter = current.node.children.keyIterator();

            while (children_iter.next()) |c| {
                try current.value.append(c.*);
                defer _ = current.value.pop();
                var _tmp = std.ArrayList(u8).init(alloc);
                try _tmp.appendSlice(current.value.items);
                const nxt = QTuple{
                    .node = current.node.children.get(c.*).?,
                    .value = _tmp,
                };
                try Q.pushBack(nxt);
            }
        }
    }
};

test "Trie insert and check" {
    const testing = std.testing;
    const dictionary = [_][]const u8{
        "word",
        "work",
        ".name ",
    };

    _ = &dictionary;
    const allocator = testing.allocator;

    const root_node = try Node.new_node(allocator);
    defer root_node.deinit(allocator);

    for (dictionary) |word| {
        try Node.insert(allocator, root_node, word);
    }

    try testing.expect(Node.lookup(root_node, "word"));
    try testing.expect(Node.lookup(root_node, "work"));
    try testing.expect(Node.lookup(root_node, ".name "));
    try testing.expect(!Node.lookup(root_node, ".name"));
}

test "Test get all possible suggestions" {
    const testing = std.testing;
    const dictionary = [_][]const u8{
        "wor",
        "word",
        ".name ",
    };

    const allocator = testing.allocator;

    const root_node = try Node.new_node(allocator);
    defer root_node.deinit(allocator);
    for (dictionary) |word| {
        try Node.insert(allocator, root_node, word);
    }

    {
        var current = std.ArrayList(u8).init(allocator);
        defer current.deinit();
        var results = std.ArrayList(Candidate).init(allocator);
        defer {
            for (results.items) |result| {
                allocator.free(result.value);
            }
            results.deinit();
        }
        try Node.getCandidates(allocator, root_node, &current, &results, std.math.maxInt(usize));
        try testing.expect(results.items.len == dictionary.len);
    }
    // test by starting from the dot node
    {
        const dot_node = root_node.children.get('.').?;
        var current = std.ArrayList(u8).init(allocator);
        defer current.deinit();
        var results = std.ArrayList(Candidate).init(allocator);
        defer {
            for (results.items) |result| {
                allocator.free(result.value);
            }
            results.deinit();
        }
        try Node.getCandidates(allocator, dot_node, &current, &results, std.math.maxInt(usize));
        try testing.expect(results.items.len == 1);
        try testing.expect(std.mem.eql(u8, results.items[0].value, "name "));
    }
    {
        var results = std.ArrayList(Candidate).init(allocator);
        defer {
            for (results.items) |result| {
                allocator.free(result.value);
            }
            results.deinit();
        }
        try Node.getCandidatesBFS(allocator, root_node, &results, 2);
        try testing.expect(results.items.len == 2);
        try testing.expect(std.mem.eql(u8, results.items[0].value, "wor"));
        try testing.expect(std.mem.eql(u8, results.items[1].value, "word"));
    }
}
test "Test insert with Node" {
    const testing = std.testing;
    const dictionary = [_][]const u8{
        "word",
        "work",
        ".name ",
    };

    const allocator = testing.allocator;

    {
        const root_node = try Node.new_node(allocator);
        defer root_node.deinit(allocator);

        for (dictionary) |word| {
            try Node.insert(allocator, root_node, word);
        }
        for (dictionary) |word| {
            try testing.expect(Node.lookup(root_node, word));
        }

        const dot_node = root_node.children.get('.').?;
        try Node.insert(allocator, dot_node, "n");

        try testing.expect(Node.lookup(root_node, ".n"));
        try testing.expect(!Node.lookup(root_node, ".n "));
        var current = std.ArrayList(u8).init(allocator);
        defer current.deinit();
        var candidates = std.ArrayList(Candidate).init(allocator);
        defer {
            for (candidates.items) |result| {
                allocator.free(result.value);
            }
            candidates.deinit();
        }
        try Node.getCandidates(allocator, try Node.gerOrCreateNode(allocator, root_node, ".n"), &current, &candidates, std.math.maxInt(usize));
        try testing.expect(candidates.items.len == 2);
    }
}

test "Test getOrCreateNode" {
    const testing = std.testing;
    const dictionary = [_][]const u8{
        "word",
        "work",
        "name ",
    };
    const allocator = testing.allocator;
    const root_node = try Node.new_node(allocator);
    defer root_node.deinit(allocator);
    const _dot_node = try Node.gerOrCreateNode(allocator, root_node, ".");
    try testing.expect(_dot_node.is_word == false);
    for (dictionary) |word| {
        try Node.insert(allocator, _dot_node, word);
    }

    var current = std.ArrayList(u8).init(allocator);
    defer current.deinit();
    var candidates = std.ArrayList(Candidate).init(allocator);
    defer {
        for (candidates.items) |result| {
            allocator.free(result.value);
        }
        candidates.deinit();
    }
    try Node.getCandidates(allocator, try Node.gerOrCreateNode(allocator, root_node, "."), &current, &candidates, std.math.maxInt(usize));
    try testing.expect(candidates.items.len == 3);
}
