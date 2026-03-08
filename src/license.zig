/// LemonSqueezy license verification for rtmify-trace.
///
/// Activation flow:
///   rtmify-trace --activate <key>
///     → validates key online with LemonSqueezy
///     → writes ~/.rtmify/license.json on success
///
/// Startup check:
///   check(gpa, .{}) → .ok / .not_activated / .expired
///
/// Deactivation:
///   rtmify-trace --deactivate
///     → calls LemonSqueezy deactivate endpoint
///     → removes ~/.rtmify/license.json
///
/// For tests: pass Options{ .dir = "/tmp/some-temp-dir" } to redirect
/// cache I/O away from the real ~/.rtmify/ directory.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Cached activation record stored in ~/.rtmify/license.json.
pub const LicenseRecord = struct {
    license_key: []const u8,
    activated_at: i64,
    fingerprint: []const u8,
    /// Null means perpetual (never expires). Unix timestamp otherwise.
    expires_at: ?i64 = null,
};

pub const CheckResult = enum {
    ok,
    not_activated,
    expired,
};

/// Controls where the license cache is stored.
/// Leave `dir` null to use `~/.rtmify/` (production).
/// Set `dir` to a temp path in tests.
pub const Options = struct {
    dir: ?[]const u8 = null,
};

/// 30-day grace period after subscription expiration.
pub const GRACE_PERIOD_SECS: i64 = 30 * 24 * 60 * 60;

/// LemonSqueezy API base URL.
const LS_ACTIVATE_URL = "https://api.lemonsqueezy.com/v1/licenses/activate";
const LS_DEACTIVATE_URL = "https://api.lemonsqueezy.com/v1/licenses/deactivate";

// ---------------------------------------------------------------------------
// Machine fingerprint
// ---------------------------------------------------------------------------

/// Returns a 64-character hex string (SHA-256 of hostname + OS).
/// `buf` must be exactly 64 bytes.
pub fn machineFingerprint(buf: *[64]u8) ![]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});

    if (builtin.os.tag == .windows) {
        // GetComputerNameA: max 256 bytes (MAX_COMPUTERNAME_LENGTH + 1 for DNS names)
        var hostname_buf: [256]u8 = undefined;
        var size: std.os.windows.DWORD = @intCast(hostname_buf.len);
        const GetComputerNameA = struct {
            extern "kernel32" fn GetComputerNameA(
                lpBuffer: [*]u8,
                nSize: *std.os.windows.DWORD,
            ) callconv(.winapi) std.os.windows.BOOL;
        }.GetComputerNameA;
        if (GetComputerNameA(&hostname_buf, &size) != 0) {
            sha.update(hostname_buf[0..size]);
        }
    } else {
        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = try std.posix.gethostname(&hostname_buf);
        sha.update(hostname);
    }

    sha.update("\x00");
    sha.update(@tagName(builtin.os.tag));

    var digest: [32]u8 = undefined;
    sha.final(&digest);

    const hex = std.fmt.bytesToHex(&digest, .lower);
    @memcpy(buf, &hex);
    return buf[0..];
}

// ---------------------------------------------------------------------------
// Cache path helpers
// ---------------------------------------------------------------------------

/// Returns an allocated path for the license.json file.
/// Caller owns the returned slice.
fn cacheFilePath(gpa: Allocator, opts: Options) ![]u8 {
    const dir = if (opts.dir) |d| d else blk: {
        const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        const home = try std.process.getEnvVarOwned(gpa, home_var);
        defer gpa.free(home);
        const rtmify_dir = try std.fs.path.join(gpa, &.{ home, ".rtmify" });
        break :blk rtmify_dir;
    };

    if (opts.dir == null) {
        // dir was heap-allocated inside the blk; owned by caller now
        defer gpa.free(dir);
        return std.fs.path.join(gpa, &.{ dir, "license.json" });
    }
    return std.fs.path.join(gpa, &.{ dir, "license.json" });
}

/// Ensures the parent directory of `file_path` exists.
fn ensureParentDir(gpa: Allocator, file_path: []const u8) !void {
    const dir = std.fs.path.dirname(file_path) orelse return;
    // makePath is idempotent; it succeeds even if the directory already exists.
    try std.fs.cwd().makePath(dir);
    _ = gpa;
}

// ---------------------------------------------------------------------------
// Cache read / write
// ---------------------------------------------------------------------------

/// Read and parse the license cache. Returns null if the file doesn't exist.
/// On success, all string fields in the returned record are owned by `gpa`;
/// caller must free them (license_key, fingerprint).
pub fn readCache(gpa: Allocator, opts: Options) !?LicenseRecord {
    const path = try cacheFilePath(gpa, opts);
    defer gpa.free(path);

    const data = std.fs.cwd().readFileAlloc(gpa, path, 8192) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(data);

    var parsed = try std.json.parseFromSlice(LicenseRecord, gpa, data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    // Dupe strings before freeing `data` and `parsed`.
    return LicenseRecord{
        .license_key = try gpa.dupe(u8, parsed.value.license_key),
        .activated_at = parsed.value.activated_at,
        .fingerprint = try gpa.dupe(u8, parsed.value.fingerprint),
        .expires_at = parsed.value.expires_at,
    };
}

/// Serialize and write a LicenseRecord to the cache file.
pub fn writeCache(gpa: Allocator, opts: Options, record: LicenseRecord) !void {
    const path = try cacheFilePath(gpa, opts);
    defer gpa.free(path);

    try ensureParentDir(gpa, path);

    const json_bytes = try std.json.Stringify.valueAlloc(gpa, record, .{});
    defer gpa.free(json_bytes);

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json_bytes });
}

/// Remove the license cache file (used by --deactivate).
pub fn removeCache(gpa: Allocator, opts: Options) !void {
    const path = try cacheFilePath(gpa, opts);
    defer gpa.free(path);

    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// License validity check (pure, no I/O)
// ---------------------------------------------------------------------------

/// Determine whether a record is currently valid given `now` (unix timestamp).
/// Does not perform any I/O.
pub fn checkRecord(record: LicenseRecord, now: i64) CheckResult {
    if (record.expires_at) |exp| {
        if (now > exp + GRACE_PERIOD_SECS) return .expired;
    }
    return .ok;
}

// ---------------------------------------------------------------------------
// High-level operations
// ---------------------------------------------------------------------------

/// Check license status from the cached activation record.
/// Returns .not_activated if no cache file exists.
/// Caller does not need to free anything.
pub fn check(gpa: Allocator, opts: Options) !CheckResult {
    const record = try readCache(gpa, opts) orelse return .not_activated;
    defer gpa.free(record.license_key);
    defer gpa.free(record.fingerprint);
    return checkRecord(record, std.time.timestamp());
}

/// Activate a license key by validating with LemonSqueezy and writing the cache.
/// Requires network access.
pub fn activate(gpa: Allocator, opts: Options, license_key: []const u8) !void {
    var fp_buf: [64]u8 = undefined;
    const fp = try machineFingerprint(&fp_buf);

    try callLemonSqueezyActivate(gpa, license_key, fp);

    const record = LicenseRecord{
        .license_key = license_key,
        .activated_at = std.time.timestamp(),
        .fingerprint = fp,
        .expires_at = null, // LemonSqueezy expiry parsing is future work
    };
    try writeCache(gpa, opts, record);
}

/// Deactivate: inform LemonSqueezy and remove the local cache.
/// Requires network access. Removes the cache even if the network call fails.
pub fn deactivate(gpa: Allocator, opts: Options) !void {
    const record = try readCache(gpa, opts) orelse return; // nothing to do
    defer gpa.free(record.license_key);
    defer gpa.free(record.fingerprint);

    callLemonSqueezyDeactivate(gpa, record.license_key, record.fingerprint) catch |err| {
        std.log.warn("deactivate network call failed: {s}", .{@errorName(err)});
    };

    try removeCache(gpa, opts);
}

// ---------------------------------------------------------------------------
// LemonSqueezy HTTP helpers (require network)
// ---------------------------------------------------------------------------

/// Minimal JSON structure expected from LemonSqueezy activate/validate response.
const LsResponse = struct {
    activated: ?bool = null,
    deactivated: ?bool = null,
    @"error": ?[]const u8 = null,
    license_key: ?struct {
        status: []const u8,
    } = null,
};

fn callLemonSqueezyActivate(gpa: Allocator, license_key: []const u8, fp: []const u8) !void {
    const body = try std.fmt.allocPrint(gpa, "license_key={s}&instance_name={s}", .{ license_key, fp });
    defer gpa.free(body);

    const resp_bytes = try httpPost(gpa, LS_ACTIVATE_URL, body);
    defer gpa.free(resp_bytes);

    var parsed = try std.json.parseFromSlice(LsResponse, gpa, resp_bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.activated == false or parsed.value.@"error" != null) {
        std.log.err("LemonSqueezy activation failed: {s}", .{
            parsed.value.@"error" orelse "unknown error",
        });
        return error.LicenseActivationFailed;
    }
}

fn callLemonSqueezyDeactivate(gpa: Allocator, license_key: []const u8, instance_name: []const u8) !void {
    const body = try std.fmt.allocPrint(gpa, "license_key={s}&instance_name={s}", .{ license_key, instance_name });
    defer gpa.free(body);

    const resp_bytes = try httpPost(gpa, LS_DEACTIVATE_URL, body);
    defer gpa.free(resp_bytes);

    var parsed = try std.json.parseFromSlice(LsResponse, gpa, resp_bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.deactivated == false or parsed.value.@"error" != null) {
        std.log.warn("LemonSqueezy deactivation returned error: {s}", .{
            parsed.value.@"error" orelse "unknown",
        });
    }
}

/// Send an HTTP POST with `application/x-www-form-urlencoded` body.
/// Returns the response body as an owned slice. Caller must free.
fn httpPost(gpa: Allocator, url: []const u8, body: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    var response_buf = std.Io.Writer.Allocating.init(gpa);
    defer response_buf.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &response_buf.writer,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" },
        },
    });

    if (result.status != .ok and result.status != .created) {
        return error.LicenseServerError;
    }

    return response_buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "machineFingerprint returns 64 hex chars" {
    var buf: [64]u8 = undefined;
    const fp = try machineFingerprint(&buf);
    try testing.expectEqual(@as(usize, 64), fp.len);
    for (fp) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
}

test "machineFingerprint is stable" {
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    const fp1 = try machineFingerprint(&buf1);
    const fp2 = try machineFingerprint(&buf2);
    try testing.expectEqualStrings(fp1, fp2);
}

test "LicenseRecord json round-trip" {
    const gpa = testing.allocator;

    const original = LicenseRecord{
        .license_key = "ABCD-1234-EFGH-5678",
        .activated_at = 1700000000,
        .fingerprint = "deadbeef01234567deadbeef01234567deadbeef01234567deadbeef01234567",
        .expires_at = null,
    };

    const json_bytes = try std.json.Stringify.valueAlloc(gpa, original, .{});
    defer gpa.free(json_bytes);

    var parsed = try std.json.parseFromSlice(LicenseRecord, gpa, json_bytes, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings(original.license_key, parsed.value.license_key);
    try testing.expectEqual(original.activated_at, parsed.value.activated_at);
    try testing.expectEqualStrings(original.fingerprint, parsed.value.fingerprint);
    try testing.expectEqual(original.expires_at, parsed.value.expires_at);
}

test "LicenseRecord json round-trip with expires_at" {
    const gpa = testing.allocator;

    const original = LicenseRecord{
        .license_key = "TEST-0000-0000-0001",
        .activated_at = 1700000000,
        .fingerprint = "aaaa",
        .expires_at = 1800000000,
    };

    const json_bytes = try std.json.Stringify.valueAlloc(gpa, original, .{});
    defer gpa.free(json_bytes);

    var parsed = try std.json.parseFromSlice(LicenseRecord, gpa, json_bytes, .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(?i64, 1800000000), parsed.value.expires_at);
}

test "checkRecord perpetual license never expires" {
    const rec = LicenseRecord{
        .license_key = "K",
        .activated_at = 0,
        .fingerprint = "f",
        .expires_at = null,
    };
    // Any timestamp → ok
    try testing.expectEqual(CheckResult.ok, checkRecord(rec, 0));
    try testing.expectEqual(CheckResult.ok, checkRecord(rec, 9_999_999_999));
}

test "checkRecord subscription within grace period" {
    const now: i64 = 1_700_000_000;
    const twenty_days: i64 = 20 * 24 * 60 * 60;
    const rec = LicenseRecord{
        .license_key = "K",
        .activated_at = 0,
        .fingerprint = "f",
        .expires_at = now - twenty_days,
    };
    try testing.expectEqual(CheckResult.ok, checkRecord(rec, now));
}

test "checkRecord subscription expired beyond grace" {
    const now: i64 = 1_700_000_000;
    const forty_days: i64 = 40 * 24 * 60 * 60;
    const rec = LicenseRecord{
        .license_key = "K",
        .activated_at = 0,
        .fingerprint = "f",
        .expires_at = now - forty_days,
    };
    try testing.expectEqual(CheckResult.expired, checkRecord(rec, now));
}

test "check returns not_activated when no cache file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const result = try check(testing.allocator, .{ .dir = tmp_path });
    try testing.expectEqual(CheckResult.not_activated, result);
}

test "writeCache and check ok" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const opts = Options{ .dir = tmp_path };

    const record = LicenseRecord{
        .license_key = "LIVE-0000-0000-ABCD",
        .activated_at = std.time.timestamp(),
        .fingerprint = "testfp",
        .expires_at = null,
    };
    try writeCache(testing.allocator, opts, record);

    const result = try check(testing.allocator, opts);
    try testing.expectEqual(CheckResult.ok, result);
}

test "writeCache then removeCache then not_activated" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const opts = Options{ .dir = tmp_path };

    const record = LicenseRecord{
        .license_key = "LIVE-1111-1111-1111",
        .activated_at = 0,
        .fingerprint = "fp",
        .expires_at = null,
    };
    try writeCache(testing.allocator, opts, record);
    try removeCache(testing.allocator, opts);

    const result = try check(testing.allocator, opts);
    try testing.expectEqual(CheckResult.not_activated, result);
}

test "check expired subscription" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const opts = Options{ .dir = tmp_path };
    const forty_days_ago = std.time.timestamp() - 40 * 24 * 60 * 60;

    const record = LicenseRecord{
        .license_key = "SUB-0001",
        .activated_at = forty_days_ago - 100,
        .fingerprint = "fp",
        .expires_at = forty_days_ago,
    };
    try writeCache(testing.allocator, opts, record);

    const result = try check(testing.allocator, opts);
    try testing.expectEqual(CheckResult.expired, result);
}
