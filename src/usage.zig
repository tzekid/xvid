const std = @import("std");
const job_mod = @import("job.zig");
const c = struct {
    const sqlite3 = opaque {};
    const sqlite3_stmt = opaque {};
    const ExecCallback = *const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int;
    const Destructor = *const fn (?*anyopaque) callconv(.c) void;

    const SQLITE_OK = 0;
    const SQLITE_ROW = 100;
    const SQLITE_DONE = 101;
    const SQLITE_OPEN_READWRITE = 0x00000002;
    const SQLITE_OPEN_CREATE = 0x00000004;
    const SQLITE_OPEN_FULLMUTEX = 0x00010000;
    const SQLITE_OPEN_EXRESCODE = 0x02000000;

    extern "c" fn sqlite3_open_v2(filename: [*c]const u8, database: *?*sqlite3, flags: c_int, vfs: ?[*:0]const u8) c_int;
    extern "c" fn sqlite3_close(database: *sqlite3) c_int;
    extern "c" fn sqlite3_close_v2(database: *sqlite3) c_int;
    extern "c" fn sqlite3_extended_result_codes(database: *sqlite3, enabled: c_int) c_int;
    extern "c" fn sqlite3_busy_timeout(database: *sqlite3, milliseconds: c_int) c_int;
    extern "c" fn sqlite3_exec(database: *sqlite3, sql: [*c]const u8, callback: ?ExecCallback, context: ?*anyopaque, message: *[*c]u8) c_int;
    extern "c" fn sqlite3_free(pointer: ?*anyopaque) void;
    extern "c" fn sqlite3_prepare_v3(database: *sqlite3, sql: [*c]const u8, length: c_int, flags: c_uint, statement: *?*sqlite3_stmt, tail: ?*[*c]const u8) c_int;
    extern "c" fn sqlite3_finalize(statement: *sqlite3_stmt) c_int;
    extern "c" fn sqlite3_step(statement: *sqlite3_stmt) c_int;
    extern "c" fn sqlite3_bind_text(statement: *sqlite3_stmt, index: c_int, value: [*c]const u8, length: c_int, destructor: ?Destructor) c_int;
    extern "c" fn sqlite3_bind_null(statement: *sqlite3_stmt, index: c_int) c_int;
    extern "c" fn sqlite3_bind_int64(statement: *sqlite3_stmt, index: c_int, value: i64) c_int;
    extern "c" fn sqlite3_changes64(database: *sqlite3) i64;
    extern "c" fn sqlite3_column_int64(statement: *sqlite3_stmt, index: c_int) i64;
    extern "c" fn sqlite3_column_text(statement: *sqlite3_stmt, index: c_int) ?[*]const u8;
    extern "c" fn sqlite3_column_bytes(statement: *sqlite3_stmt, index: c_int) c_int;
};

pub const DeliveryKind = enum {
    download_response_complete,
    share_handoff,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    database_path: []u8,
    handle: *c.sqlite3,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, data_root: []const u8) !Store {
        const database_path = try std.fs.path.join(allocator, &.{ data_root, "usage.sqlite3" });
        errdefer allocator.free(database_path);
        const file = try std.Io.Dir.cwd().createFile(io, database_path, .{
            .read = true,
            .truncate = false,
            .permissions = @fromBackingInt(@intCast(0o600)),
        });
        file.close(io);

        const path_z = try allocator.dupeSentinel(u8, database_path, 0);
        defer allocator.free(path_z);
        var raw_handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX | c.SQLITE_OPEN_EXRESCODE;
        const open_result = c.sqlite3_open_v2(path_z.ptr, &raw_handle, flags, null);
        if (open_result != c.SQLITE_OK or raw_handle == null) {
            if (raw_handle) |handle| _ = c.sqlite3_close(handle);
            return error.UsageDatabaseOpenFailed;
        }
        errdefer _ = c.sqlite3_close(raw_handle.?);
        if (c.sqlite3_extended_result_codes(raw_handle.?, 1) != c.SQLITE_OK) return error.UsageDatabaseConfigurationFailed;
        if (c.sqlite3_busy_timeout(raw_handle.?, 2_000) != c.SQLITE_OK) return error.UsageDatabaseConfigurationFailed;
        try exec(raw_handle.?, schema);
        return .{
            .allocator = allocator,
            .io = io,
            .database_path = database_path,
            .handle = raw_handle.?,
        };
    }

    pub fn deinit(store: *Store) void {
        _ = c.sqlite3_close_v2(store.handle);
        store.allocator.free(store.database_path);
        store.* = undefined;
    }

    pub fn path(store: *const Store) []const u8 {
        return store.database_path;
    }

    pub fn check(store: *Store) !void {
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        const statement = try prepare(store.handle, "PRAGMA quick_check");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.UsageDatabaseCheckFailed;
        const value = columnText(statement, 0) orelse return error.UsageDatabaseCheckFailed;
        if (!std.mem.eql(u8, value, "ok")) return error.UsageDatabaseCheckFailed;
    }

    pub fn recordCreated(store: *Store, id: []const u8, created_at: i64, source_host: []const u8, intent: job_mod.Intent) !void {
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        const statement = try prepare(store.handle,
            \\INSERT INTO usage_jobs (
            \\  job_id, created_at, updated_at, source_host, intent, state
            \\) VALUES (?1, ?2, ?2, ?3, ?4, 'probing')
            \\ON CONFLICT(job_id) DO UPDATE SET
            \\  source_host = excluded.source_host,
            \\  intent = excluded.intent,
            \\  updated_at = max(usage_jobs.updated_at, excluded.updated_at)
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, id);
        try bindInteger(statement, 2, created_at);
        try bindText(statement, 3, source_host);
        try bindText(statement, 4, @tagName(intent));
        try stepDone(statement);
    }

    pub fn recordSnapshot(store: *Store, data: job_mod.Data) !void {
        var retained_files: u16 = 0;
        var retained_bytes: u64 = 0;
        for (data.source_artifacts) |artifact| {
            retained_files += 1;
            retained_bytes = try std.math.add(u64, retained_bytes, artifact.size_bytes);
        }
        for (data.output_artifacts) |artifact| {
            retained_files += 1;
            retained_bytes = try std.math.add(u64, retained_bytes, artifact.size_bytes);
        }
        const probe = data.probe;
        const delivery_mode: ?[]const u8 = if (data.delivery) |delivery| @tagName(delivery.mode) else null;
        const failure_code: ?[]const u8 = if (data.failure) |failure| failure.code else null;

        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        const statement = try prepare(store.handle,
            \\UPDATE usage_jobs SET
            \\  updated_at = ?1,
            \\  state = ?2,
            \\  engine = ?3,
            \\  media_kind = ?4,
            \\  item_count = ?5,
            \\  video_count = ?6,
            \\  image_count = ?7,
            \\  delivery_mode = ?8,
            \\  failure_code = ?9,
            \\  retained_files = ?10,
            \\  retained_bytes = ?11,
            \\  expires_at = ?12,
            \\  terminal_at = CASE
            \\    WHEN ?13 = 1 THEN coalesce(terminal_at, ?1)
            \\    ELSE terminal_at
            \\  END
            \\WHERE job_id = ?14
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindInteger(statement, 1, data.updated_at);
        try bindText(statement, 2, @tagName(data.state));
        try bindOptionalText(statement, 3, if (probe) |value| @tagName(value.engine) else null);
        try bindOptionalText(statement, 4, if (probe) |value| @tagName(value.media_kind) else null);
        try bindOptionalInteger(statement, 5, if (probe) |value| value.item_count else null);
        try bindOptionalInteger(statement, 6, if (probe) |value| value.video_count else null);
        try bindOptionalInteger(statement, 7, if (probe) |value| value.image_count else null);
        try bindOptionalText(statement, 8, delivery_mode);
        try bindOptionalText(statement, 9, failure_code);
        try bindInteger(statement, 10, retained_files);
        try bindInteger(statement, 11, retained_bytes);
        try bindOptionalInteger(statement, 12, data.expires_at);
        try bindInteger(statement, 13, @as(i64, if (data.state.terminal()) 1 else 0));
        try bindText(statement, 14, data.id);
        try stepDone(statement);
        if (c.sqlite3_changes64(store.handle) != 1) return error.UsageJobMissing;
    }

    pub fn recordDelivery(
        store: *Store,
        job_id: []const u8,
        kind: DeliveryKind,
        artifact_ids: []const u8,
        artifact_count: u8,
        bytes: u64,
        occurred_at: i64,
    ) !void {
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        const statement = try prepare(store.handle,
            \\INSERT INTO usage_deliveries (
            \\  job_id, occurred_at, kind, artifact_ids, artifact_count, bytes
            \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, job_id);
        try bindInteger(statement, 2, occurred_at);
        try bindText(statement, 3, @tagName(kind));
        try bindText(statement, 4, artifact_ids);
        try bindInteger(statement, 5, artifact_count);
        try bindInteger(statement, 6, bytes);
        try stepDone(statement);
    }

    fn count(store: *Store, table: []const u8) !u64 {
        store.mutex.lockUncancelable(store.io);
        defer store.mutex.unlock(store.io);
        const sql = if (std.mem.eql(u8, table, "usage_jobs")) "SELECT count(*) FROM usage_jobs" else "SELECT count(*) FROM usage_deliveries";
        const statement = try prepare(store.handle, sql);
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.UsageDatabaseQueryFailed;
        return @intCast(c.sqlite3_column_int64(statement, 0));
    }
};

const schema =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA synchronous=FULL;
    \\PRAGMA foreign_keys=ON;
    \\PRAGMA wal_autocheckpoint=100;
    \\CREATE TABLE IF NOT EXISTS usage_jobs (
    \\  job_id TEXT PRIMARY KEY,
    \\  created_at INTEGER NOT NULL,
    \\  updated_at INTEGER NOT NULL,
    \\  source_host TEXT NOT NULL,
    \\  intent TEXT NOT NULL,
    \\  state TEXT NOT NULL,
    \\  engine TEXT,
    \\  media_kind TEXT,
    \\  item_count INTEGER,
    \\  video_count INTEGER,
    \\  image_count INTEGER,
    \\  delivery_mode TEXT,
    \\  failure_code TEXT,
    \\  retained_files INTEGER NOT NULL DEFAULT 0,
    \\  retained_bytes INTEGER NOT NULL DEFAULT 0,
    \\  terminal_at INTEGER,
    \\  expires_at INTEGER
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS usage_deliveries (
    \\  id INTEGER PRIMARY KEY,
    \\  job_id TEXT NOT NULL REFERENCES usage_jobs(job_id),
    \\  occurred_at INTEGER NOT NULL,
    \\  kind TEXT NOT NULL CHECK (kind IN ('download_response_complete', 'share_handoff')),
    \\  artifact_ids TEXT NOT NULL,
    \\  artifact_count INTEGER NOT NULL CHECK (artifact_count BETWEEN 1 AND 8),
    \\  bytes INTEGER NOT NULL CHECK (bytes >= 0)
    \\) STRICT;
    \\CREATE INDEX IF NOT EXISTS usage_deliveries_job_time
    \\  ON usage_deliveries(job_id, occurred_at);
    \\CREATE INDEX IF NOT EXISTS usage_jobs_created_at
    \\  ON usage_jobs(created_at);
    \\PRAGMA user_version=1;
;

fn exec(handle: *c.sqlite3, sql: []const u8) !void {
    var message: [*c]u8 = null;
    const result = c.sqlite3_exec(handle, sql.ptr, null, null, &message);
    if (message != null) c.sqlite3_free(message);
    if (result != c.SQLITE_OK) return error.UsageDatabaseSchemaFailed;
}

fn prepare(handle: *c.sqlite3, sql: []const u8) !*c.sqlite3_stmt {
    var raw_statement: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v3(handle, sql.ptr, @intCast(sql.len), 0, &raw_statement, null) != c.SQLITE_OK or raw_statement == null) {
        return error.UsageDatabasePrepareFailed;
    }
    return raw_statement.?;
}

fn bindText(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(statement, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) return error.UsageDatabaseBindFailed;
}

fn bindOptionalText(statement: *c.sqlite3_stmt, index: c_int, value: ?[]const u8) !void {
    if (value) |text| return bindText(statement, index, text);
    if (c.sqlite3_bind_null(statement, index) != c.SQLITE_OK) return error.UsageDatabaseBindFailed;
}

fn bindInteger(statement: *c.sqlite3_stmt, index: c_int, value: anytype) !void {
    const cast: i64 = @intCast(value);
    if (c.sqlite3_bind_int64(statement, index, cast) != c.SQLITE_OK) return error.UsageDatabaseBindFailed;
}

fn bindOptionalInteger(statement: *c.sqlite3_stmt, index: c_int, value: anytype) !void {
    if (value) |integer| return bindInteger(statement, index, integer);
    if (c.sqlite3_bind_null(statement, index) != c.SQLITE_OK) return error.UsageDatabaseBindFailed;
}

fn stepDone(statement: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.UsageDatabaseWriteFailed;
}

fn columnText(statement: *c.sqlite3_stmt, index: c_int) ?[]const u8 {
    const pointer = c.sqlite3_column_text(statement, index) orelse return null;
    const length: usize = @intCast(c.sqlite3_column_bytes(statement, index));
    return pointer[0..length];
}

test "usage database preserves jobs and delivery facts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", temporary.sub_path[0..], "usage-data" });
    defer allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    var store = try Store.init(allocator, io, root);
    defer store.deinit();
    try store.recordCreated("0123456789abcdef0123456789abcdef", 1_800_000_000, "x.com", .save_original);
    try store.recordDelivery("0123456789abcdef0123456789abcdef", .download_response_complete, "file-1", 1, 42, 1_800_000_010);
    try store.check();
    try std.testing.expectEqual(@as(u64, 1), try store.count("usage_jobs"));
    try std.testing.expectEqual(@as(u64, 1), try store.count("usage_deliveries"));
}
