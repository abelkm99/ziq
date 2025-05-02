const std = @import("std");
const NodeMap = std.AutoHashMap(u8, *Node);

const Suggestion = struct {
    expires_at: i32 = -1,
    value: []const u8,
};

const Node = struct {
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

const Trie = struct {
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

    pub fn get_suggestions(alloc: std.mem.Allocator, node: *Node, current: *std.ArrayList(u8), result: *std.ArrayList(Suggestion)) !void {
        if (node.is_word) {
            try result.append(Suggestion{
                .value = try alloc.dupe(u8, current.items),
            });
        }
        var children_iter = node.children.keyIterator();
        while (children_iter.next()) |c| {
            try current.append(c.*);
            defer _ = current.pop();
            const next = node.children.get(c.*).?;
            try get_suggestions(alloc, next, current, result);
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
        "word",
        "work",
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
        var results = std.ArrayList(Suggestion).init(T.alloc);
        defer {
            for (results.items) |result| {
                T.alloc.free(result.value);
            }
            results.deinit();
        }
        try Trie.get_suggestions(T.alloc, T.root, &current, &results);
        for (results.items, 1..) |result, i| {
            std.debug.print("suggestion {d} -> {s}\n", .{ i, result.value });
        }
        try testing.expect(results.items.len == dictionary.len);
    }
    // test by starting from the dot node
    {
        const dot_node = T.root.children.get('.').?;
        var current = std.ArrayList(u8).init(T.alloc);
        defer current.deinit();
        var results = std.ArrayList(Suggestion).init(T.alloc);
        defer {
            for (results.items) |result| {
                T.alloc.free(result.value);
            }
            results.deinit();
        }
        try Trie.get_suggestions(T.alloc, dot_node, &current, &results);
        try testing.expect(results.items.len == 1);
        try testing.expect(std.mem.eql(u8, results.items[0].value, "name "));
    }
}
