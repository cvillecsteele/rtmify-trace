/// Maps parsed XLSX sheet data onto a Graph.
///
/// Column lookup is by header name (case-insensitive) so column reordering
/// in the template does not break ingestion.

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph = @import("graph.zig");
const xlsx = @import("xlsx.zig");
const diagnostic = @import("diagnostic.zig");
const Diagnostics = diagnostic.Diagnostics;

const Graph = graph.Graph;
const Property = graph.Property;
const SheetData = xlsx.SheetData;
const Row = xlsx.Row;

pub const IngestStats = struct {
    requirement_count: u32 = 0,
    user_need_count: u32 = 0,
    test_group_count: u32 = 0,
    test_count: u32 = 0,
    risk_count: u32 = 0,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Ingest all four XLSX sheets into g.
/// Call order: User Needs → Tests → Requirements → Risks
/// (so that edge targets exist before edges are created).
pub fn ingest(g: *Graph, sheets: []const SheetData) !void {
    var d = Diagnostics.init(g.arena.child_allocator);
    defer d.deinit();
    _ = try ingestValidated(g, sheets, &d);
}

/// Validated ingest: appends diagnostics, returns counts.
pub fn ingestValidated(g: *Graph, sheets: []const SheetData, diag: *Diagnostics) !IngestStats {
    var stats = IngestStats{};
    // Order matters for edge resolution
    if (resolveTab(sheets, "User Needs", user_needs_synonyms, diag)) |s| {
        try ingestUserNeeds(g, s, diag, &stats);
    } else {
        try diag.info(diagnostic.E.optional_tab_missing, .tab_discovery, null, null,
            "'User Needs' tab not found — user need traceability will be absent", .{});
    }
    if (resolveTab(sheets, "Tests", tests_synonyms, diag)) |s| {
        try ingestTests(g, s, diag, &stats);
    } else {
        try diag.info(diagnostic.E.optional_tab_missing, .tab_discovery, null, null,
            "'Tests' tab not found — test coverage will not be tracked", .{});
    }
    // Requirements tab is mandatory
    const req_sheet = resolveTab(sheets, "Requirements", requirements_synonyms, diag) orelse {
        try diag.add(.err, diagnostic.E.requirements_tab_missing, .tab_discovery, null, null,
            "No 'Requirements' tab found. Available tabs: {s}", .{tabList(sheets, diag)});
        return diagnostic.ValidationError.RequirementsTabNotFound;
    };
    try ingestRequirements(g, req_sheet, diag, &stats);
    if (resolveTab(sheets, "Risks", risks_synonyms, diag)) |s| {
        try ingestRisks(g, s, diag, &stats);
    } else {
        try diag.info(diagnostic.E.optional_tab_missing, .tab_discovery, null, null,
            "'Risks' tab not found — risk register will not be tracked", .{});
    }
    try semanticValidate(g, diag);
    return stats;
}

/// Build a comma-joined list of all sheet names using the diag arena.
fn tabList(sheets: []const SheetData, diag: *Diagnostics) []const u8 {
    if (sheets.len == 0) return "(none)";
    var out: std.ArrayList(u8) = .empty;
    for (sheets, 0..) |s, i| {
        if (i > 0) out.appendSlice(diag.arena.allocator(), ", ") catch return sheets[0].name;
        out.appendSlice(diag.arena.allocator(), s.name) catch return sheets[0].name;
    }
    return out.toOwnedSlice(diag.arena.allocator()) catch sheets[0].name;
}

// ---------------------------------------------------------------------------
// Tab synonym lists (Layer 3)
// ---------------------------------------------------------------------------

const user_needs_synonyms = &[_][]const u8{
    "needs", "user requirements", "stakeholder needs", "user stories",
    "stakeholder requirements", "voice of customer", "voc",
};
const requirements_synonyms = &[_][]const u8{
    "reqs", "requirements list", "system requirements", "functional requirements",
    "product requirements", "req", "design inputs",
};
const tests_synonyms = &[_][]const u8{
    "test plan", "test cases", "test matrix", "verification",
    "verification tests", "test procedures", "v&v",
};
const risks_synonyms = &[_][]const u8{
    "risk register", "risk analysis", "risk assessment", "fmea",
    "hazard analysis", "risk matrix", "risk log",
};

// ---------------------------------------------------------------------------
// Tab resolution (Layer 3)
// ---------------------------------------------------------------------------

/// Resolve a tab from sheets using tiered matching.
/// Returns null if no match (caller decides if that's an error).
fn resolveTab(sheets: []const SheetData, canonical: []const u8, synonyms: []const []const u8, diag: *Diagnostics) ?SheetData {
    // Tier 1: case-insensitive exact match on canonical name
    var t1_match: ?SheetData = null;
    var t1_count: usize = 0;
    for (sheets) |s| {
        if (std.ascii.eqlIgnoreCase(s.name, canonical)) {
            if (t1_match == null) t1_match = s;
            t1_count += 1;
        }
    }
    if (t1_count > 1) {
        diag.warn(diagnostic.E.ambiguous_tab, .tab_discovery, null, null,
            "multiple tabs match '{s}' exactly; using first match '{s}'",
            .{canonical, t1_match.?.name}) catch {};
    }
    if (t1_match != null) return t1_match;

    // Tier 2: synonym exact match — collect ALL synonym matches, warn if ambiguous
    var t2_match: ?SheetData = null;
    var t2_syn: []const u8 = "";
    var t2_count: usize = 0;
    outer: for (synonyms) |syn| {
        for (sheets) |s| {
            if (std.ascii.eqlIgnoreCase(s.name, syn)) {
                if (t2_match == null) {
                    t2_match = s;
                    t2_syn = syn;
                } else if (!std.mem.eql(u8, t2_match.?.name, s.name)) {
                    t2_count += 1;
                    // Don't break — keep scanning so we get the count right
                }
                // First synonym wins; synonyms ordered by preference
                break :outer;
            }
        }
    }
    // Also scan remaining synonyms to count additional hits
    if (t2_match != null) {
        for (synonyms) |syn| {
            for (sheets) |s| {
                if (std.ascii.eqlIgnoreCase(s.name, syn) and
                    !std.mem.eql(u8, s.name, t2_match.?.name))
                {
                    t2_count += 1;
                    break;
                }
            }
        }
        if (t2_count > 0) {
            diag.warn(diagnostic.E.ambiguous_tab, .tab_discovery, null, null,
                "multiple tabs match '{s}' synonyms; using '{s}'",
                .{canonical, t2_match.?.name}) catch {};
        } else {
            diag.info(diagnostic.E.tab_synonym_match, .tab_discovery, null, null,
                "'{s}' tab matched by synonym '{s}'", .{canonical, t2_syn}) catch {};
        }
        return t2_match;
    }

    // Tier 3: substring match (longest sheet name that contains canonical, or vice versa)
    var best: ?SheetData = null;
    var best_len: usize = 0;
    var t3_count: usize = 0;
    for (sheets) |s| {
        const s_lower_buf = toLowerBuf(s.name);
        const c_lower_buf = toLowerBuf(canonical);
        const s_lower = s_lower_buf[0..s.name.len];
        const c_lower = c_lower_buf[0..canonical.len];
        if (std.mem.indexOf(u8, s_lower, c_lower) != null or
            std.mem.indexOf(u8, c_lower, s_lower) != null)
        {
            t3_count += 1;
            if (s.name.len > best_len) {
                best = s;
                best_len = s.name.len;
            }
        }
    }
    if (best) |b| {
        if (t3_count > 1) {
            diag.warn(diagnostic.E.ambiguous_tab, .tab_discovery, null, null,
                "multiple tabs substring-match '{s}'; using longest match '{s}'",
                .{canonical, b.name}) catch {};
        } else {
            diag.info(diagnostic.E.tab_substring_match, .tab_discovery, null, null,
                "'{s}' tab matched by substring '{s}'", .{canonical, b.name}) catch {};
        }
        return b;
    }

    // Tier 4: Levenshtein ≤ 2 against canonical
    var t4_match: ?SheetData = null;
    var t4_count: usize = 0;
    for (sheets) |s| {
        if (levenshtein(s.name, canonical) <= 2) {
            if (t4_match == null) t4_match = s;
            t4_count += 1;
        }
    }
    if (t4_match) |m| {
        if (t4_count > 1) {
            diag.warn(diagnostic.E.ambiguous_tab, .tab_discovery, null, null,
                "multiple tabs fuzzy-match '{s}'; using '{s}'",
                .{canonical, m.name}) catch {};
        } else {
            diag.info(diagnostic.E.tab_fuzzy_match, .tab_discovery, null, null,
                "'{s}' tab matched by fuzzy match '{s}'", .{canonical, m.name}) catch {};
        }
        return m;
    }

    return null;
}

/// Stack-allocated lowercase conversion for short strings (up to 128 chars).
fn toLowerBuf(s: []const u8) [128]u8 {
    var buf: [128]u8 = undefined;
    const len = @min(s.len, buf.len);
    for (s[0..len], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

/// Levenshtein distance, max input length 31 (stack-allocated DP).
fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len > 31 or b.len > 31) return 999;
    var dp: [32][32]u16 = undefined;
    for (0..a.len + 1) |i| dp[i][0] = @intCast(i);
    for (0..b.len + 1) |j| dp[0][j] = @intCast(j);
    for (1..a.len + 1) |i| {
        for (1..b.len + 1) |j| {
            const cost: u16 = if (std.ascii.toLower(a[i - 1]) == std.ascii.toLower(b[j - 1])) 0 else 1;
            dp[i][j] = @min(dp[i-1][j] + 1, @min(dp[i][j-1] + 1, dp[i-1][j-1] + cost));
        }
    }
    return dp[a.len][b.len];
}

// ---------------------------------------------------------------------------
// Column synonym lists (Layer 4)
// ---------------------------------------------------------------------------

// User Needs
const un_id_syns      = &[_][]const u8{ "User Need ID", "UN ID", "Need ID", "Stakeholder Need ID", "Item #", "Item ID", "Number", "#" };
const un_stmt_syns    = &[_][]const u8{ "Description", "Need Statement", "User Need", "Need Description", "Requirement Statement" };
const un_source_syns  = &[_][]const u8{ "Source", "Origin", "Stakeholder", "Customer", "Requestor", "Originator" };
const un_pri_syns     = &[_][]const u8{ "Importance", "Criticality", "Rank", "Level" };

// Requirements
const req_id_syns     = &[_][]const u8{ "Requirement ID", "Req ID", "REQ #", "Item ID", "Requirement Number", "Req Number", "Number", "#" };
const req_un_syns     = &[_][]const u8{ "User Need ID", "User Need iD", "User Need", "Traces To", "Parent Need", "Source Need", "UN ID", "Derived From", "Source", "Stakeholder Need" };
const req_stmt_syns   = &[_][]const u8{ "Requirement Statement", "Description", "Requirement Text", "Requirement Description", "Req Statement" };
const req_pri_syns    = &[_][]const u8{ "Importance", "Criticality", "Rank", "Level" };
const req_tg_syns     = &[_][]const u8{ "Test Group", "Verification Method", "Verification ID", "TG ID", "Verified By", "Test Ref", "Verification", "Test ID" };
const req_status_syns = &[_][]const u8{ "Status", "State", "Requirement Status", "Lifecycle" };
const req_notes_syns  = &[_][]const u8{ "Comments", "Remarks", "Additional Notes", "Comment" };

// Tests
const tst_tgid_syns   = &[_][]const u8{ "TG ID", "Group ID", "Test Suite ID", "Test Group", "Group", "Suite ID" };
const tst_id_syns     = &[_][]const u8{ "ID", "Test Number", "Test Case ID", "TC ID", "Test Case", "Case ID" };
const tst_type_syns   = &[_][]const u8{ "Type", "Verification Type", "Method Type", "Test Category" };
const tst_method_syns = &[_][]const u8{ "Method", "Verification Method", "Test Approach", "Approach", "Technique" };

// Risks
const risk_id_syns    = &[_][]const u8{ "ID", "Risk Number", "Risk #", "Hazard ID", "FMEA ID", "Risk Item", "Number" };
const risk_desc_syns  = &[_][]const u8{ "Description", "Risk Description", "Hazard Description", "Risk Statement", "Failure Mode", "Hazard" };
const risk_isev_syns  = &[_][]const u8{ "Severity", "Initial Sev", "Pre-mitigation Severity", "Sev", "S", "Initial S" };
const risk_ilik_syns  = &[_][]const u8{ "Likelihood", "Initial Lik", "Probability", "Pre-mitigation Likelihood", "Prob", "Occurrence", "P", "Initial P" };
const risk_mit_syns   = &[_][]const u8{ "Mitigation", "Control", "Risk Control", "Mitigation Action", "Risk Treatment", "Control Measure", "Action" };
const risk_req_syns   = &[_][]const u8{ "Linked Requirement", "Mitigating Requirement", "Control Requirement", "REQ ID", "Requirement ID", "Mitigated By", "Linked REQ ID", "Linked REQ" };
const risk_rsev_syns  = &[_][]const u8{ "Residual Severity", "Residual Sev", "Post-mitigation Severity", "RS", "Res Sev" };
const risk_rlik_syns  = &[_][]const u8{ "Residual Likelihood", "Residual Lik", "Post-mitigation Likelihood", "RP", "Residual Occurrence", "Res Lik" };

// ---------------------------------------------------------------------------
// Column resolution (Layer 4)
// ---------------------------------------------------------------------------

/// Resolve column index by canonical name + synonyms. Leftmost wins on ambiguity.
/// `is_id_col`: enables pattern-based heuristic fallback when name lookup fails.
/// `data_rows`: needed only for heuristic; pass empty slice for non-ID fields.
fn resolveCol(
    headers: Row,
    data_rows: []const Row,
    canonical: []const u8,
    synonyms: []const []const u8,
    tab_name: []const u8,
    diag: *Diagnostics,
    is_id_col: bool,
) ?usize {
    // Tier 1: canonical name (case-insensitive, trim whitespace)
    var found: ?usize = null;
    var found_label: []const u8 = canonical;
    var ambig_count: usize = 0;

    for (headers, 0..) |h, i| {
        const ht = std.mem.trim(u8, h, " \t");
        if (std.ascii.eqlIgnoreCase(ht, canonical)) {
            if (found == null) { found = i; }
            else { ambig_count += 1; if (i < found.?) { found = i; } }
        }
    }
    if (found != null) {
        if (ambig_count > 0) diag.warn(diagnostic.E.column_ambiguous, .column_mapping, tab_name, null,
            "multiple columns match '{s}'; using leftmost (col {d})", .{canonical, found.? + 1}) catch {};
        return found;
    }

    // Tier 2: synonyms (iterate in preference order; collect leftmost across all)
    for (synonyms) |syn| {
        for (headers, 0..) |h, i| {
            const ht = std.mem.trim(u8, h, " \t");
            if (std.ascii.eqlIgnoreCase(ht, syn)) {
                if (found == null) { found = i; found_label = syn; }
                else if (i < found.?) { found = i; found_label = syn; ambig_count += 1; }
                else { ambig_count += 1; }
            }
        }
    }
    if (found != null) {
        if (ambig_count > 0) {
            diag.warn(diagnostic.E.column_ambiguous, .column_mapping, tab_name, null,
                "multiple columns match '{s}' field; using leftmost", .{canonical}) catch {};
        } else {
            diag.info(diagnostic.E.column_synonym_match, .column_mapping, tab_name, null,
                "'{s}' column matched by synonym '{s}'", .{canonical, found_label}) catch {};
        }
        return found;
    }

    // Tier 3 (ID columns only): pattern heuristic — column where >50% of cells look like IDs
    if (is_id_col and data_rows.len > 0) {
        const col_count = headers.len;
        var best_col: ?usize = null;
        var best_score: usize = 0;
        for (0..col_count) |ci| {
            var matches: usize = 0;
            for (data_rows) |row| {
                if (ci < row.len and looksLikeId(row[ci])) matches += 1;
            }
            if (matches > data_rows.len / 2 and matches > best_score) {
                best_score = matches;
                best_col = ci;
            }
        }
        if (best_col) |bc| {
            diag.warn(diagnostic.E.id_column_guessed, .column_mapping, tab_name, null,
                "ID column not found by name; guessing column {d} from data pattern", .{bc + 1}) catch {};
            return bc;
        }
        diag.warn(diagnostic.E.id_column_missing, .column_mapping, tab_name, null,
            "ID column not found for '{s}' tab; rows will be skipped", .{tab_name}) catch {};
    }

    return null;
}

/// Return true if a cell value looks like a typed ID: 1–6 uppercase letters, dash, 1–6 digits.
fn looksLikeId(s: []const u8) bool {
    if (s.len < 3 or s.len > 20) return false;
    var i: usize = 0;
    var lc: usize = 0;
    while (i < s.len and s[i] >= 'A' and s[i] <= 'Z') : (i += 1) lc += 1;
    if (lc == 0 or lc > 6) return false;
    if (i >= s.len or s[i] != '-') return false;
    i += 1;
    var dc: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) dc += 1;
    return dc > 0 and i == s.len;
}

// ---------------------------------------------------------------------------
// Layer 5: row normalization helpers
// ---------------------------------------------------------------------------

/// Returns true if the string is a blank-equivalent value that signals an
/// intentionally-absent field (not a traceability gap).
pub fn isBlankEquivalent(s: []const u8) bool {
    if (s.len == 0) return true;
    const blanks = [_][]const u8{ "n/a", "na", "tbd", "tbc", "none", "-", "\xe2\x80\x94" };
    for (blanks) |b| {
        if (std.ascii.eqlIgnoreCase(s, b)) return true;
    }
    return false;
}

/// Returns true if a row looks like a visual section divider or sub-header
/// rather than a real data row. Checked before ID extraction; silent skip.
fn isSectionDivider(row: Row, id_col: ?usize) bool {
    // If the ID cell is non-empty, this is real data — never a divider.
    if (id_col) |c| {
        if (c < row.len and row[c].len > 0) return false;
    }
    // Count non-empty cells and capture the single content string if ≤ 1.
    var non_empty: usize = 0;
    var content: []const u8 = "";
    for (row) |c| {
        if (c.len > 0) {
            non_empty += 1;
            content = c;
        }
    }
    if (non_empty == 0) return true; // blank row
    if (non_empty > 1) return false; // multiple cells → real data, just missing ID
    // Single non-empty cell with no ID: treat as divider if it looks like a header.
    if (content.len < 15) return true;
    if (std.mem.indexOf(u8, content, "---") != null or
        std.mem.indexOf(u8, content, "===") != null) return true;
    if (std.ascii.indexOfIgnoreCase(content, "section") != null) return true;
    // All alphabetic characters are uppercase → section heading like "GENERAL"
    var all_caps = true;
    for (content) |c| {
        if (std.ascii.isAlphabetic(c) and !std.ascii.isUpper(c)) {
            all_caps = false;
            break;
        }
    }
    return all_caps;
}

/// Normalize an ID cell: BOM/whitespace via normalizeCell, strip parenthetical
/// suffix, strip leading/trailing hyphens, uppercase. Warns on non-trivial changes.
fn normalizeId(raw: []const u8, alloc: Allocator, diag: *Diagnostics, tab: []const u8, row_num: u32) ![]const u8 {
    const normed = try xlsx.normalizeCell(raw, alloc);
    if (normed.len == 0) return normed;

    // Strip parenthetical suffix: "REQ-001 (old)" → "REQ-001"
    var result = normed;
    if (std.mem.indexOf(u8, normed, "(")) |paren_pos| {
        const before = std.mem.trimRight(u8, normed[0..paren_pos], " ");
        if (before.len > 0) {
            try diag.warn(diagnostic.E.id_paren_stripped, .row_parsing, tab, row_num,
                "ID '{s}': stripped parenthetical suffix → '{s}'", .{ normed, before });
            result = try alloc.dupe(u8, before);
        }
    }

    // Strip leading/trailing hyphens: "-REQ-001-" → "REQ-001"
    const stripped = std.mem.trim(u8, result, "-");
    if (stripped.len < result.len) {
        try diag.warn(diagnostic.E.id_hyphen_stripped, .row_parsing, tab, row_num,
            "ID '{s}': stripped leading/trailing hyphens → '{s}'", .{ result, stripped });
        result = try alloc.dupe(u8, stripped);
    }

    // Uppercase all characters
    const upper = try alloc.alloc(u8, result.len);
    for (result, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    return upper;
}

/// Parse a severity/likelihood numeric field that may be expressed as text
/// ("high", "H", "III") or a number. Returns null for blank-equivalents or
/// unmappable values; warns on fractional or unrecognized input.
fn parseNumericField(raw: []const u8, diag: *Diagnostics, tab: []const u8, row_num: u32, field: []const u8) !?[]const u8 {
    if (isBlankEquivalent(raw)) return null;

    const Mapping = struct { text: []const u8, num: []const u8 };
    const mappings = [_]Mapping{
        .{ .text = "critical",     .num = "5" }, .{ .text = "catastrophic", .num = "5" },
        .{ .text = "very high",    .num = "5" },
        .{ .text = "high",         .num = "4" }, .{ .text = "h",            .num = "4" },
        .{ .text = "medium",       .num = "3" }, .{ .text = "m",            .num = "3" },
        .{ .text = "moderate",     .num = "3" },
        .{ .text = "low",          .num = "2" }, .{ .text = "l",            .num = "2" },
        .{ .text = "negligible",   .num = "1" }, .{ .text = "minimal",      .num = "1" },
        .{ .text = "very low",     .num = "1" }, .{ .text = "n",            .num = "1" },
        // Roman numerals
        .{ .text = "v",   .num = "5" }, .{ .text = "iv",  .num = "4" },
        .{ .text = "iii", .num = "3" }, .{ .text = "ii",  .num = "2" },
        .{ .text = "i",   .num = "1" },
    };
    for (mappings) |mp| {
        if (std.ascii.eqlIgnoreCase(raw, mp.text)) return mp.num;
    }

    const trimmed = std.mem.trim(u8, raw, " ");

    // ".0" suffix → strip silently and return integer part
    if (std.mem.endsWith(u8, trimmed, ".0")) return trimmed[0 .. trimmed.len - 2];

    // Already a valid integer
    if (std.fmt.parseInt(i64, trimmed, 10)) |_| return trimmed else |_| {}

    // Fractional float → warn and ignore
    if (std.fmt.parseFloat(f64, trimmed)) |_| {
        try diag.warn(diagnostic.E.numeric_fractional, .row_parsing, tab, row_num,
            "{s}: fractional value '{s}' cannot be used as severity/likelihood; ignoring", .{ field, raw });
        return null;
    } else |_| {}

    // Completely unrecognized
    try diag.warn(diagnostic.E.numeric_unrecognized, .row_parsing, tab, row_num,
        "{s}: cannot parse '{s}' as numeric severity/likelihood; ignoring", .{ field, raw });
    return null;
}

/// Split a multi-value cross-reference cell on `,`, `;`, `/`, and newlines.
/// Trims each token; returns only non-empty pieces.
pub fn splitIds(raw: []const u8, alloc: Allocator) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, raw, ",;/\n\r\t");
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " ");
        if (trimmed.len > 0) try result.append(alloc, trimmed);
    }
    return result.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Layer 7: cross-reference validation helper
// ---------------------------------------------------------------------------

/// Verify that `ref_id` exists in the graph with `expected_type`.
/// Emits a WARN diagnostic but does NOT prevent the edge from being added —
/// preserving traceability intent even for dangling references.
fn checkCrossRef(
    g: *const Graph,
    ref_id: []const u8,
    expected_type: graph.NodeType,
    diag: *Diagnostics,
    tab: []const u8,
    row_num: u32,
) !void {
    if (g.getNode(ref_id)) |target| {
        if (target.node_type != expected_type) {
            try diag.warn(diagnostic.E.ref_wrong_type, .cross_ref, tab, row_num,
                "reference '{s}' resolves to a {s} node but a {s} was expected here — check the ID",
                .{ ref_id, target.node_type.toString(), expected_type.toString() });
        }
        // Exists and correct type — no warning needed.
    } else {
        // Not found: collect up to 5 available IDs of the expected type as a hint.
        var samples: [5][]const u8 = undefined;
        var sample_count: usize = 0;
        var total: usize = 0;
        var it = g.nodes.valueIterator();
        while (it.next()) |ptr| {
            if (ptr.*.node_type == expected_type) {
                total += 1;
                if (sample_count < 5) {
                    samples[sample_count] = ptr.*.id;
                    sample_count += 1;
                }
            }
        }
        if (total == 0) {
            try diag.warn(diagnostic.E.ref_not_found, .cross_ref, tab, row_num,
                "reference '{s}' not found (no {s} nodes exist in the graph)",
                .{ ref_id, expected_type.toString() });
        } else {
            const a = diag.arena.allocator();
            var buf: std.ArrayList(u8) = .empty;
            for (samples[0..sample_count], 0..) |s, i| {
                if (i > 0) try buf.appendSlice(a, ", ");
                try buf.appendSlice(a, s);
            }
            try diag.warn(diagnostic.E.ref_not_found, .cross_ref, tab, row_num,
                "reference '{s}' not found; available {s} IDs: {s} ({d} total)",
                .{ ref_id, expected_type.toString(), buf.items, total });
        }
    }
}

// ---------------------------------------------------------------------------
// Sheet finders and column helpers (legacy)
// ---------------------------------------------------------------------------

fn findSheet(sheets: []const SheetData, name: []const u8) ?SheetData {
    for (sheets) |s| if (std.mem.eql(u8, s.name, name)) return s;
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

fn ingestUserNeeds(g: *Graph, sheet: SheetData, diag: *Diagnostics, stats: *IngestStats) !void {
    if (sheet.rows.len < 2) return;
    const headers = sheet.rows[0];
    const data = sheet.rows[1..];
    const a = diag.arena.allocator();

    const c_id   = resolveCol(headers, data, "ID",                       un_id_syns,     sheet.name, diag, true);
    const c_stmt = resolveCol(headers, &.{}, "Statement",                un_stmt_syns,   sheet.name, diag, false);
    const c_src  = resolveCol(headers, &.{}, "Source of Need Statement", un_source_syns, sheet.name, diag, false);
    const c_pri  = resolveCol(headers, &.{}, "Priority",                 un_pri_syns,    sheet.name, diag, false);

    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();

    for (data, 0..) |row, ri| {
        if (isSectionDivider(row, c_id)) continue;
        const raw_id = cell(row, c_id);
        if (raw_id.len == 0) {
            try diag.warn(diagnostic.E.row_no_id, .row_parsing, sheet.name, @intCast(ri + 2),
                "row has content but ID column is empty — skipping", .{});
            continue;
        }
        const id = try normalizeId(raw_id, a, diag, sheet.name, @intCast(ri + 2));
        if (id.len == 0) continue;
        if (seen.contains(id)) {
            try diag.warn(diagnostic.E.duplicate_id, .row_parsing, sheet.name, @intCast(ri + 2),
                "duplicate ID '{s}' — skipping", .{id});
            continue;
        }
        try seen.put(id, {});

        try g.addNode(id, .user_need, &.{
            .{ .key = "statement", .value = cell(row, c_stmt) },
            .{ .key = "source", .value = cell(row, c_src) },
            .{ .key = "priority", .value = cell(row, c_pri) },
        });
        stats.user_need_count += 1;
    }
}

fn ingestTests(g: *Graph, sheet: SheetData, diag: *Diagnostics, stats: *IngestStats) !void {
    if (sheet.rows.len < 2) return;
    const headers = sheet.rows[0];
    const data = sheet.rows[1..];
    const a = diag.arena.allocator();

    const c_tgid   = resolveCol(headers, data, "Test Group ID", tst_tgid_syns,   sheet.name, diag, true);
    const c_tid    = resolveCol(headers, data, "Test ID",       tst_id_syns,     sheet.name, diag, false);
    const c_type   = resolveCol(headers, &.{}, "Test Type",     tst_type_syns,   sheet.name, diag, false);
    const c_method = resolveCol(headers, &.{}, "Test Method",   tst_method_syns, sheet.name, diag, false);

    // Track test-case IDs for duplicate detection (TG-IDs repeat intentionally)
    var seen_tests = std.StringHashMap(void).init(a);
    defer seen_tests.deinit();

    for (data, 0..) |row, ri| {
        if (isSectionDivider(row, c_tgid)) continue;
        const raw_tg = cell(row, c_tgid);
        const raw_t  = cell(row, c_tid);
        if (raw_tg.len == 0 and raw_t.len == 0) continue;

        const tg_id = if (raw_tg.len > 0)
            try normalizeId(raw_tg, a, diag, sheet.name, @intCast(ri + 2))
        else "";
        const t_id = if (raw_t.len > 0)
            try normalizeId(raw_t, a, diag, sheet.name, @intCast(ri + 2))
        else "";

        // Add test group (idempotent — multiple rows share same TG-ID)
        if (tg_id.len > 0) {
            const was_new = !g.nodes.contains(tg_id);
            try g.addNode(tg_id, .test_group, &.{});
            if (was_new) stats.test_group_count += 1;
        }

        // Add individual test and link to group
        if (t_id.len > 0 and tg_id.len > 0) {
            if (seen_tests.contains(t_id)) {
                try diag.warn(diagnostic.E.duplicate_test_id, .row_parsing, sheet.name, @intCast(ri + 2),
                    "duplicate Test ID '{s}' — skipping", .{t_id});
                continue;
            }
            try seen_tests.put(t_id, {});
            try g.addNode(t_id, .test_case, &.{
                .{ .key = "test_type", .value = cell(row, c_type) },
                .{ .key = "test_method", .value = cell(row, c_method) },
            });
            try g.addEdge(tg_id, t_id, .has_test);
            stats.test_count += 1;
        }
    }
}

fn ingestRequirements(g: *Graph, sheet: SheetData, diag: *Diagnostics, stats: *IngestStats) !void {
    if (sheet.rows.len < 2) return;
    const headers = sheet.rows[0];
    const data = sheet.rows[1..];
    const a = diag.arena.allocator();

    const c_id     = resolveCol(headers, data, "ID",               req_id_syns,     sheet.name, diag, true);
    const c_un     = resolveCol(headers, &.{}, "User Need iD",     req_un_syns,     sheet.name, diag, false);
    const c_stmt   = resolveCol(headers, &.{}, "Statement",        req_stmt_syns,   sheet.name, diag, false);
    const c_pri    = resolveCol(headers, &.{}, "Priority",         req_pri_syns,    sheet.name, diag, false);
    const c_tgid   = resolveCol(headers, &.{}, "Test Group ID",    req_tg_syns,     sheet.name, diag, false);
    const c_status = resolveCol(headers, &.{}, "Lifecycle Status", req_status_syns, sheet.name, diag, false);
    const c_notes  = resolveCol(headers, &.{}, "Notes",            req_notes_syns,  sheet.name, diag, false);

    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();

    for (data, 0..) |row, ri| {
        if (isSectionDivider(row, c_id)) continue;
        const raw_id = cell(row, c_id);
        if (raw_id.len == 0) {
            try diag.warn(diagnostic.E.row_no_id, .row_parsing, sheet.name, @intCast(ri + 2),
                "row has content but ID column is empty — skipping", .{});
            continue;
        }
        const id = try normalizeId(raw_id, a, diag, sheet.name, @intCast(ri + 2));
        if (id.len == 0) continue;
        if (seen.contains(id)) {
            try diag.warn(diagnostic.E.duplicate_id, .row_parsing, sheet.name, @intCast(ri + 2),
                "duplicate ID '{s}' — skipping", .{id});
            continue;
        }
        try seen.put(id, {});

        try g.addNode(id, .requirement, &.{
            .{ .key = "statement", .value = cell(row, c_stmt) },
            .{ .key = "priority", .value = cell(row, c_pri) },
            .{ .key = "status", .value = cell(row, c_status) },
            .{ .key = "notes", .value = cell(row, c_notes) },
        });
        stats.requirement_count += 1;

        // DERIVES_FROM edges: Requirement → UserNeed (multi-value, skip blanks)
        const un_raw = cell(row, c_un);
        if (!isBlankEquivalent(un_raw)) {
            for (try splitIds(un_raw, a)) |part| {
                const un_id = try normalizeId(part, a, diag, sheet.name, @intCast(ri + 2));
                if (un_id.len == 0) continue;
                try checkCrossRef(g, un_id, .user_need, diag, sheet.name, @intCast(ri + 2));
                try g.addEdge(id, un_id, .derives_from);
            }
        }

        // TESTED_BY edges: Requirement → TestGroup (multi-value, skip blanks)
        const tg_raw = cell(row, c_tgid);
        if (!isBlankEquivalent(tg_raw)) {
            for (try splitIds(tg_raw, a)) |part| {
                const tg_id = try normalizeId(part, a, diag, sheet.name, @intCast(ri + 2));
                if (tg_id.len == 0) continue;
                try checkCrossRef(g, tg_id, .test_group, diag, sheet.name, @intCast(ri + 2));
                try g.addEdge(id, tg_id, .tested_by);
            }
        }
    }
}

fn ingestRisks(g: *Graph, sheet: SheetData, diag: *Diagnostics, stats: *IngestStats) !void {
    if (sheet.rows.len < 2) return;
    const headers = sheet.rows[0];
    const data = sheet.rows[1..];
    const a = diag.arena.allocator();

    const c_id   = resolveCol(headers, data, "Risk ID",             risk_id_syns,   sheet.name, diag, true);
    const c_desc = resolveCol(headers, &.{}, "Description",         risk_desc_syns, sheet.name, diag, false);
    const c_isev = resolveCol(headers, &.{}, "Initial Severity",    risk_isev_syns, sheet.name, diag, false);
    const c_ilik = resolveCol(headers, &.{}, "Initial Likelihood",  risk_ilik_syns, sheet.name, diag, false);
    const c_mit  = resolveCol(headers, &.{}, "Mitigation",          risk_mit_syns,  sheet.name, diag, false);
    const c_req  = resolveCol(headers, &.{}, "Linked REQ",          risk_req_syns,  sheet.name, diag, false);
    const c_rsev = resolveCol(headers, &.{}, "Residual Severity",   risk_rsev_syns, sheet.name, diag, false);
    const c_rlik = resolveCol(headers, &.{}, "Residual Likelihood", risk_rlik_syns, sheet.name, diag, false);

    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();

    for (data, 0..) |row, ri| {
        if (isSectionDivider(row, c_id)) continue;
        const raw_id = cell(row, c_id);
        if (raw_id.len == 0) {
            try diag.warn(diagnostic.E.row_no_id, .row_parsing, sheet.name, @intCast(ri + 2),
                "row has content but ID column is empty — skipping", .{});
            continue;
        }
        const id = try normalizeId(raw_id, a, diag, sheet.name, @intCast(ri + 2));
        if (id.len == 0) continue;
        if (seen.contains(id)) {
            try diag.warn(diagnostic.E.duplicate_id, .row_parsing, sheet.name, @intCast(ri + 2),
                "duplicate ID '{s}' — skipping", .{id});
            continue;
        }
        try seen.put(id, {});

        // Parse severity/likelihood through text-mapping layer
        const isev = try parseNumericField(cell(row, c_isev), diag, sheet.name, @intCast(ri + 2), "Initial Severity") orelse "";
        const ilik = try parseNumericField(cell(row, c_ilik), diag, sheet.name, @intCast(ri + 2), "Initial Likelihood") orelse "";
        const rsev = try parseNumericField(cell(row, c_rsev), diag, sheet.name, @intCast(ri + 2), "Residual Severity") orelse "";
        const rlik = try parseNumericField(cell(row, c_rlik), diag, sheet.name, @intCast(ri + 2), "Residual Likelihood") orelse "";

        try g.addNode(id, .risk, &.{
            .{ .key = "description",          .value = cell(row, c_desc) },
            .{ .key = "initial_severity",     .value = isev },
            .{ .key = "initial_likelihood",   .value = ilik },
            .{ .key = "mitigation",           .value = cell(row, c_mit) },
            .{ .key = "residual_severity",    .value = rsev },
            .{ .key = "residual_likelihood",  .value = rlik },
        });
        stats.risk_count += 1;

        // MITIGATED_BY edges: Risk → Requirement (multi-value, skip blanks)
        const req_raw = cell(row, c_req);
        if (!isBlankEquivalent(req_raw)) {
            for (try splitIds(req_raw, a)) |part| {
                const req_id = try normalizeId(part, a, diag, sheet.name, @intCast(ri + 2));
                if (req_id.len == 0) continue;
                try checkCrossRef(g, req_id, .requirement, diag, sheet.name, @intCast(ri + 2));
                try g.addEdge(id, req_id, .mitigated_by);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Semantic validation (Layer 6)
// ---------------------------------------------------------------------------

const vague_words = &[_][]const u8{
    "appropriate", "adequate", "reasonable", "user-friendly", "fast",
    "reliable", "safe", "sufficient", "timely", "as needed", "if necessary",
    "etc.", "and/or",
};

/// Return true if the graph has any edge from `from_id` with the given label.
/// Scans edges directly — no allocation required.
fn hasEdgeFrom(g: *const Graph, from_id: []const u8, label: graph.EdgeLabel) bool {
    for (g.edges.items) |e| {
        if (e.label == label and std.mem.eql(u8, e.from_id, from_id)) return true;
    }
    return false;
}

fn semanticValidate(g: *const Graph, diag: *Diagnostics) !void {
    var it = g.nodes.valueIterator();
    while (it.next()) |node_ptr| {
        const node = node_ptr.*;
        switch (node.node_type) {
            .requirement => {
                const stmt = node.get("statement") orelse "";
                if (stmt.len == 0) {
                    try diag.warn(diagnostic.E.req_empty, .semantic, null, null,
                        "REQ {s}: empty requirement statement", .{node.id});
                    continue;
                }
                if (stmt.len < 10) {
                    try diag.warn(diagnostic.E.req_short, .semantic, null, null,
                        "REQ {s}: statement very short ({d} chars)", .{node.id, stmt.len});
                }
                // "shall" presence + compound requirement check
                var shall_count: usize = 0;
                var sp: usize = 0;
                while (sp < stmt.len) {
                    if (std.ascii.indexOfIgnoreCase(stmt[sp..], "shall")) |rel| {
                        shall_count += 1;
                        sp += rel + 5;
                    } else break;
                }
                if (shall_count == 0) {
                    try diag.warn(diagnostic.E.req_no_shall, .semantic, null, null,
                        "REQ {s}: statement has no 'shall'", .{node.id});
                } else if (shall_count > 1) {
                    try diag.warn(diagnostic.E.req_compound, .semantic, null, null,
                        "REQ {s}: compound requirement — {d} 'shall' clauses detected; split into separate requirements",
                        .{ node.id, shall_count });
                }
                // Vague words
                for (vague_words) |vw| {
                    if (std.ascii.indexOfIgnoreCase(stmt, vw) != null) {
                        try diag.warn(diagnostic.E.req_vague, .semantic, null, null,
                            "REQ {s}: vague term '{s}' in statement", .{ node.id, vw });
                    }
                }
                // Obsolete requirement with active trace links
                const status = node.get("status") orelse "";
                if (std.ascii.eqlIgnoreCase(status, "obsolete")) {
                    if (hasEdgeFrom(g, node.id, .derives_from) or
                        hasEdgeFrom(g, node.id, .tested_by))
                    {
                        try diag.warn(diagnostic.E.req_obsolete_traced, .semantic, null, null,
                            "REQ {s}: status is 'obsolete' but still has active trace links",
                            .{node.id});
                    }
                }
            },
            .risk => {
                const isev_s = node.get("initial_severity") orelse "";
                const ilik_s = node.get("initial_likelihood") orelse "";
                const rsev_s = node.get("residual_severity") orelse "";
                const rlik_s = node.get("residual_likelihood") orelse "";

                // Severity/likelihood must both be present or both absent
                if ((isev_s.len > 0) != (ilik_s.len > 0)) {
                    try diag.warn(diagnostic.E.risk_score_mismatch, .semantic, null, null,
                        "Risk {s}: severity and likelihood must both be present or both absent",
                        .{node.id});
                }
                // High-risk score with no mitigation
                const mit = node.get("mitigation") orelse "";
                if (isev_s.len > 0 and ilik_s.len > 0 and mit.len == 0) {
                    const sev = std.fmt.parseInt(u32, isev_s, 10) catch 0;
                    const lik = std.fmt.parseInt(u32, ilik_s, 10) catch 0;
                    if (sev * lik > 12) {
                        try diag.warn(diagnostic.E.risk_unmitigated, .semantic, null, null,
                            "Risk {s}: score {d} > 12 but no mitigation", .{ node.id, sev * lik });
                    }
                }
                // Residual scores present but initial scores absent
                if ((rsev_s.len > 0 or rlik_s.len > 0) and
                    (isev_s.len == 0 or ilik_s.len == 0))
                {
                    try diag.warn(diagnostic.E.risk_residual_no_init, .semantic, null, null,
                        "Risk {s}: residual scores present but initial scores absent", .{node.id});
                }
                // Residual score must not exceed initial score
                if (isev_s.len > 0 and ilik_s.len > 0 and
                    rsev_s.len > 0 and rlik_s.len > 0)
                {
                    const isev = std.fmt.parseInt(u32, isev_s, 10) catch 0;
                    const ilik = std.fmt.parseInt(u32, ilik_s, 10) catch 0;
                    const rsev = std.fmt.parseInt(u32, rsev_s, 10) catch 0;
                    const rlik = std.fmt.parseInt(u32, rlik_s, 10) catch 0;
                    if (isev > 0 and ilik > 0 and rsev * rlik > isev * ilik) {
                        try diag.warn(diagnostic.E.risk_residual_exceeds, .semantic, null, null,
                            "Risk {s}: residual score ({d}) exceeds initial score ({d}) — " ++
                            "mitigation should reduce risk, not increase it",
                            .{ node.id, rsev * rlik, isev * ilik });
                    }
                }
            },
            .test_group => {
                if (!hasEdgeFrom(g, node.id, .has_test)) {
                    try diag.warn(diagnostic.E.test_group_empty, .semantic, null, null,
                        "Test group {s} has no test cases", .{node.id});
                }
            },
            else => {},
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

test "resolveTab exact match" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();
    const sheets = &[_]SheetData{
        .{ .name = "Requirements", .rows = &.{} },
        .{ .name = "Risks", .rows = &.{} },
    };
    const found = resolveTab(sheets, "Requirements", requirements_synonyms, &d);
    try testing.expect(found != null);
    try testing.expectEqualStrings("Requirements", found.?.name);
}

test "resolveTab case-insensitive" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();
    const sheets = &[_]SheetData{
        .{ .name = "REQUIREMENTS", .rows = &.{} },
    };
    const found = resolveTab(sheets, "Requirements", requirements_synonyms, &d);
    try testing.expect(found != null);
}

test "resolveTab synonym match" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();
    const sheets = &[_]SheetData{
        .{ .name = "Reqs", .rows = &.{} },
    };
    const found = resolveTab(sheets, "Requirements", requirements_synonyms, &d);
    try testing.expect(found != null);
    try testing.expectEqualStrings("Reqs", found.?.name);
}

test "resolveTab fuzzy match" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();
    const sheets = &[_]SheetData{
        .{ .name = "Risk", .rows = &.{} }, // levenshtein("Risk","Risks") = 1
    };
    const found = resolveTab(sheets, "Risks", risks_synonyms, &d);
    try testing.expect(found != null);
}

test "resolveTab returns null for no match" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();
    const sheets = &[_]SheetData{
        .{ .name = "Sheet1", .rows = &.{} },
    };
    const found = resolveTab(sheets, "Requirements", requirements_synonyms, &d);
    try testing.expect(found == null);
}

test "levenshtein distances" {
    try testing.expectEqual(@as(usize, 0), levenshtein("abc", "abc"));
    try testing.expectEqual(@as(usize, 1), levenshtein("Risks", "Risk"));
    try testing.expectEqual(@as(usize, 1), levenshtein("Reqts", "Reqs"));
    try testing.expectEqual(@as(usize, 3), levenshtein("abc", "xyz"));
}

test "ingestValidated returns stats" {
    var tmp_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    const sheets = try xlsx.parse(tmp, "test/fixtures/RTMify_Requirements_Tracking_Template.xlsx");

    var g = Graph.init(testing.allocator);
    defer g.deinit();

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    const stats = try ingestValidated(&g, sheets, &d);
    try testing.expect(stats.requirement_count >= 2);
    try testing.expect(stats.user_need_count >= 1);
    try testing.expect(stats.risk_count >= 1);
}

test "semanticValidate warns on missing shall" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system will work correctly" }, // no "shall"
    });

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try semanticValidate(&g, &d);
    try testing.expect(d.warning_count >= 1);

    var found = false;
    for (d.entries.items) |e| {
        if (std.mem.indexOf(u8, e.message, "shall") != null) found = true;
    }
    try testing.expect(found);
}

test "semanticValidate warns on vague terms" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system shall provide adequate performance" },
    });

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (std.mem.indexOf(u8, e.message, "adequate") != null) found = true;
    }
    try testing.expect(found);
}

test "semanticValidate warns on high risk without mitigation" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("RSK-001", .risk, &.{
        .{ .key = "initial_severity", .value = "4" },
        .{ .key = "initial_likelihood", .value = "4" }, // 4*4=16 > 12
        .{ .key = "mitigation", .value = "" },
    });

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (std.mem.indexOf(u8, e.message, "score") != null) found = true;
    }
    try testing.expect(found);
}

test "semanticValidate warns on compound shall" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system shall work and shall also report errors" },
    });

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and std.mem.indexOf(u8, e.message, "compound") != null) found = true;
    }
    try testing.expect(found);
}

test "semanticValidate warns on obsolete with traces" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system shall work" },
        .{ .key = "status", .value = "obsolete" },
    });
    try g.addNode("TG-001", .test_group, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and std.mem.indexOf(u8, e.message, "obsolete") != null) found = true;
    }
    try testing.expect(found);
}

test "semanticValidate warns when residual exceeds initial" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("RSK-001", .risk, &.{
        .{ .key = "initial_severity",    .value = "2" },
        .{ .key = "initial_likelihood",  .value = "2" }, // initial = 4
        .{ .key = "residual_severity",   .value = "3" },
        .{ .key = "residual_likelihood", .value = "3" }, // residual = 9 > 4
        .{ .key = "mitigation",          .value = "Some action" },
    });

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and std.mem.indexOf(u8, e.message, "residual score") != null) found = true;
    }
    try testing.expect(found);
}

test "semanticValidate warns when residual present but initial absent" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("RSK-001", .risk, &.{
        .{ .key = "residual_severity",   .value = "2" },
        .{ .key = "residual_likelihood", .value = "2" },
        // initial_severity and initial_likelihood intentionally absent
    });

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and std.mem.indexOf(u8, e.message, "initial scores absent") != null) found = true;
    }
    try testing.expect(found);
}

test "semanticValidate warns on test group with no tests" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("TG-001", .test_group, &.{});
    // No HAS_TEST edges from TG-001

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and std.mem.indexOf(u8, e.message, "no test cases") != null) found = true;
    }
    try testing.expect(found);
}

test "semanticValidate no warning for test group with tests" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("T-001",  .test_case,  &.{});
    try g.addEdge("TG-001", "T-001", .has_test);

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try semanticValidate(&g, &d);
    for (d.entries.items) |e| {
        if (std.mem.indexOf(u8, e.message, "no test cases") != null) {
            try testing.expect(false); // should not reach here
        }
    }
}

test "resolveCol exact match" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();
    const headers: Row = &.{ "ID", "Statement", "Priority" };
    const col = resolveCol(headers, &.{}, "ID", req_id_syns, "Reqs", &d, false);
    try testing.expectEqual(@as(?usize, 0), col);
}

test "resolveCol synonym match emits info" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();
    const headers: Row = &.{ "Req ID", "Statement" };
    const col = resolveCol(headers, &.{}, "ID", req_id_syns, "Reqs", &d, false);
    try testing.expectEqual(@as(?usize, 0), col);
    // Should emit an INFO about synonym match
    var found_info = false;
    for (d.entries.items) |e| {
        if (e.level == .info and std.mem.indexOf(u8, e.message, "synonym") != null) found_info = true;
    }
    try testing.expect(found_info);
}

test "resolveCol leftmost wins on ambiguity" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();
    // Two columns both match "ID" canonical
    const headers: Row = &.{ "Other", "ID", "Statement", "ID" };
    const col = resolveCol(headers, &.{}, "ID", req_id_syns, "Reqs", &d, false);
    try testing.expectEqual(@as(?usize, 1), col); // leftmost match
    // Should emit a warning
    try testing.expect(d.warning_count >= 1);
}

test "resolveCol heuristic ID detection" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();
    const headers: Row = &.{ "Whatever", "Random Col" };
    const data_rows: []const Row = &.{
        &.{ "REQ-001", "foo" },
        &.{ "REQ-002", "bar" },
        &.{ "REQ-003", "baz" },
    };
    const col = resolveCol(headers, data_rows, "ID", req_id_syns, "Reqs", &d, true);
    // Column 0 has all IDs matching the pattern
    try testing.expectEqual(@as(?usize, 0), col);
    // Should emit a warning about guessing
    var found_warn = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and std.mem.indexOf(u8, e.message, "guessing") != null) found_warn = true;
    }
    try testing.expect(found_warn);
}

test "looksLikeId" {
    try testing.expect(looksLikeId("REQ-001"));
    try testing.expect(looksLikeId("UN-12"));
    try testing.expect(looksLikeId("RSK-101"));
    try testing.expect(!looksLikeId("hello"));
    try testing.expect(!looksLikeId("REQ001"));  // no dash
    try testing.expect(!looksLikeId("req-001"));  // lowercase
    try testing.expect(!looksLikeId(""));
}

test "splitIds comma and semicolon" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parts = try splitIds("UN-001, UN-002; UN-003", a);
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("UN-001", parts[0]);
    try testing.expectEqualStrings("UN-002", parts[1]);
    try testing.expectEqualStrings("UN-003", parts[2]);
}

test "splitIds slash and newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parts = try splitIds("TG-001/TG-002\nTG-003", a);
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("TG-001", parts[0]);
    try testing.expectEqualStrings("TG-002", parts[1]);
    try testing.expectEqualStrings("TG-003", parts[2]);
}

test "splitIds single token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parts = try splitIds("  REQ-001  ", a);
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expectEqualStrings("REQ-001", parts[0]);
}

test "splitIds empty produces no tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parts = try splitIds("", a);
    try testing.expectEqual(@as(usize, 0), parts.len);
}

test "checkCrossRef unresolved ref emits warning with available IDs" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    // Add a user need so the "available" hint is non-empty
    try g.addNode("UN-001", .user_need, &.{});

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try checkCrossRef(&g, "UN-999", .user_need, &d, "Requirements", 3);

    try testing.expect(d.warning_count >= 1);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and
            std.mem.indexOf(u8, e.message, "UN-999") != null and
            std.mem.indexOf(u8, e.message, "UN-001") != null) found = true;
    }
    try testing.expect(found);
}

test "checkCrossRef wrong type emits warning" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    // Add REQ-001 as a requirement, but reference it where a user_need is expected
    try g.addNode("REQ-001", .requirement, &.{});

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try checkCrossRef(&g, "REQ-001", .user_need, &d, "Requirements", 2);

    try testing.expect(d.warning_count >= 1);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and std.mem.indexOf(u8, e.message, "Requirement") != null and
            std.mem.indexOf(u8, e.message, "UserNeed") != null) found = true;
    }
    try testing.expect(found);
}

test "checkCrossRef no warning for correct type" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("UN-001", .user_need, &.{});

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try checkCrossRef(&g, "UN-001", .user_need, &d, "Requirements", 2);
    try testing.expectEqual(@as(u32, 0), d.warning_count);
}

test "multi-ID DERIVES_FROM creates multiple edges" {
    const sheets: []const SheetData = &.{
        .{ .name = "User Needs", .rows = &.{
            &.{ "ID", "Statement" },
            &.{ "UN-001", "Need one" },
            &.{ "UN-002", "Need two" },
        }},
        .{ .name = "Requirements", .rows = &.{
            &.{ "ID", "Statement", "User Need iD" },
            &.{ "REQ-001", "The system shall work", "UN-001, UN-002" },
        }},
    };

    var g = Graph.init(testing.allocator);
    defer g.deinit();

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    _ = try ingestValidated(&g, sheets, &d);

    var edges: std.ArrayList(graph.Edge) = .empty;
    defer edges.deinit(testing.allocator);
    try g.edgesFrom("REQ-001", testing.allocator, &edges);

    var derives_count: usize = 0;
    for (edges.items) |e| {
        if (e.label == .derives_from) derives_count += 1;
    }
    // Both UN-001 and UN-002 should have DERIVES_FROM edges
    try testing.expectEqual(@as(usize, 2), derives_count);
    // No cross-ref warnings (both IDs exist and are correct type)
    try testing.expectEqual(@as(u32, 0), d.warning_count);
}

test "isBlankEquivalent" {
    try testing.expect(isBlankEquivalent(""));
    try testing.expect(isBlankEquivalent("n/a"));
    try testing.expect(isBlankEquivalent("N/A"));
    try testing.expect(isBlankEquivalent("tbd"));
    try testing.expect(isBlankEquivalent("TBD"));
    try testing.expect(isBlankEquivalent("none"));
    try testing.expect(isBlankEquivalent("-"));
    try testing.expect(!isBlankEquivalent("REQ-001"));
    try testing.expect(!isBlankEquivalent("UN-001"));
    try testing.expect(!isBlankEquivalent("0"));
}

test "isSectionDivider" {
    // Completely blank row → divider
    try testing.expect(isSectionDivider(&.{ "", "" }, 0));

    // Single short content, ID empty → divider
    try testing.expect(isSectionDivider(&.{ "", "Intro" }, 0));

    // All-caps section header, ID empty → divider
    try testing.expect(isSectionDivider(&.{ "", "GENERAL REQUIREMENTS" }, 0));

    // ID present → not a divider
    try testing.expect(!isSectionDivider(&.{ "REQ-001", "statement" }, 0));

    // Multiple non-empty cells, no ID → real data with missing ID (not a divider)
    try testing.expect(!isSectionDivider(&.{ "", "statement", "high" }, 0));

    // Contains "section" → divider
    try testing.expect(isSectionDivider(&.{ "", "section 3 - interfaces" }, 0));
}

test "normalizeId basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    const result = try normalizeId("req-001", a, &d, "Test", 1);
    try testing.expectEqualStrings("REQ-001", result);
    try testing.expectEqual(@as(u32, 0), d.warning_count); // lowercase→uppercase is silent
}

test "normalizeId strips parenthetical suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    const result = try normalizeId("REQ-001 (old)", a, &d, "Test", 1);
    try testing.expectEqualStrings("REQ-001", result);
    try testing.expect(d.warning_count >= 1);
}

test "normalizeId strips leading/trailing hyphens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    const result = try normalizeId("-REQ-001-", a, &d, "Test", 1);
    try testing.expectEqualStrings("REQ-001", result);
    try testing.expect(d.warning_count >= 1);
}

test "parseNumericField text mappings" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try testing.expectEqualStrings("4", (try parseNumericField("high",   &d, "T", 1, "Sev")).?);
    try testing.expectEqualStrings("4", (try parseNumericField("High",   &d, "T", 1, "Sev")).?);
    try testing.expectEqualStrings("4", (try parseNumericField("H",      &d, "T", 1, "Sev")).?);
    try testing.expectEqualStrings("3", (try parseNumericField("medium", &d, "T", 1, "Sev")).?);
    try testing.expectEqualStrings("2", (try parseNumericField("low",    &d, "T", 1, "Sev")).?);
    try testing.expectEqualStrings("1", (try parseNumericField("negligible", &d, "T", 1, "Sev")).?);
    try testing.expectEqualStrings("5", (try parseNumericField("critical",   &d, "T", 1, "Sev")).?);
    try testing.expectEqualStrings("3", (try parseNumericField("iii",        &d, "T", 1, "Sev")).?);
    try testing.expectEqualStrings("4", (try parseNumericField("4.0",        &d, "T", 1, "Sev")).?);
}

test "parseNumericField blank equivalents return null" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    try testing.expect(try parseNumericField("",    &d, "T", 1, "Sev") == null);
    try testing.expect(try parseNumericField("n/a", &d, "T", 1, "Sev") == null);
    try testing.expect(try parseNumericField("tbd", &d, "T", 1, "Sev") == null);
    try testing.expect(try parseNumericField("-",   &d, "T", 1, "Sev") == null);
}

test "parseNumericField fractional warns and returns null" {
    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    const result = try parseNumericField("3.5", &d, "Risks", 2, "Severity");
    try testing.expect(result == null);
    try testing.expect(d.warning_count >= 1);
}

test "duplicate ID detection in ingestValidated" {
    const sheets: []const SheetData = &.{
        .{ .name = "Requirements", .rows = &.{
            &.{ "ID", "Statement" },
            &.{ "REQ-001", "The system shall work" },
            &.{ "REQ-001", "Duplicate entry" }, // duplicate
            &.{ "REQ-002", "The system shall also work" },
        }},
    };

    var g = Graph.init(testing.allocator);
    defer g.deinit();

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    const stats = try ingestValidated(&g, sheets, &d);

    // Only 2 unique requirements should be ingested
    try testing.expectEqual(@as(u32, 2), stats.requirement_count);

    // Should have warned about the duplicate
    var found_dup_warn = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and std.mem.indexOf(u8, e.message, "duplicate") != null) {
            found_dup_warn = true;
        }
    }
    try testing.expect(found_dup_warn);
}

test "isSectionDivider skipped silently in ingest" {
    const sheets: []const SheetData = &.{
        .{ .name = "Requirements", .rows = &.{
            &.{ "ID", "Statement" },
            &.{ "", "GENERAL REQUIREMENTS" }, // section header
            &.{ "REQ-001", "The system shall work" },
        }},
    };

    var g = Graph.init(testing.allocator);
    defer g.deinit();

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    const stats = try ingestValidated(&g, sheets, &d);
    try testing.expectEqual(@as(u32, 1), stats.requirement_count);
    // No warning for the section divider row
    var divider_warn = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and std.mem.indexOf(u8, e.message, "GENERAL") != null) {
            divider_warn = true;
        }
    }
    try testing.expect(!divider_warn);
}

test "isBlankEquivalent prevents dangling edges" {
    const sheets: []const SheetData = &.{
        .{ .name = "Requirements", .rows = &.{
            &.{ "ID", "Statement", "User Need iD", "Test Group ID" },
            &.{ "REQ-001", "The system shall work", "N/A", "TBD" },
        }},
    };

    var g = Graph.init(testing.allocator);
    defer g.deinit();

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    _ = try ingestValidated(&g, sheets, &d);

    // No DERIVES_FROM or TESTED_BY edges should be added for N/A or TBD
    var edges: std.ArrayList(graph.Edge) = .empty;
    defer edges.deinit(testing.allocator);
    try g.edgesFrom("REQ-001", testing.allocator, &edges);
    try testing.expectEqual(@as(usize, 0), edges.items.len);
}

test "resolveTab emits INFO for missing optional tabs" {
    var tmp_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tmp_arena.deinit();

    // Sheet with only Requirements
    const sheets: []const SheetData = &.{
        .{ .name = "Requirements", .rows = &.{
            &.{ "ID", "Statement" },
            &.{ "REQ-001", "The system shall work" },
        }},
    };

    var g = Graph.init(testing.allocator);
    defer g.deinit();

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    _ = try ingestValidated(&g, sheets, &d);

    // Should have INFO entries for missing User Needs, Tests, Risks tabs
    var un_info = false;
    var tst_info = false;
    var risk_info = false;
    for (d.entries.items) |e| {
        if (e.level == .info) {
            if (std.mem.indexOf(u8, e.message, "User Needs") != null) un_info = true;
            if (std.mem.indexOf(u8, e.message, "Tests") != null) tst_info = true;
            if (std.mem.indexOf(u8, e.message, "Risks") != null) risk_info = true;
        }
    }
    try testing.expect(un_info);
    try testing.expect(tst_info);
    try testing.expect(risk_info);
}

test "resolveTab full tab list in RequirementsTabNotFound error" {
    const sheets: []const SheetData = &.{
        .{ .name = "Sheet1", .rows = &.{} },
        .{ .name = "Sheet2", .rows = &.{} },
    };

    var g = Graph.init(testing.allocator);
    defer g.deinit();

    var d = Diagnostics.init(testing.allocator);
    defer d.deinit();

    const result = ingestValidated(&g, sheets, &d);
    try testing.expectError(diagnostic.ValidationError.RequirementsTabNotFound, result);

    // Error message should contain available tab names
    var found_tabs = false;
    for (d.entries.items) |e| {
        if (e.level == .err and std.mem.indexOf(u8, e.message, "Sheet1") != null) found_tabs = true;
    }
    try testing.expect(found_tabs);
}
