/// Renders an in-memory Graph as a DOCX Requirements Traceability Matrix.
///
/// Produces a valid ZIP archive (stored/uncompressed mode) containing the
/// minimal set of OOXML parts required for a well-formed Word document.
/// No external libraries; ZIP and XML are hand-written.
///
/// All ZIP entries are stored (method 0) — no deflate dependency. DOCX files
/// are small enough that uncompressed is fine.

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph = @import("graph.zig");
const Graph = graph.Graph;
const RtmRow = graph.RtmRow;
const RiskRow = graph.RiskRow;

// ---------------------------------------------------------------------------
// Column widths (DXA / twips). US Letter with 1" margins = 9360 DXA usable.
// ---------------------------------------------------------------------------

const COL_UN = [4]u32{ 840, 4800, 2160, 1560 }; // User Needs
const COL_RTM = [8]u32{ 840, 840, 2880, 720, 720, 840, 840, 1680 }; // RTM
const COL_TST = [5]u32{ 840, 840, 1800, 1800, 4080 }; // Tests
const COL_RISK = [10]u32{ 720, 3600, 480, 480, 480, 1440, 720, 480, 480, 480 }; // Risks

const GAP_FILL = "FFFF00"; // yellow for gap rows
const HDR_FILL = "D9D9D9"; // gray for header rows
const DASH = "—"; // U+2014 em dash for empty fields

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Write a full DOCX RTM report for `g` to `writer`.
pub fn renderDocx(
    g: *const Graph,
    input_filename: []const u8,
    timestamp: []const u8,
    writer: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content_types = try buildContentTypes(alloc);
    const root_rels = try buildRootRels(alloc);
    const doc_rels = try buildDocRels(alloc);
    const styles_xml = try buildStyles(alloc);
    const footer_xml = try buildFooter(alloc);
    const document_xml = try buildDocument(g, input_filename, timestamp, alloc);

    const files = [_]ZipFile{
        .{ .name = "[Content_Types].xml", .data = content_types },
        .{ .name = "_rels/.rels", .data = root_rels },
        .{ .name = "word/_rels/document.xml.rels", .data = doc_rels },
        .{ .name = "word/styles.xml", .data = styles_xml },
        .{ .name = "word/footer1.xml", .data = footer_xml },
        .{ .name = "word/document.xml", .data = document_xml },
    };
    try writeZip(&files, writer);
}

// ---------------------------------------------------------------------------
// ZIP writer (stored mode only)
// ---------------------------------------------------------------------------

const ZipFile = struct {
    name: []const u8,
    data: []const u8,
};

fn writeZip(files: []const ZipFile, writer: anytype) !void {
    const MAX_FILES = 16;
    var offsets: [MAX_FILES]u32 = undefined;
    var crcs: [MAX_FILES]u32 = undefined;
    var sizes: [MAX_FILES]u32 = undefined;
    var cur: u32 = 0;

    // Local file headers + data
    for (files, 0..) |file, i| {
        const crc = std.hash.crc.Crc32.hash(file.data);
        const sz: u32 = @intCast(file.data.len);
        const nl: u16 = @intCast(file.name.len);
        offsets[i] = cur;
        crcs[i] = crc;
        sizes[i] = sz;

        try writer.writeAll("PK\x03\x04"); // local file header signature
        try writer.writeInt(u16, 20, .little); // version needed: 2.0
        try writer.writeInt(u16, 0, .little); // flags
        try writer.writeInt(u16, 0, .little); // store (no compression)
        try writer.writeInt(u16, 0, .little); // last mod time
        try writer.writeInt(u16, 0, .little); // last mod date
        try writer.writeInt(u32, crc, .little);
        try writer.writeInt(u32, sz, .little);
        try writer.writeInt(u32, sz, .little);
        try writer.writeInt(u16, nl, .little);
        try writer.writeInt(u16, 0, .little); // extra field length
        try writer.writeAll(file.name);
        try writer.writeAll(file.data);

        cur += 30 + @as(u32, nl) + sz;
    }

    // Central directory
    const cd_offset = cur;
    var cd_size: u32 = 0;
    for (files, 0..) |file, i| {
        const nl: u16 = @intCast(file.name.len);
        try writer.writeAll("PK\x01\x02"); // central directory header signature
        try writer.writeInt(u16, 20, .little); // version made by
        try writer.writeInt(u16, 20, .little); // version needed
        try writer.writeInt(u16, 0, .little); // flags
        try writer.writeInt(u16, 0, .little); // store
        try writer.writeInt(u16, 0, .little); // last mod time
        try writer.writeInt(u16, 0, .little); // last mod date
        try writer.writeInt(u32, crcs[i], .little);
        try writer.writeInt(u32, sizes[i], .little);
        try writer.writeInt(u32, sizes[i], .little);
        try writer.writeInt(u16, nl, .little);
        try writer.writeInt(u16, 0, .little); // extra len
        try writer.writeInt(u16, 0, .little); // comment len
        try writer.writeInt(u16, 0, .little); // disk start
        try writer.writeInt(u16, 0, .little); // internal file attributes
        try writer.writeInt(u32, 0, .little); // external file attributes
        try writer.writeInt(u32, offsets[i], .little);
        try writer.writeAll(file.name);
        cd_size += 46 + @as(u32, nl);
    }

    // End of central directory record
    const n: u16 = @intCast(files.len);
    try writer.writeAll("PK\x05\x06"); // end of central dir signature
    try writer.writeInt(u16, 0, .little); // disk number
    try writer.writeInt(u16, 0, .little); // CD start disk
    try writer.writeInt(u16, n, .little); // entries on this disk
    try writer.writeInt(u16, n, .little); // total entries
    try writer.writeInt(u32, cd_size, .little);
    try writer.writeInt(u32, cd_offset, .little);
    try writer.writeInt(u16, 0, .little); // comment length
}

// ---------------------------------------------------------------------------
// Fixed XML part builders
// ---------------------------------------------------------------------------

fn buildContentTypes(alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(alloc);
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
    try w.writeAll("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">");
    try w.writeAll("<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>");
    try w.writeAll("<Default Extension=\"xml\" ContentType=\"application/xml\"/>");
    try w.writeAll("<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>");
    try w.writeAll("<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>");
    try w.writeAll("<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>");
    try w.writeAll("</Types>");
    return buf.items;
}

fn buildRootRels(alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(alloc);
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
    try w.writeAll("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">");
    try w.writeAll("<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>");
    try w.writeAll("</Relationships>");
    return buf.items;
}

fn buildDocRels(alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(alloc);
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
    try w.writeAll("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">");
    try w.writeAll("<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>");
    try w.writeAll("<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>");
    try w.writeAll("</Relationships>");
    return buf.items;
}

fn buildStyles(alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(alloc);
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
    try w.writeAll("<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">");
    // Document defaults: Helvetica 10pt (20 half-points)
    try w.writeAll("<w:docDefaults><w:rPrDefault><w:rPr>");
    try w.writeAll("<w:rFonts w:ascii=\"Helvetica\" w:hAnsi=\"Helvetica\"/>");
    try w.writeAll("<w:sz w:val=\"20\"/>");
    try w.writeAll("</w:rPr></w:rPrDefault></w:docDefaults>");
    // Normal (default paragraph)
    try w.writeAll("<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\">");
    try w.writeAll("<w:name w:val=\"Normal\"/></w:style>");
    // Heading 1: 14pt bold, spacing before/after
    try w.writeAll("<w:style w:type=\"paragraph\" w:styleId=\"Heading1\">");
    try w.writeAll("<w:name w:val=\"heading 1\"/>");
    try w.writeAll("<w:pPr><w:spacing w:before=\"240\" w:after=\"120\"/></w:pPr>");
    try w.writeAll("<w:rPr><w:b/><w:sz w:val=\"28\"/></w:rPr>");
    try w.writeAll("</w:style>");
    // Heading 2: 12pt bold
    try w.writeAll("<w:style w:type=\"paragraph\" w:styleId=\"Heading2\">");
    try w.writeAll("<w:name w:val=\"heading 2\"/>");
    try w.writeAll("<w:pPr><w:spacing w:before=\"120\" w:after=\"60\"/></w:pPr>");
    try w.writeAll("<w:rPr><w:b/><w:sz w:val=\"24\"/></w:rPr>");
    try w.writeAll("</w:style>");
    // TableGrid: all borders
    try w.writeAll("<w:style w:type=\"table\" w:styleId=\"TableGrid\">");
    try w.writeAll("<w:name w:val=\"Table Grid\"/>");
    try w.writeAll("<w:tblPr><w:tblBorders>");
    for ([_][]const u8{ "top", "left", "bottom", "right", "insideH", "insideV" }) |side| {
        try w.print("<w:{s} w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"000000\"/>", .{side});
    }
    try w.writeAll("</w:tblBorders></w:tblPr></w:style>");
    try w.writeAll("</w:styles>");
    return buf.items;
}

fn buildFooter(alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(alloc);
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
    try w.writeAll("<w:ftr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">");
    try w.writeAll("<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>");
    try w.writeAll("<w:fldSimple w:instr=\" PAGE \"><w:r><w:t>1</w:t></w:r></w:fldSimple>");
    try w.writeAll("</w:p></w:ftr>");
    return buf.items;
}

// ---------------------------------------------------------------------------
// XML helpers
// ---------------------------------------------------------------------------

/// Append text to writer with XML escaping for &, <, >.
fn xmlText(w: anytype, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '&' or c == '<' or c == '>') {
            if (i > start) try w.writeAll(text[start..i]);
            start = i + 1;
            try w.writeAll(switch (c) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                else => unreachable,
            });
        }
    }
    if (start < text.len) try w.writeAll(text[start..]);
}

/// Write a styled paragraph. Pass style="" for Normal.
fn writePara(w: anytype, style: []const u8, bold: bool, text: []const u8) !void {
    if (style.len > 0) {
        try w.print("<w:p><w:pPr><w:pStyle w:val=\"{s}\"/></w:pPr>", .{style});
    } else {
        try w.writeAll("<w:p>");
    }
    try w.writeAll("<w:r>");
    if (bold) try w.writeAll("<w:rPr><w:b/></w:rPr>");
    try w.writeAll("<w:t xml:space=\"preserve\">");
    try xmlText(w, text);
    try w.writeAll("</w:t></w:r></w:p>");
}

/// Write one table cell.
fn writeCell(w: anytype, width: u32, text: []const u8, bold: bool, fill: ?[]const u8) !void {
    try w.writeAll("<w:tc><w:tcPr>");
    try w.print("<w:tcW w:w=\"{d}\" w:type=\"dxa\"/>", .{width});
    if (fill) |f| {
        try w.print("<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"{s}\"/>", .{f});
    }
    try w.writeAll("</w:tcPr><w:p><w:r>");
    if (bold) try w.writeAll("<w:rPr><w:b/></w:rPr>");
    try w.writeAll("<w:t xml:space=\"preserve\">");
    try xmlText(w, text);
    try w.writeAll("</w:t></w:r></w:p></w:tc>");
}

/// Open a table with column widths.
fn tableStart(w: anytype, widths: []const u32) !void {
    try w.writeAll("<w:tbl><w:tblPr>");
    try w.writeAll("<w:tblStyle w:val=\"TableGrid\"/>");
    try w.writeAll("<w:tblW w:w=\"9360\" w:type=\"dxa\"/>");
    try w.writeAll("</w:tblPr><w:tblGrid>");
    for (widths) |ww| try w.print("<w:gridCol w:w=\"{d}\"/>", .{ww});
    try w.writeAll("</w:tblGrid>");
}

fn tableEnd(w: anytype) !void {
    try w.writeAll("</w:tbl>");
}

/// Write a bold header row with gray background.
fn writeHeaderRow(w: anytype, cells_text: []const []const u8, widths: []const u32) !void {
    try w.writeAll("<w:tr><w:trPr><w:tblHeader/></w:trPr>");
    for (cells_text, widths) |txt, wid| try writeCell(w, wid, txt, true, HDR_FILL);
    try w.writeAll("</w:tr>");
}

/// Write a data row with optional fill color.
fn writeDataRow(w: anytype, cells_text: []const []const u8, widths: []const u32, fill: ?[]const u8) !void {
    try w.writeAll("<w:tr>");
    for (cells_text, widths) |txt, wid| try writeCell(w, wid, txt, false, fill);
    try w.writeAll("</w:tr>");
}

// ---------------------------------------------------------------------------
// Shared data helpers
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
// Main document builder
// ---------------------------------------------------------------------------

fn buildDocument(
    g: *const Graph,
    input_filename: []const u8,
    timestamp: []const u8,
    alloc: Allocator,
) ![]const u8 {
    // Collect and sort all data (mirrors render_md.zig ordering)
    var uns: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesByType(.user_need, alloc, &uns);
    std.mem.sort(*const graph.Node, uns.items, {}, nodeIdLt);

    var rtm_rows: std.ArrayList(RtmRow) = .empty;
    try g.rtm(alloc, &rtm_rows);
    std.mem.sort(RtmRow, rtm_rows.items, {}, rtmRowLt);

    var untested: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesMissingEdge(.requirement, .tested_by, alloc, &untested);
    var orphan: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesMissingEdge(.requirement, .derives_from, alloc, &orphan);

    // Build test rows
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
        var edges_in: std.ArrayList(graph.Edge) = .empty;
        try g.edgesTo(tg.id, alloc, &edges_in);
        var req_id: ?[]const u8 = null;
        for (edges_in.items) |e| {
            if (e.label == .tested_by) {
                req_id = e.from_id;
                break;
            }
        }
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

    var risk_rows: std.ArrayList(RiskRow) = .empty;
    try g.risks(alloc, &risk_rows);
    std.mem.sort(RiskRow, risk_rows.items, {}, struct {
        fn lt(_: void, a: RiskRow, b: RiskRow) bool {
            return std.mem.order(u8, a.risk_id, b.risk_id) == .lt;
        }
    }.lt);

    // Build list of unresolved risk mitigations
    var unresolved: std.ArrayList(struct { risk_id: []const u8, req_id: []const u8 }) = .empty;
    for (risk_rows.items) |row| {
        if (row.req_id) |rid| {
            if (g.getNode(rid) == null) {
                try unresolved.append(alloc, .{ .risk_id = row.risk_id, .req_id = rid });
            }
        }
    }

    // Build XML
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(alloc);

    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
    try w.writeAll("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"");
    try w.writeAll(" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">");
    try w.writeAll("<w:body>");

    // Title block
    try writePara(w, "Heading1", false, "Requirements Traceability Matrix");
    try writePara(w, "", false, try std.fmt.allocPrint(alloc, "Input: {s}", .{input_filename}));
    try writePara(w, "", false, try std.fmt.allocPrint(alloc, "Generated: {s}", .{timestamp}));

    // === User Needs ===
    try writePara(w, "Heading1", false, "User Needs");
    try tableStart(w, &COL_UN);
    try writeHeaderRow(w, &[_][]const u8{ "ID", "Statement", "Source", "Priority" }, &COL_UN);
    for (uns.items) |n| {
        const cells = [_][]const u8{
            n.id,
            n.get("statement") orelse "",
            n.get("source") orelse "",
            n.get("priority") orelse "",
        };
        try writeDataRow(w, &cells, &COL_UN, null);
    }
    try tableEnd(w);

    // === Requirements Traceability ===
    try writePara(w, "Heading1", false, "Requirements Traceability");
    try tableStart(w, &COL_RTM);
    try writeHeaderRow(w, &[_][]const u8{ "Req ID", "User Need", "Statement", "Test Group", "Test ID", "Type", "Method", "Status" }, &COL_RTM);
    for (rtm_rows.items) |row| {
        const has_gap = nodeHasId(untested.items, row.req_id) or nodeHasId(orphan.items, row.req_id);
        const fill: ?[]const u8 = if (has_gap) GAP_FILL else null;
        const req_label: []const u8 = if (has_gap)
            try std.fmt.allocPrint(alloc, "\u{26A0} {s}", .{row.req_id})
        else
            row.req_id;
        const cells = [_][]const u8{
            req_label,
            row.user_need_id orelse DASH,
            row.statement,
            row.test_group_id orelse DASH,
            row.test_id orelse DASH,
            row.test_type orelse DASH,
            row.test_method orelse DASH,
            row.status,
        };
        try writeDataRow(w, &cells, &COL_RTM, fill);
    }
    try tableEnd(w);

    // === Tests ===
    try writePara(w, "Heading1", false, "Tests");
    try tableStart(w, &COL_TST);
    try writeHeaderRow(w, &[_][]const u8{ "Test Group", "Test ID", "Type", "Method", "Linked Req" }, &COL_TST);
    for (test_rows.items) |row| {
        const cells = [_][]const u8{
            row.tg_id,
            row.test_id,
            row.test_type,
            row.test_method,
            row.req_id orelse DASH,
        };
        try writeDataRow(w, &cells, &COL_TST, null);
    }
    try tableEnd(w);

    // === Risk Register ===
    try writePara(w, "Heading1", false, "Risk Register");
    try tableStart(w, &COL_RISK);
    try writeHeaderRow(w, &[_][]const u8{ "Risk ID", "Description", "I.Sev", "I.Lik", "I.Score", "Mitigation", "Linked Req", "R.Sev", "R.Lik", "R.Score" }, &COL_RISK);
    for (risk_rows.items) |row| {
        const is_unresolved = if (row.req_id) |rid| g.getNode(rid) == null else false;
        const fill: ?[]const u8 = if (is_unresolved) GAP_FILL else null;
        const req_label: []const u8 = if (is_unresolved)
            try std.fmt.allocPrint(alloc, "\u{26A0} {s}", .{row.req_id.?})
        else
            row.req_id orelse DASH;
        var iscore_buf: [32]u8 = undefined;
        var rscore_buf: [32]u8 = undefined;
        const init_score = scoreStr(&iscore_buf, row.initial_severity, row.initial_likelihood);
        const res_score = scoreStr(&rscore_buf, row.residual_severity, row.residual_likelihood);
        const cells = [_][]const u8{
            row.risk_id,
            row.description,
            row.initial_severity orelse DASH,
            row.initial_likelihood orelse DASH,
            init_score,
            row.mitigation orelse DASH,
            req_label,
            row.residual_severity orelse DASH,
            row.residual_likelihood orelse DASH,
            res_score,
        };
        try writeDataRow(w, &cells, &COL_RISK, fill);
    }
    try tableEnd(w);

    // === Gap Summary ===
    std.mem.sort(*const graph.Node, untested.items, {}, nodeIdLt);
    std.mem.sort(*const graph.Node, orphan.items, {}, nodeIdLt);
    const total_gaps = untested.items.len + orphan.items.len + unresolved.items.len;
    try writePara(w, "Heading1", false, "Gap Summary");
    try writePara(w, "", true, try std.fmt.allocPrint(alloc, "{d} gap(s) found.", .{total_gaps}));

    if (untested.items.len > 0) {
        try writePara(w, "Heading2", false, try std.fmt.allocPrint(alloc, "Untested Requirements ({d})", .{untested.items.len}));
        for (untested.items) |n| {
            try writePara(w, "", false, try std.fmt.allocPrint(alloc, "\u{2022} {s}", .{n.id}));
        }
    }
    if (orphan.items.len > 0) {
        try writePara(w, "Heading2", false, try std.fmt.allocPrint(alloc, "Orphan Requirements \u{2014} no User Need ({d})", .{orphan.items.len}));
        for (orphan.items) |n| {
            try writePara(w, "", false, try std.fmt.allocPrint(alloc, "\u{2022} {s}", .{n.id}));
        }
    }
    if (unresolved.items.len > 0) {
        try writePara(w, "Heading2", false, try std.fmt.allocPrint(alloc, "Unresolved Risk Mitigations ({d})", .{unresolved.items.len}));
        for (unresolved.items) |r| {
            try writePara(w, "", false, try std.fmt.allocPrint(alloc, "\u{2022} {s} \u{2192} {s}", .{ r.risk_id, r.req_id }));
        }
    }

    // Section properties: US Letter, 1" margins, footer
    try w.writeAll("<w:sectPr>");
    try w.writeAll("<w:footerReference w:type=\"default\" r:id=\"rId2\"/>");
    try w.writeAll("<w:pgSz w:w=\"12240\" w:h=\"15840\"/>");
    try w.writeAll("<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"");
    try w.writeAll(" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/>");
    try w.writeAll("</w:sectPr>");

    try w.writeAll("</w:body></w:document>");
    return buf.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const xlsx = @import("xlsx.zig");
const schema = @import("schema.zig");

test "render_docx fixture" {
    var tmp_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    const sheets = try xlsx.parse(tmp, "test/fixtures/RTMify_Requirements_Tracking_Template.xlsx");
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try schema.ingest(&g, sheets);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderDocx(&g, "test.xlsx", "2024-01-01T00:00:00Z", buf.writer(testing.allocator));

    const out = buf.items;

    // ZIP signatures
    try testing.expect(std.mem.indexOf(u8, out, "PK\x03\x04") != null);
    try testing.expect(std.mem.indexOf(u8, out, "PK\x01\x02") != null);
    try testing.expect(std.mem.indexOf(u8, out, "PK\x05\x06") != null);

    // All required OOXML parts present in ZIP entries
    try testing.expect(std.mem.indexOf(u8, out, "[Content_Types].xml") != null);
    try testing.expect(std.mem.indexOf(u8, out, "word/document.xml") != null);
    try testing.expect(std.mem.indexOf(u8, out, "word/styles.xml") != null);
    try testing.expect(std.mem.indexOf(u8, out, "word/footer1.xml") != null);

    // Document content from fixture data
    try testing.expect(std.mem.indexOf(u8, out, "Requirements Traceability Matrix") != null);
    try testing.expect(std.mem.indexOf(u8, out, "This better work") != null); // UN-001 statement
    try testing.expect(std.mem.indexOf(u8, out, "The system SHALL work") != null); // REQ-001
    try testing.expect(std.mem.indexOf(u8, out, "Clock drift at high temp") != null); // RSK-101
    try testing.expect(std.mem.indexOf(u8, out, "Add external TCXO") != null); // mitigation

    // Yellow shading on gap rows (REQ-001 untested, REQ-002 orphan)
    try testing.expect(std.mem.indexOf(u8, out, "FFFF00") != null);

    // Page number field in footer
    try testing.expect(std.mem.indexOf(u8, out, " PAGE ") != null);

    // Gap summary
    try testing.expect(std.mem.indexOf(u8, out, "3 gap(s) found.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Untested Requirements") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Orphan Requirements") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Unresolved Risk Mitigations") != null);
}

test "render_docx no gaps no yellow" {
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
    try renderDocx(&g, "test.xlsx", "2024-01-01T00:00:00Z", buf.writer(testing.allocator));

    const out = buf.items;
    // No gaps → no yellow shading and no gap sub-sections
    try testing.expect(std.mem.indexOf(u8, out, "FFFF00") == null);
    try testing.expect(std.mem.indexOf(u8, out, "0 gap(s) found.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Untested Requirements") == null);
}

test "render_docx xml escape" {
    // Verify that XML special chars in content are escaped
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "A & B < C > D" },
        .{ .key = "status", .value = "draft" },
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderDocx(&g, "test.xlsx", "T", buf.writer(testing.allocator));

    const out = buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "&amp;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&lt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&gt;") != null);
    // Raw unescaped characters should not appear adjacent to each other
    try testing.expect(std.mem.indexOf(u8, out, "A & B") == null);
}
