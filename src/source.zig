const std = @import("std");
const Config = @import("config.zig").Config;
const job_mod = @import("job.zig");
const x = @import("x.zig");

pub const Shared = struct {
    x_guest_tokens: x.GuestTokenCache = .{},
};

pub const Context = struct {
    io: std.Io,
    config: *const Config,
    environment: *const std.process.Environ.Map,
    shared: *Shared,
    x_client: x.Client,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: *const Config,
        environment: *const std.process.Environ.Map,
        shared: *Shared,
    ) Context {
        return .{
            .io = io,
            .config = config,
            .environment = environment,
            .shared = shared,
            .x_client = x.Client.init(allocator, io, config, &shared.x_guest_tokens),
        };
    }

    pub fn deinit(context: *Context) void {
        context.x_client.deinit();
    }
};

pub const ProgressCallback = struct {
    context: *anyopaque,
    update: *const fn (context: *anyopaque, progress: job_mod.Progress) anyerror!void,
};

pub fn probe(
    allocator: std.mem.Allocator,
    context: *Context,
    job_id: []const u8,
    source_url: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) !job_mod.Probe {
    if (cancelled(cancel)) return error.Cancelled;
    if (!x.matches(source_url)) return error.UnsupportedUrl;
    const diagnostic = x.probeDiagnostic(allocator, &context.x_client, source_url) catch |native_error| {
        logMetadataFailure(job_id, native_error, &context.x_client);
        return native_error;
    };
    if (cancelled(cancel)) return error.Cancelled;
    if (diagnostic.metadata_retries > 0) logMetadataRecovery(job_id, &context.x_client);
    return diagnostic.probe;
}

fn cancelled(cancel: ?*const std.atomic.Value(bool)) bool {
    return cancel != null and cancel.?.load(.acquire);
}

fn logMetadataRecovery(job_id: []const u8, client: *const x.Client) void {
    const retry = client.retryEvidence() orelse return;
    const first = retry.trace.first orelse return;
    const last = retry.trace.last orelse first;
    std.log.warn("native_x_metadata_recovered job_id={s} attempts=2 initial_cause={s} failures={d} first_endpoint={s} first_stage={s} first_status={d} last_endpoint={s} last_stage={s} last_status={d} last_cause={s}", .{
        job_id,
        retry.cause,
        retry.trace.count,
        @tagName(first.endpoint),
        @tagName(first.stage),
        first.status,
        @tagName(last.endpoint),
        @tagName(last.stage),
        last.status,
        last.cause,
    });
}

fn logMetadataFailure(job_id: []const u8, err: anyerror, client: *const x.Client) void {
    const final_trace = client.trace();
    const final = final_trace.last orelse return;
    const retry = client.retryEvidence();
    const initial_trace = if (retry) |value| value.trace else final_trace;
    const initial = initial_trace.first orelse final;
    std.log.warn("native_x_metadata_failure job_id={s} attempts={d} cause={s} initial_cause={s} initial_failures={d} initial_endpoint={s} initial_stage={s} initial_status={d} initial_transport_cause={s} final_failures={d} final_endpoint={s} final_stage={s} final_status={d} final_transport_cause={s}", .{
        job_id,
        if (retry == null) @as(u8, 1) else 2,
        @errorName(err),
        if (retry) |value| value.cause else @errorName(err),
        initial_trace.count,
        @tagName(initial.endpoint),
        @tagName(initial.stage),
        initial.status,
        initial.cause,
        final_trace.count,
        @tagName(final.endpoint),
        @tagName(final.stage),
        final.status,
        final.cause,
    });
}

pub fn acquire(
    result_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    context: *Context,
    job_id: []const u8,
    job_root: []const u8,
    source_url: []const u8,
    probe_result: job_mod.Probe,
    selection: job_mod.Selection,
    cancel: *const std.atomic.Value(bool),
    progress_callback: ProgressCallback,
) !job_mod.Acquisition {
    _ = job_id;
    _ = source_url;
    if (probe_result.engine != .x_native) return error.SourceEngineRetired;
    return x.acquire(
        result_allocator,
        scratch_allocator,
        &context.x_client,
        context.environment,
        job_root,
        probe_result,
        selection,
        cancel,
        .{ .context = progress_callback.context, .update = progress_callback.update },
    );
}
