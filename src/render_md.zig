/// Renders an in-memory Graph as a Markdown Requirements Traceability Matrix.
///
/// All sections (User Needs, Requirements Traceability, Tests, Risk Register,
/// Gap Summary) are sorted deterministically by ID so output is stable across
/// hash-map iteration orders.

const std = @import("std");
const graph = @import("graph.zig");
const Graph = graph.Graph;
const RtmRow = graph.RtmRow;
const RiskRow = graph.RiskRow;

const DASH = "—"; // U+2014 em dash

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Write a full Markdown RTM report for `g` to `writer`.
/// `input_filename` and `timestamp` are embedded verbatim in the title block.
pub fn renderMd(
    g: *const Graph,
    input_filename: []const u8,
    timestamp: []const u8,
    writer: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // -----------------------------------------------------------------------
    // Title block
    // -----------------------------------------------------------------------
    try writer.print("# Requirements Traceability Matrix\n\n", .{});
    try writer.print("Input: {s}\n", .{input_filename});
    try writer.print("Generated: {s}\n", .{timestamp});

    // -----------------------------------------------------------------------
    // User Needs
    // -----------------------------------------------------------------------
    try writer.writeAll("\n## User Needs\n\n");
    try writer.writeAll("| ID | Statement | Source | Priority |\n");
    try writer.writeAll("| --- | --- | --- | --- |\n");

    var uns: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesByType(.user_need, alloc, &uns);
    std.mem.sort(*const graph.Node, uns.items, {}, nodeIdLt);
    for (uns.items) |n| {
        try writer.print("| {s} | {s} | {s} | {s} |\n", .{
            n.id,
            n.get("statement") orelse "",
            n.get("source") orelse "",
            n.get("priority") orelse "",
        });
    }

    // -----------------------------------------------------------------------
    // Requirements Traceability
    // -----------------------------------------------------------------------
    try writer.writeAll("\n## Requirements Traceability\n\n");
    try writer.writeAll("| Req ID | User Need | Statement | Test Group | Test ID | Type | Method | Status |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- | --- | --- | --- |\n");

    var rtm_rows: std.ArrayList(RtmRow) = .empty;
    try g.rtm(alloc, &rtm_rows);
    std.mem.sort(RtmRow, rtm_rows.items, {}, rtmRowLt);

    // Pre-compute gap sets for **⚠** markers
    var untested: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesMissingEdge(.requirement, .tested_by, alloc, &untested);

    var orphan: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesMissingEdge(.requirement, .derives_from, alloc, &orphan);

    for (rtm_rows.items) |row| {
        const has_gap = nodeHasId(untested.items, row.req_id) or
            nodeHasId(orphan.items, row.req_id);
        const req_prefix: []const u8 = if (has_gap) "**⚠** " else "";
        const un = row.user_need_id orelse DASH;
        const tg = row.test_group_id orelse DASH;
        const tid = row.test_id orelse DASH;
        const typ = row.test_type orelse DASH;
        const meth = row.test_method orelse DASH;
        try writer.print("| {s}{s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} |\n", .{
            req_prefix, row.req_id, un, row.statement,
            tg, tid, typ, meth, row.status,
        });
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------
    try writer.writeAll("\n## Tests\n\n");
    try writer.writeAll("| Test Group | Test ID | Type | Method | Linked Req |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- |\n");

    const TestRow = struct {
        tg_id: []const u8,
        test_id: []const u8,
        test_type: []const u8,
        test_method: []const u8,
        req_id: ?[]const u8,
    };

    var tg_nodes: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesByType(.test_group, alloc, &tg_nodes);

    var test_rows: std.ArrayList(TestRow) = .empty;
    for (tg_nodes.items) |tg| {
        // Find requirement linked to this test group (TESTED_BY tg)
        var edges_in: std.ArrayList(graph.Edge) = .empty;
        try g.edgesTo(tg.id, alloc, &edges_in);
        var req_id: ?[]const u8 = null;
        for (edges_in.items) |e| {
            if (e.label == .tested_by) {
                req_id = e.from_id;
                break;
            }
        }

        // Find test cases in this group (tg HAS_TEST test)
        var edges_out: std.ArrayList(graph.Edge) = .empty;
        try g.edgesFrom(tg.id, alloc, &edges_out);
        for (edges_out.items) |e| {
            if (e.label != .has_test) continue;
            const t = g.getNode(e.to_id);
            try test_rows.append(alloc, .{
                .tg_id = tg.id,
                .test_id = e.to_id,
                .test_type = if (t) |n| n.get("test_type") orelse "" else "",
                .test_method = if (t) |n| n.get("test_method") orelse "" else "",
                .req_id = req_id,
            });
        }
    }
    std.mem.sort(TestRow, test_rows.items, {}, struct {
        fn lt(_: void, a: TestRow, b: TestRow) bool {
            const c = std.mem.order(u8, a.tg_id, b.tg_id);
            if (c != .eq) return c == .lt;
            return std.mem.order(u8, a.test_id, b.test_id) == .lt;
        }
    }.lt);

    for (test_rows.items) |row| {
        const req = row.req_id orelse DASH;
        try writer.print("| {s} | {s} | {s} | {s} | {s} |\n", .{
            row.tg_id, row.test_id, row.test_type, row.test_method, req,
        });
    }

    // -----------------------------------------------------------------------
    // Risk Register
    // -----------------------------------------------------------------------
    try writer.writeAll("\n## Risk Register\n\n");
    try writer.writeAll("| Risk ID | Description | Init. Sev | Init. Like | Init. Score | Mitigation | Linked Req | Res. Sev | Res. Like | Res. Score |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");

    var risk_rows: std.ArrayList(RiskRow) = .empty;
    try g.risks(alloc, &risk_rows);
    std.mem.sort(RiskRow, risk_rows.items, {}, struct {
        fn lt(_: void, a: RiskRow, b: RiskRow) bool {
            return std.mem.order(u8, a.risk_id, b.risk_id) == .lt;
        }
    }.lt);

    var unresolved: std.ArrayList(struct { risk_id: []const u8, req_id: []const u8 }) = .empty;

    for (risk_rows.items) |row| {
        const is_unresolved = if (row.req_id) |rid| g.getNode(rid) == null else false;
        const req_prefix: []const u8 = if (is_unresolved) "**⚠** " else "";
        const req_str = row.req_id orelse DASH;
        const init_sev = row.initial_severity orelse DASH;
        const init_lik = row.initial_likelihood orelse DASH;
        const res_sev = row.residual_severity orelse DASH;
        const res_lik = row.residual_likelihood orelse DASH;
        const mit = row.mitigation orelse DASH;

        var init_score_buf: [32]u8 = undefined;
        var res_score_buf: [32]u8 = undefined;
        const init_score = scoreStr(&init_score_buf, row.initial_severity, row.initial_likelihood);
        const res_score = scoreStr(&res_score_buf, row.residual_severity, row.residual_likelihood);

        try writer.print("| {s} | {s} | {s} | {s} | {s} | {s} | {s}{s} | {s} | {s} | {s} |\n", .{
            row.risk_id, row.description,
            init_sev, init_lik, init_score,
            mit,
            req_prefix, req_str,
            res_sev, res_lik, res_score,
        });

        if (is_unresolved) {
            try unresolved.append(alloc, .{
                .risk_id = row.risk_id,
                .req_id = row.req_id.?,
            });
        }
    }

    // -----------------------------------------------------------------------
    // Gap Summary
    // -----------------------------------------------------------------------
    std.mem.sort(*const graph.Node, untested.items, {}, nodeIdLt);
    std.mem.sort(*const graph.Node, orphan.items, {}, nodeIdLt);

    const total: usize = untested.items.len + orphan.items.len + unresolved.items.len;
    try writer.print("\n## Gap Summary\n\n**{d} gap(s) found.**\n", .{total});

    if (untested.items.len > 0) {
        try writer.print("\n### Untested Requirements ({d})\n\n", .{untested.items.len});
        for (untested.items) |n| {
            try writer.print("- {s}\n", .{n.id});
        }
    }

    if (orphan.items.len > 0) {
        try writer.print("\n### Orphan Requirements \u{2014} no User Need ({d})\n\n", .{orphan.items.len});
        for (orphan.items) |n| {
            try writer.print("- {s}\n", .{n.id});
        }
    }

    if (unresolved.items.len > 0) {
        try writer.print("\n### Unresolved Risk Mitigations ({d})\n\n", .{unresolved.items.len});
        for (unresolved.items) |r| {
            try writer.print("- {s} \u{2192} {s}\n", .{ r.risk_id, r.req_id });
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn nodeIdLt(_: void, a: *const graph.Node, b: *const graph.Node) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn rtmRowLt(_: void, a: RtmRow, b: RtmRow) bool {
    const c = std.mem.order(u8, a.req_id, b.req_id);
    if (c != .eq) return c == .lt;
    return std.mem.order(u8, a.test_id orelse "", b.test_id orelse "") == .lt;
}

fn nodeHasId(nodes: []const *const graph.Node, id: []const u8) bool {
    for (nodes) |n| if (std.mem.eql(u8, n.id, id)) return true;
    return false;
}

fn scoreStr(buf: []u8, sev: ?[]const u8, lik: ?[]const u8) []const u8 {
    const s = sev orelse return DASH;
    const l = lik orelse return DASH;
    const si = std.fmt.parseInt(u64, s, 10) catch return DASH;
    const li = std.fmt.parseInt(u64, l, 10) catch return DASH;
    return std.fmt.bufPrint(buf, "{d}", .{si * li}) catch DASH;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const xlsx = @import("xlsx.zig");
const schema = @import("schema.zig");

test "render_md golden file" {
    var tmp_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    const sheets = try xlsx.parse(tmp, "test/fixtures/RTMify_Requirements_Tracking_Template.xlsx");

    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try schema.ingest(&g, sheets);

    // Render to buffer
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderMd(&g, "RTMify_Requirements_Tracking_Template.xlsx", "2024-01-01T00:00:00Z",
        buf.writer(testing.allocator));

    // Load golden file
    const golden = try std.fs.cwd().readFileAlloc(
        testing.allocator,
        "test/fixtures/golden_rtm.md",
        1024 * 1024,
    );
    defer testing.allocator.free(golden);

    try testing.expectEqualStrings(golden, buf.items);
}

test "render_md no gaps" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("UN-001", .user_need, &.{
        .{ .key = "statement", .value = "Need" },
        .{ .key = "source", .value = "Customer" },
        .{ .key = "priority", .value = "high" },
    });
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "SHALL do" },
        .{ .key = "status", .value = "Approved" },
    });
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("T-001", .test_case, &.{
        .{ .key = "test_type", .value = "Verification" },
        .{ .key = "test_method", .value = "Test" },
    });
    try g.addEdge("REQ-001", "UN-001", .derives_from);
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    try g.addEdge("TG-001", "T-001", .has_test);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderMd(&g, "test.xlsx", "2024-01-01T00:00:00Z", buf.writer(testing.allocator));

    // No gaps — no warning markers, gap summary shows 0, no sub-sections
    try testing.expect(std.mem.indexOf(u8, buf.items, "**⚠**") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "**0 gap(s) found.**") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "### Untested") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "### Orphan") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "### Unresolved") == null);
}

test "render_md score calculation" {
    var init_buf: [32]u8 = undefined;
    var res_buf: [32]u8 = undefined;
    try testing.expectEqualStrings("12", scoreStr(&init_buf, "4", "3"));
    try testing.expectEqualStrings("4", scoreStr(&res_buf, "4", "1"));

    var dash_buf: [32]u8 = undefined;
    try testing.expectEqualStrings(DASH, scoreStr(&dash_buf, null, "3"));
    try testing.expectEqualStrings(DASH, scoreStr(&dash_buf, "4", null));
    try testing.expectEqualStrings(DASH, scoreStr(&dash_buf, "x", "3"));
}
