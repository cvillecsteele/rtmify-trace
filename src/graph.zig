const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const NodeType = enum {
    user_need,
    requirement,
    test_group,
    test_case,
    risk,

    pub fn fromString(s: []const u8) ?NodeType {
        if (std.mem.eql(u8, s, "UserNeed")) return .user_need;
        if (std.mem.eql(u8, s, "Requirement")) return .requirement;
        if (std.mem.eql(u8, s, "TestGroup")) return .test_group;
        if (std.mem.eql(u8, s, "Test")) return .test_case;
        if (std.mem.eql(u8, s, "Risk")) return .risk;
        return null;
    }

    pub fn toString(self: NodeType) []const u8 {
        return switch (self) {
            .user_need => "UserNeed",
            .requirement => "Requirement",
            .test_group => "TestGroup",
            .test_case => "Test",
            .risk => "Risk",
        };
    }
};

pub const EdgeLabel = enum {
    derives_from,
    tested_by,
    has_test,
    mitigated_by,

    pub fn fromString(s: []const u8) ?EdgeLabel {
        if (std.mem.eql(u8, s, "DERIVES_FROM")) return .derives_from;
        if (std.mem.eql(u8, s, "TESTED_BY")) return .tested_by;
        if (std.mem.eql(u8, s, "HAS_TEST")) return .has_test;
        if (std.mem.eql(u8, s, "MITIGATED_BY")) return .mitigated_by;
        return null;
    }

    pub fn toString(self: EdgeLabel) []const u8 {
        return switch (self) {
            .derives_from => "DERIVES_FROM",
            .tested_by => "TESTED_BY",
            .has_test => "HAS_TEST",
            .mitigated_by => "MITIGATED_BY",
        };
    }
};

/// A key-value property pair passed to addNode.
pub const Property = struct {
    key: []const u8,
    value: []const u8,
};

pub const Node = struct {
    id: []const u8,
    node_type: NodeType,
    properties: std.StringHashMapUnmanaged([]const u8),

    pub fn get(self: *const Node, key: []const u8) ?[]const u8 {
        return self.properties.get(key);
    }
};

pub const Edge = struct {
    from_id: []const u8,
    to_id: []const u8,
    label: EdgeLabel,
};

/// One row of the Requirements Traceability Matrix.
pub const RtmRow = struct {
    req_id: []const u8,
    statement: []const u8,
    status: []const u8,
    user_need_id: ?[]const u8,
    test_group_id: ?[]const u8,
    test_id: ?[]const u8,
    test_type: ?[]const u8,
    test_method: ?[]const u8,
};

/// One row of the Risk Register.
pub const RiskRow = struct {
    risk_id: []const u8,
    description: []const u8,
    initial_severity: ?[]const u8,
    initial_likelihood: ?[]const u8,
    mitigation: ?[]const u8,
    residual_severity: ?[]const u8,
    residual_likelihood: ?[]const u8,
    req_id: ?[]const u8,
};

// ---------------------------------------------------------------------------
// Graph
// ---------------------------------------------------------------------------

/// In-memory graph of nodes and edges. All memory is owned by an internal
/// ArenaAllocator; call deinit() to free everything at once.
///
/// Build the graph (addNode / addEdge), then query it (rtm, risks, etc.).
/// Do not hold node pointers across addNode calls — the internal HashMap
/// may resize and invalidate pointers. In practice, build first, then query.
pub const Graph = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.StringHashMapUnmanaged(*Node) = .{},
    edges: std.ArrayListUnmanaged(Edge) = .{},

    pub fn init(allocator: Allocator) Graph {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Graph) void {
        self.arena.deinit();
    }

    fn a(self: *Graph) Allocator {
        return self.arena.allocator();
    }

    // -----------------------------------------------------------------------
    // Mutation
    // -----------------------------------------------------------------------

    /// Add a node. Idempotent: a second call with the same id is a no-op.
    pub fn addNode(self: *Graph, id: []const u8, node_type: NodeType, props: []const Property) !void {
        if (self.nodes.contains(id)) return;
        const alloc = self.a();
        const node = try alloc.create(Node);
        node.* = .{
            .id = try alloc.dupe(u8, id),
            .node_type = node_type,
            .properties = .{},
        };
        for (props) |p| {
            try node.properties.put(alloc, try alloc.dupe(u8, p.key), try alloc.dupe(u8, p.value));
        }
        try self.nodes.put(alloc, node.id, node);
    }

    /// Add a directed edge. Idempotent: duplicate from/to/label is a no-op.
    pub fn addEdge(self: *Graph, from_id: []const u8, to_id: []const u8, label: EdgeLabel) !void {
        for (self.edges.items) |e| {
            if (e.label == label and
                std.mem.eql(u8, e.from_id, from_id) and
                std.mem.eql(u8, e.to_id, to_id)) return;
        }
        const alloc = self.a();
        try self.edges.append(alloc, .{
            .from_id = try alloc.dupe(u8, from_id),
            .to_id = try alloc.dupe(u8, to_id),
            .label = label,
        });
    }

    // -----------------------------------------------------------------------
    // Basic queries
    // -----------------------------------------------------------------------

    pub fn getNode(self: *const Graph, id: []const u8) ?*const Node {
        return self.nodes.get(id);
    }

    pub fn nodesByType(self: *const Graph, node_type: NodeType, alloc: Allocator, result: *std.ArrayList(*const Node)) !void {
        var it = self.nodes.valueIterator();
        while (it.next()) |ptr| {
            if (ptr.*.node_type == node_type) try result.append(alloc, ptr.*);
        }
    }

    pub fn edgesFrom(self: *const Graph, from_id: []const u8, alloc: Allocator, result: *std.ArrayList(Edge)) !void {
        for (self.edges.items) |e| {
            if (std.mem.eql(u8, e.from_id, from_id)) try result.append(alloc, e);
        }
    }

    pub fn edgesTo(self: *const Graph, to_id: []const u8, alloc: Allocator, result: *std.ArrayList(Edge)) !void {
        for (self.edges.items) |e| {
            if (std.mem.eql(u8, e.to_id, to_id)) try result.append(alloc, e);
        }
    }

    // -----------------------------------------------------------------------
    // Gap queries
    // -----------------------------------------------------------------------

    /// Returns all nodes of node_type that have no outgoing edge with label.
    pub fn nodesMissingEdge(
        self: *const Graph,
        node_type: NodeType,
        label: EdgeLabel,
        alloc: Allocator,
        result: *std.ArrayList(*const Node),
    ) !void {
        var it = self.nodes.valueIterator();
        while (it.next()) |ptr| {
            const node = ptr.*;
            if (node.node_type != node_type) continue;
            var has_edge = false;
            for (self.edges.items) |e| {
                if (e.label == label and std.mem.eql(u8, e.from_id, node.id)) {
                    has_edge = true;
                    break;
                }
            }
            if (!has_edge) try result.append(alloc, node);
        }
    }

    // -----------------------------------------------------------------------
    // Traversal
    // -----------------------------------------------------------------------

    /// BFS reachable from from_id following any outgoing edge, up to max_depth.
    /// Uses an internal arena for temporary state so the caller's allocator is
    /// not polluted with intermediary data.
    pub fn downstream(
        self: *const Graph,
        from_id: []const u8,
        max_depth: usize,
        alloc: Allocator,
        result: *std.ArrayList(*const Node),
    ) !void {
        var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer tmp_arena.deinit();
        const tmp = tmp_arena.allocator();

        var visited = std.StringHashMapUnmanaged(void){};
        // Pre-mark the start node so cycles back to it don't add it to results
        try visited.put(tmp, from_id, {});
        const QueueItem = struct { id: []const u8, depth: usize };
        var queue = std.ArrayListUnmanaged(QueueItem){};

        for (self.edges.items) |e| {
            if (std.mem.eql(u8, e.from_id, from_id)) {
                try queue.append(tmp, .{ .id = e.to_id, .depth = 1 });
            }
        }

        var qi: usize = 0;
        while (qi < queue.items.len) {
            const item = queue.items[qi];
            qi += 1;

            if (visited.contains(item.id)) continue;
            try visited.put(tmp, item.id, {});

            if (self.nodes.get(item.id)) |node| try result.append(alloc, node);
            if (item.depth >= max_depth) continue;

            for (self.edges.items) |e| {
                if (std.mem.eql(u8, e.from_id, item.id) and !visited.contains(e.to_id)) {
                    try queue.append(tmp, .{ .id = e.to_id, .depth = item.depth + 1 });
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Report queries
    // -----------------------------------------------------------------------

    /// Requirements Traceability Matrix. Each row is one (req, test) pair.
    /// A req with no test group yields one row with null test fields.
    /// A test group with N tests yields N rows for that req.
    pub fn rtm(self: *const Graph, alloc: Allocator, result: *std.ArrayList(RtmRow)) !void {
        var it = self.nodes.valueIterator();
        while (it.next()) |ptr| {
            const req = ptr.*;
            if (req.node_type != .requirement) continue;

            const statement = req.get("statement") orelse "";
            const status = req.get("status") orelse "";

            var user_need_id: ?[]const u8 = null;
            for (self.edges.items) |e| {
                if (e.label == .derives_from and std.mem.eql(u8, e.from_id, req.id)) {
                    user_need_id = e.to_id;
                    break;
                }
            }

            var test_group_id: ?[]const u8 = null;
            for (self.edges.items) |e| {
                if (e.label == .tested_by and std.mem.eql(u8, e.from_id, req.id)) {
                    test_group_id = e.to_id;
                    break;
                }
            }

            if (test_group_id == null) {
                try result.append(alloc, .{
                    .req_id = req.id,
                    .statement = statement,
                    .status = status,
                    .user_need_id = user_need_id,
                    .test_group_id = null,
                    .test_id = null,
                    .test_type = null,
                    .test_method = null,
                });
                continue;
            }

            var found_tests = false;
            for (self.edges.items) |e| {
                if (e.label == .has_test and std.mem.eql(u8, e.from_id, test_group_id.?)) {
                    found_tests = true;
                    const t = self.nodes.get(e.to_id);
                    try result.append(alloc, .{
                        .req_id = req.id,
                        .statement = statement,
                        .status = status,
                        .user_need_id = user_need_id,
                        .test_group_id = test_group_id,
                        .test_id = e.to_id,
                        .test_type = if (t) |n| n.get("test_type") else null,
                        .test_method = if (t) |n| n.get("test_method") else null,
                    });
                }
            }
            if (!found_tests) {
                try result.append(alloc, .{
                    .req_id = req.id,
                    .statement = statement,
                    .status = status,
                    .user_need_id = user_need_id,
                    .test_group_id = test_group_id,
                    .test_id = null,
                    .test_type = null,
                    .test_method = null,
                });
            }
        }
    }

    /// Risk Register: each Risk node with its linked Requirement (if any).
    pub fn risks(self: *const Graph, alloc: Allocator, result: *std.ArrayList(RiskRow)) !void {
        var it = self.nodes.valueIterator();
        while (it.next()) |ptr| {
            const risk = ptr.*;
            if (risk.node_type != .risk) continue;

            var req_id: ?[]const u8 = null;
            for (self.edges.items) |e| {
                if (e.label == .mitigated_by and std.mem.eql(u8, e.from_id, risk.id)) {
                    req_id = e.to_id;
                    break;
                }
            }

            try result.append(alloc, .{
                .risk_id = risk.id,
                .description = risk.get("description") orelse "",
                .initial_severity = risk.get("initial_severity"),
                .initial_likelihood = risk.get("initial_likelihood"),
                .mitigation = risk.get("mitigation"),
                .residual_severity = risk.get("residual_severity"),
                .residual_likelihood = risk.get("residual_likelihood"),
                .req_id = req_id,
            });
        }
    }
};

// ---------------------------------------------------------------------------
// Tests (translated from live/tests/test_graph.py)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn hasId(nodes: []const *const Node, id: []const u8) bool {
    for (nodes) |n| if (std.mem.eql(u8, n.id, id)) return true;
    return false;
}

test "addNode and getNode" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system SHALL detect loss of GPS" },
    });
    const node = g.getNode("REQ-001");
    try testing.expect(node != null);
    try testing.expectEqualStrings("REQ-001", node.?.id);
    try testing.expectEqual(NodeType.requirement, node.?.node_type);
    try testing.expectEqualStrings("The system SHALL detect loss of GPS", node.?.get("statement").?);
}

test "addNode idempotent" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{.{ .key = "statement", .value = "first" }});
    try g.addNode("REQ-001", .requirement, &.{.{ .key = "statement", .value = "second" }});
    const node = g.getNode("REQ-001");
    try testing.expectEqualStrings("first", node.?.get("statement").?);
}

test "getNode missing returns null" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try testing.expect(g.getNode("DOES-NOT-EXIST") == null);
}

test "addEdge idempotent" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addNode("TG-001", .test_group, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(testing.allocator);
    try g.edgesFrom("REQ-001", testing.allocator, &edges);
    try testing.expectEqual(1, edges.items.len);
    try testing.expectEqual(EdgeLabel.tested_by, edges.items[0].label);
}

test "nodesByType" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addNode("REQ-002", .requirement, &.{});
    try g.addNode("UN-001", .user_need, &.{});
    var reqs: std.ArrayList(*const Node) = .empty;
    defer reqs.deinit(testing.allocator);
    try g.nodesByType(.requirement, testing.allocator, &reqs);
    try testing.expectEqual(2, reqs.items.len);
}

test "nodesMissingEdge" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addNode("REQ-002", .requirement, &.{});
    try g.addNode("TG-001", .test_group, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    var gaps: std.ArrayList(*const Node) = .empty;
    defer gaps.deinit(testing.allocator);
    try g.nodesMissingEdge(.requirement, .tested_by, testing.allocator, &gaps);
    try testing.expectEqual(1, gaps.items.len);
    try testing.expectEqualStrings("REQ-002", gaps.items[0].id);
}

test "nodesMissingEdge all covered" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addNode("TG-001", .test_group, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    var gaps: std.ArrayList(*const Node) = .empty;
    defer gaps.deinit(testing.allocator);
    try g.nodesMissingEdge(.requirement, .tested_by, testing.allocator, &gaps);
    try testing.expectEqual(0, gaps.items.len);
}

test "nodesMissingEdge empty graph" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    var gaps: std.ArrayList(*const Node) = .empty;
    defer gaps.deinit(testing.allocator);
    try g.nodesMissingEdge(.requirement, .tested_by, testing.allocator, &gaps);
    try testing.expectEqual(0, gaps.items.len);
}

test "downstream direct and recursive" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("A", .requirement, &.{});
    try g.addNode("B", .test_group, &.{});
    try g.addNode("C", .test_case, &.{});
    try g.addEdge("A", "B", .tested_by);
    try g.addEdge("B", "C", .has_test);
    var result: std.ArrayList(*const Node) = .empty;
    defer result.deinit(testing.allocator);
    try g.downstream("A", 20, testing.allocator, &result);
    try testing.expectEqual(2, result.items.len);
    try testing.expect(hasId(result.items, "B"));
    try testing.expect(hasId(result.items, "C"));
}

test "downstream direct only" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("A", .requirement, &.{});
    try g.addNode("B", .test_group, &.{});
    try g.addNode("C", .test_case, &.{});
    try g.addEdge("A", "B", .tested_by);
    try g.addEdge("B", "C", .has_test);
    var result: std.ArrayList(*const Node) = .empty;
    defer result.deinit(testing.allocator);
    try g.downstream("A", 1, testing.allocator, &result);
    try testing.expectEqual(1, result.items.len);
    try testing.expectEqualStrings("B", result.items[0].id);
}

test "downstream no edges" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("A", .requirement, &.{});
    var result: std.ArrayList(*const Node) = .empty;
    defer result.deinit(testing.allocator);
    try g.downstream("A", 20, testing.allocator, &result);
    try testing.expectEqual(0, result.items.len);
}

test "downstream cycle guard" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("A", .requirement, &.{});
    try g.addNode("B", .requirement, &.{});
    try g.addNode("C", .requirement, &.{});
    try g.addEdge("A", "B", .derives_from);
    try g.addEdge("B", "C", .derives_from);
    try g.addEdge("C", "A", .derives_from);
    var result: std.ArrayList(*const Node) = .empty;
    defer result.deinit(testing.allocator);
    try g.downstream("A", 20, testing.allocator, &result);
    try testing.expectEqual(2, result.items.len);
    try testing.expect(hasId(result.items, "B"));
    try testing.expect(hasId(result.items, "C"));
}

test "rtm unverified requirement" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system SHALL work" },
        .{ .key = "status", .value = "approved" },
    });
    var rows: std.ArrayList(RtmRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.rtm(testing.allocator, &rows);
    try testing.expectEqual(1, rows.items.len);
    const row = rows.items[0];
    try testing.expectEqualStrings("REQ-001", row.req_id);
    try testing.expect(row.test_group_id == null);
    try testing.expect(row.test_id == null);
    try testing.expect(row.user_need_id == null);
}

test "rtm with test" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("UN-001", .user_need, &.{.{ .key = "statement", .value = "I need GPS" }});
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system SHALL detect loss of GPS" },
        .{ .key = "status", .value = "approved" },
    });
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("TG-001-T01", .test_case, &.{
        .{ .key = "test_type", .value = "system" },
        .{ .key = "test_method", .value = "test" },
    });
    try g.addEdge("REQ-001", "UN-001", .derives_from);
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    try g.addEdge("TG-001", "TG-001-T01", .has_test);
    var rows: std.ArrayList(RtmRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.rtm(testing.allocator, &rows);
    try testing.expectEqual(1, rows.items.len);
    const row = rows.items[0];
    try testing.expectEqualStrings("REQ-001", row.req_id);
    try testing.expectEqualStrings("UN-001", row.user_need_id.?);
    try testing.expectEqualStrings("TG-001", row.test_group_id.?);
    try testing.expectEqualStrings("TG-001-T01", row.test_id.?);
    try testing.expectEqualStrings("system", row.test_type.?);
    try testing.expectEqualStrings("test", row.test_method.?);
}

test "rtm multiple tests in group" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "SHALL work" },
        .{ .key = "status", .value = "approved" },
    });
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("TG-001-T01", .test_case, &.{});
    try g.addNode("TG-001-T02", .test_case, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    try g.addEdge("TG-001", "TG-001-T01", .has_test);
    try g.addEdge("TG-001", "TG-001-T02", .has_test);
    var rows: std.ArrayList(RtmRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.rtm(testing.allocator, &rows);
    try testing.expectEqual(2, rows.items.len);
    try testing.expectEqualStrings("REQ-001", rows.items[0].req_id);
    try testing.expectEqualStrings("REQ-001", rows.items[1].req_id);
}

test "rtm multiple requirements" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{.{ .key = "statement", .value = "one" }});
    try g.addNode("REQ-002", .requirement, &.{.{ .key = "statement", .value = "two" }});
    var rows: std.ArrayList(RtmRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.rtm(testing.allocator, &rows);
    try testing.expectEqual(2, rows.items.len);
}

test "risks with linked req" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("RSK-001", .risk, &.{
        .{ .key = "description", .value = "GPS loss" },
        .{ .key = "initial_severity", .value = "4" },
        .{ .key = "initial_likelihood", .value = "3" },
        .{ .key = "mitigation", .value = "Add redundant sensor" },
    });
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addEdge("RSK-001", "REQ-001", .mitigated_by);
    var rows: std.ArrayList(RiskRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.risks(testing.allocator, &rows);
    try testing.expectEqual(1, rows.items.len);
    const row = rows.items[0];
    try testing.expectEqualStrings("RSK-001", row.risk_id);
    try testing.expectEqualStrings("GPS loss", row.description);
    try testing.expectEqualStrings("REQ-001", row.req_id.?);
    try testing.expectEqualStrings("4", row.initial_severity.?);
}

test "risks no linked req" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("RSK-001", .risk, &.{
        .{ .key = "description", .value = "Unmitigated risk" },
    });
    var rows: std.ArrayList(RiskRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.risks(testing.allocator, &rows);
    try testing.expectEqual(1, rows.items.len);
    try testing.expect(rows.items[0].req_id == null);
}

test "risks empty graph" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    var rows: std.ArrayList(RiskRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.risks(testing.allocator, &rows);
    try testing.expectEqual(0, rows.items.len);
}
