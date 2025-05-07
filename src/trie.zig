const std = @import("std");
const queue = @import("queue.zig");
const NodeMap = std.AutoHashMap(u8, *Node);

pub const Candidate = struct {
    value: []const u8,
};

pub const Node = struct {
    const Self = @This();
    is_word: bool = false,
    // Use size 256 to accommodate all possible u8 values
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
};

pub const Trie = struct {
    const Self = @This();
    alloc: std.mem.Allocator,
    root: *Node,

    pub fn init(alloc: std.mem.Allocator) !Self {
        const root_node = try Node.new_node(alloc);
        return Self{
            .alloc = alloc,
            .root = root_node,
        };
    }

    pub fn insert(self: *Self, word: []const u8) !void {
        var current: *Node = self.root;
        for (word) |c| {
            if (current.children.get(c) == null) {
                try current.children.put(c, try Node.new_node(self.alloc));
            }
            current = current.children.get(c).?;
        }
        current.is_word = true;
    }

    /// if word is empty, return the root node
    pub fn gerOrCreateNode(self: *Self, word: []const u8) !*Node {
        var current: *Node = self.root;
        for (word) |c| {
            if (current.children.get(c) == null) {
                try current.children.put(c, try Node.new_node(self.alloc));
            }
            current = current.children.get(c).?;
        }
        return current;
    }

    pub fn insertWithNode(self: *Self, node: *Node, word: []const u8) !void {
        var current: *Node = node;
        for (word) |c| {
            if (current.children.get(c) == null) {
                try current.children.put(c, try Node.new_node(self.alloc));
            }
            current = current.children.get(c).?;
        }
        current.is_word = true;
    }

    pub fn lookup(self: *Self, word: []const u8) bool {
        var current: *Node = self.root;
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
        self: *Self,
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
                .value = try self.alloc.dupe(u8, current.items),
            });
        }
        var children_iter = node.children.keyIterator();
        while (children_iter.next()) |c| {
            try current.append(c.*);
            defer _ = current.pop();
            const next = node.children.get(c.*).?;
            try self.getCandidates(next, current, result, n);
        }
    }

    pub fn getCandidatesBFS(
        self: *Self,
        node: *Node,
        result: *std.ArrayList(Candidate),
        n: usize,
    ) !void {
        const QTuple = struct {
            node: *Node,
            value: std.ArrayList(u8),
        };

        var Q: queue.Deque(QTuple) = try .init(self.alloc);
        defer {
            while (Q.popFront()) |current| {
                current.value.deinit();
            }
            Q.deinit();
        }
        try Q.pushBack(QTuple{
            .node = node,
            .value = std.ArrayList(u8).init(self.alloc),
        });
        while (result.items.len < n and Q.len() > 0) {
            var current: QTuple = Q.popFront().?;
            defer current.value.deinit();

            if (current.node.is_word) {
                try result.append(.{ .value = try self.alloc.dupe(u8, current.value.items) });
            }

            var children_iter = current.node.children.keyIterator();

            while (children_iter.next()) |c| {
                try current.value.append(c.*);
                defer _ = current.value.pop();
                var _tmp = std.ArrayList(u8).init(self.alloc);
                try _tmp.appendSlice(current.value.items);
                const nxt = QTuple{
                    .node = current.node.children.get(c.*).?,
                    .value = _tmp,
                };
                try Q.pushBack(nxt);
            }
        }
    }

    pub fn deinit(self: *Self) void {
        self.root.deinit(self.alloc);
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

    var T = try Trie.init(allocator);
    for (dictionary) |word| {
        try T.insert(word);
    }

    try testing.expect(T.lookup("word"));
    try testing.expect(T.lookup("work"));
    try testing.expect(T.lookup(".name "));
    try testing.expect(!T.lookup(".name"));

    defer T.deinit();
}

test "Test get all possible suggestions" {
    const testing = std.testing;
    const dictionary = [_][]const u8{
        "wor",
        "word",
        ".name ",
    };

    const allocator = testing.allocator;

    var T = try Trie.init(allocator);
    defer T.deinit();
    for (dictionary) |word| {
        try T.insert(word);
    }

    {
        var current = std.ArrayList(u8).init(T.alloc);
        defer current.deinit();
        var results = std.ArrayList(Candidate).init(T.alloc);
        defer {
            for (results.items) |result| {
                T.alloc.free(result.value);
            }
            results.deinit();
        }
        try T.getCandidates(T.root, &current, &results, std.math.maxInt(usize));
        try testing.expect(results.items.len == dictionary.len);
    }
    // test by starting from the dot node
    {
        const dot_node = T.root.children.get('.').?;
        var current = std.ArrayList(u8).init(T.alloc);
        defer current.deinit();
        var results = std.ArrayList(Candidate).init(T.alloc);
        defer {
            for (results.items) |result| {
                T.alloc.free(result.value);
            }
            results.deinit();
        }
        try T.getCandidates(dot_node, &current, &results, std.math.maxInt(usize));
        try testing.expect(results.items.len == 1);
        try testing.expect(std.mem.eql(u8, results.items[0].value, "name "));
    }
    {
        var results = std.ArrayList(Candidate).init(T.alloc);
        defer {
            for (results.items) |result| {
                T.alloc.free(result.value);
            }
            results.deinit();
        }
        try T.getCandidatesBFS(T.root, &results, 2);
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
        var T = try Trie.init(allocator);
        defer T.deinit();

        for (dictionary) |word| {
            try T.insertWithNode(T.root, word);
        }
        for (dictionary) |word| {
            try testing.expect(T.lookup(word));
        }

        const _dot_node = T.root.children.get('.').?;
        try T.insertWithNode(_dot_node, "n");

        try testing.expect(T.lookup(".n"));
        try testing.expect(!T.lookup(".n "));
        var current = std.ArrayList(u8).init(T.alloc);
        defer current.deinit();
        var candidates = std.ArrayList(Candidate).init(T.alloc);
        defer {
            for (candidates.items) |result| {
                T.alloc.free(result.value);
            }
            candidates.deinit();
        }
        try T.getCandidates(try T.gerOrCreateNode(".n"), &current, &candidates, std.math.maxInt(usize));
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
    var T = try Trie.init(allocator);
    defer T.deinit();
    const _dot_node = try T.gerOrCreateNode(".");
    try testing.expect(_dot_node.is_word == false);
    for (dictionary) |word| {
        try T.insertWithNode(_dot_node, word);
    }

    var current = std.ArrayList(u8).init(T.alloc);
    defer current.deinit();
    var candidates = std.ArrayList(Candidate).init(T.alloc);
    defer {
        for (candidates.items) |result| {
            T.alloc.free(result.value);
        }
        candidates.deinit();
    }
    try T.getCandidates(try T.gerOrCreateNode("."), &current, &candidates, std.math.maxInt(usize));
    try testing.expect(candidates.items.len == 3);
}
