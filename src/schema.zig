/// Maps parsed XLSX sheet data onto a Graph.
///
/// Column lookup is by header name (case-insensitive) so column reordering
/// in the template does not break ingestion.

const std = @import("std");
const graph = @import("graph.zig");
const xlsx = @import("xlsx.zig");

const Graph = graph.Graph;
const Property = graph.Property;
const SheetData = xlsx.SheetData;
const Row = xlsx.Row;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Ingest all four XLSX sheets into g.
/// Call order: User Needs → Tests → Requirements → Risks
/// (so that edge targets exist before edges are created).
pub fn ingest(g: *Graph, sheets: []const SheetData) !void {
    // Order matters for edge resolution
    if (findSheet(sheets, "User Needs")) |s| try ingestUserNeeds(g, s);
    if (findSheet(sheets, "Tests")) |s| try ingestTests(g, s);
    if (findSheet(sheets, "Requirements")) |s| try ingestRequirements(g, s);
    if (findSheet(sheets, "Risks")) |s| try ingestRisks(g, s);
}

// ---------------------------------------------------------------------------
// Sheet finders and column helpers
// ---------------------------------------------------------------------------

fn findSheet(sheets: []const SheetData, name: []const u8) ?SheetData {
    for (sheets) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// Find the 0-based column index for a header matching name (case-insensitive).
fn findCol(headers: Row, name: []const u8) ?usize {
    for (headers, 0..) |h, i| {
        if (std.ascii.eqlIgnoreCase(h, name)) return i;
    }
    return null;
}

fn cell(row: Row, col: ?usize) []const u8 {
    const c = col orelse return "";
    if (c >= row.len) return "";
    return row[c];
}

// ---------------------------------------------------------------------------
// Per-sheet ingestion
// ---------------------------------------------------------------------------

fn ingestUserNeeds(g: *Graph, sheet: SheetData) !void {
    if (sheet.rows.len < 2) return;
    const headers = sheet.rows[0];

    const c_id = findCol(headers, "ID");
    const c_stmt = findCol(headers, "Statement");
    const c_src = findCol(headers, "Source of Need Statement");
    const c_pri = findCol(headers, "Priority");

    for (sheet.rows[1..]) |row| {
        const id = cell(row, c_id);
        if (id.len == 0) continue;

        try g.addNode(id, .user_need, &.{
            .{ .key = "statement", .value = cell(row, c_stmt) },
            .{ .key = "source", .value = cell(row, c_src) },
            .{ .key = "priority", .value = cell(row, c_pri) },
        });
    }
}

fn ingestTests(g: *Graph, sheet: SheetData) !void {
    if (sheet.rows.len < 2) return;
    const headers = sheet.rows[0];

    const c_tgid = findCol(headers, "Test Group ID");
    const c_tid = findCol(headers, "Test ID");
    const c_type = findCol(headers, "Test Type");
    const c_method = findCol(headers, "Test Method");

    for (sheet.rows[1..]) |row| {
        const tg_id = cell(row, c_tgid);
        const t_id = cell(row, c_tid);
        if (tg_id.len == 0 and t_id.len == 0) continue;

        // Add test group (idempotent)
        if (tg_id.len > 0) {
            try g.addNode(tg_id, .test_group, &.{});
        }

        // Add individual test and link to group
        if (t_id.len > 0 and tg_id.len > 0) {
            try g.addNode(t_id, .test_case, &.{
                .{ .key = "test_type", .value = cell(row, c_type) },
                .{ .key = "test_method", .value = cell(row, c_method) },
            });
            try g.addEdge(tg_id, t_id, .has_test);
        }
    }
}

fn ingestRequirements(g: *Graph, sheet: SheetData) !void {
    if (sheet.rows.len < 2) return;
    const headers = sheet.rows[0];

    const c_id = findCol(headers, "ID");
    // Header is "User Need iD" (note lowercase 'i') in the template
    const c_un = findCol(headers, "User Need ID") orelse findCol(headers, "User Need iD");
    const c_stmt = findCol(headers, "Statement");
    const c_pri = findCol(headers, "Priority");
    const c_tgid = findCol(headers, "Test Group ID");
    const c_status = findCol(headers, "Lifecycle Status");
    const c_notes = findCol(headers, "Notes");

    for (sheet.rows[1..]) |row| {
        const id = cell(row, c_id);
        if (id.len == 0) continue;

        try g.addNode(id, .requirement, &.{
            .{ .key = "statement", .value = cell(row, c_stmt) },
            .{ .key = "priority", .value = cell(row, c_pri) },
            .{ .key = "status", .value = cell(row, c_status) },
            .{ .key = "notes", .value = cell(row, c_notes) },
        });

        // DERIVES_FROM edge: Requirement → UserNeed
        const un_id = cell(row, c_un);
        if (un_id.len > 0) {
            try g.addEdge(id, un_id, .derives_from);
        }

        // TESTED_BY edge: Requirement → TestGroup
        const tg_id = cell(row, c_tgid);
        if (tg_id.len > 0) {
            try g.addEdge(id, tg_id, .tested_by);
        }
    }
}

fn ingestRisks(g: *Graph, sheet: SheetData) !void {
    if (sheet.rows.len < 2) return;
    const headers = sheet.rows[0];

    const c_id = findCol(headers, "Risk ID");
    const c_desc = findCol(headers, "Description");
    const c_isev = findCol(headers, "Initial Severity");
    const c_ilik = findCol(headers, "Initial Likelihood");
    const c_mit = findCol(headers, "Mitigation");
    const c_req = findCol(headers, "Linked REQ");
    const c_rsev = findCol(headers, "Residual Severity");
    const c_rlik = findCol(headers, "Residual Likelihood");

    for (sheet.rows[1..]) |row| {
        const id = cell(row, c_id);
        if (id.len == 0) continue;

        try g.addNode(id, .risk, &.{
            .{ .key = "description", .value = cell(row, c_desc) },
            .{ .key = "initial_severity", .value = cell(row, c_isev) },
            .{ .key = "initial_likelihood", .value = cell(row, c_ilik) },
            .{ .key = "mitigation", .value = cell(row, c_mit) },
            .{ .key = "residual_severity", .value = cell(row, c_rsev) },
            .{ .key = "residual_likelihood", .value = cell(row, c_rlik) },
        });

        // MITIGATED_BY edge: Risk → Requirement
        const req_id = cell(row, c_req);
        if (req_id.len > 0) {
            try g.addEdge(id, req_id, .mitigated_by);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ingest fixture into graph" {
    var tmp_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    const sheets = try xlsx.parse(tmp, "test/fixtures/RTMify_Requirements_Tracking_Template.xlsx");

    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try ingest(&g, sheets);

    // User Needs
    {
        const node = g.getNode("UN-001");
        try testing.expect(node != null);
        try testing.expectEqual(graph.NodeType.user_need, node.?.node_type);
        try testing.expectEqualStrings("This better work", node.?.get("statement").?);
        try testing.expectEqualStrings("Customer", node.?.get("source").?);
        try testing.expectEqualStrings("high", node.?.get("priority").?);
    }

    // Requirements
    {
        const req1 = g.getNode("REQ-001");
        try testing.expect(req1 != null);
        try testing.expectEqual(graph.NodeType.requirement, req1.?.node_type);
        try testing.expectEqualStrings("The system SHALL work", req1.?.get("statement").?);

        const req2 = g.getNode("REQ-002");
        try testing.expect(req2 != null);
    }

    // DERIVES_FROM edge: REQ-001 → UN-001
    {
        var edges: std.ArrayList(graph.Edge) = .empty;
        defer edges.deinit(testing.allocator);
        try g.edgesFrom("REQ-001", testing.allocator, &edges);
        var found_derives = false;
        for (edges.items) |e| {
            if (e.label == .derives_from and std.mem.eql(u8, e.to_id, "UN-001")) {
                found_derives = true;
            }
        }
        try testing.expect(found_derives);
    }

    // Tests
    {
        const tg = g.getNode("TG-001");
        try testing.expect(tg != null);
        try testing.expectEqual(graph.NodeType.test_group, tg.?.node_type);

        const t1 = g.getNode("T-001");
        try testing.expect(t1 != null);
        try testing.expectEqualStrings("Verification", t1.?.get("test_type").?);

        // HAS_TEST edge
        var edges: std.ArrayList(graph.Edge) = .empty;
        defer edges.deinit(testing.allocator);
        try g.edgesFrom("TG-001", testing.allocator, &edges);
        var count: usize = 0;
        for (edges.items) |e| if (e.label == .has_test) { count += 1; };
        try testing.expectEqual(@as(usize, 2), count); // T-001 and T-002
    }

    // TESTED_BY edge: REQ-002 → TG-001
    {
        var edges: std.ArrayList(graph.Edge) = .empty;
        defer edges.deinit(testing.allocator);
        try g.edgesFrom("REQ-002", testing.allocator, &edges);
        var found = false;
        for (edges.items) |e| {
            if (e.label == .tested_by) found = true;
        }
        try testing.expect(found);
    }

    // Risks
    {
        const risk = g.getNode("RSK-101");
        try testing.expect(risk != null);
        try testing.expectEqualStrings("Clock drift at high temp", risk.?.get("description").?);
        try testing.expectEqualStrings("4", risk.?.get("initial_severity").?);
        try testing.expectEqualStrings("3", risk.?.get("initial_likelihood").?);
        try testing.expectEqualStrings("Add external TCXO", risk.?.get("mitigation").?);
    }

    // MITIGATED_BY edge: RSK-101 → REQ-602 (unresolved, but edge still added)
    {
        var edges: std.ArrayList(graph.Edge) = .empty;
        defer edges.deinit(testing.allocator);
        try g.edgesFrom("RSK-101", testing.allocator, &edges);
        var found = false;
        for (edges.items) |e| if (e.label == .mitigated_by) { found = true; };
        try testing.expect(found);
    }

    // Gap detection: REQ-001 has no test group → should appear as untested
    {
        var gaps: std.ArrayList(*const graph.Node) = .empty;
        defer gaps.deinit(testing.allocator);
        try g.nodesMissingEdge(.requirement, .tested_by, testing.allocator, &gaps);
        var found = false;
        for (gaps.items) |n| if (std.mem.eql(u8, n.id, "REQ-001")) { found = true; };
        try testing.expect(found);
    }
}
