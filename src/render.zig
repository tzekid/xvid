const std = @import("std");
const job_mod = @import("job.zig");
const x = @import("x.zig");

const maximum_share_bytes = 64 * 1024 * 1024;
pub const asset_version = "7";

const composer_before_url =
    \\<div class="persistent-composer">
    \\      <form class="link-form" action="/jobs" method="post" data-link-form data-nav-form>
    \\        <label for="url">Public X or Instagram post link</label>
    \\        <div class="url-control">
    \\          <input id="url" name="url" type="url" inputmode="url" autocomplete="url" autocapitalize="none" autocorrect="off" spellcheck="false" required maxlength="4096" placeholder="https://x.com/…/status/…" aria-describedby="link-error" value="
;
const composer_after_url =
    \\" >
    \\          <button class="clear-input" type="button" data-clear-input hidden aria-label="Clear link">×</button>
    \\        </div>
    \\        <p id="link-error" class="field-error" data-link-error hidden></p>
    \\        <label class="resolution-toggle"><span>Choose resolution</span><input type="checkbox" role="switch" name="advanced" value="1" data-resolution
;
const composer_after_resolution =
    \\></label>
    \\        <button class="primary-action" type="button" data-paste hidden>Paste</button>
    \\        <button class="secondary-action" type="submit" data-download>
;
const composer_end =
    \\</button>
    \\      </form>
    \\</div>
;

const link_composer = composer_before_url ++ composer_after_url ++ composer_after_resolution ++ "Download" ++ composer_end;

fn linkComposer(writer: *std.Io.Writer, url: []const u8, resolution: bool, ready: bool) !void {
    try writer.writeAll(composer_before_url);
    try escapeAttribute(writer, url);
    try writer.writeAll(composer_after_url);
    if (resolution) try writer.writeAll(" checked");
    try writer.writeAll(composer_after_resolution);
    try writer.writeAll(if (ready) "Download again" else "Download");
    try writer.writeAll(composer_end);
}

pub const home =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    \\  <meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
    \\  <meta name="theme-color" content="#0b0b0b" media="(prefers-color-scheme: dark)">
    \\  <title>xvid</title>
    \\  <meta name="description" content="Save selected photos and videos from public X and Instagram posts.">
    \\  <link rel="icon" href="/assets/icon.svg" type="image/svg+xml">
    \\  <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
    \\  <link rel="manifest" href="/manifest.webmanifest">
    \\  <link rel="stylesheet" href="/assets/app.css?v=6">
    \\  <script src="/assets/app.js?v=6" defer></script>
    \\</head>
    \\<body>
    \\  <main id="app" class="app-shell compose-shell" data-page-state="compose">
    \\    <header class="app-header"><a class="brand" href="/" aria-label="xvid home">xvid</a></header>
++ link_composer ++
    \\  </main>
    \\</body>
    \\</html>
;

pub fn jobPage(writer: *std.Io.Writer, snapshot: job_mod.Snapshot, automatic_navigation: bool) !void {
    try writer.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">");
    if (!snapshot.data.state.terminal()) try writer.writeAll("<meta http-equiv=\"refresh\" content=\"5\">");
    try writer.writeAll("<meta name=\"theme-color\" content=\"#ffffff\" media=\"(prefers-color-scheme: light)\"><meta name=\"theme-color\" content=\"#0b0b0b\" media=\"(prefers-color-scheme: dark)\"><title>");
    if (snapshot.data.probe) |probe| try escape(writer, probe.title) else try writer.writeAll("X media");
    try writer.print(" · xvid</title><link rel=\"icon\" href=\"/assets/icon.svg\" type=\"image/svg+xml\"><link rel=\"apple-touch-icon\" sizes=\"180x180\" href=\"/apple-touch-icon.png\"><link rel=\"manifest\" href=\"/manifest.webmanifest\"><link rel=\"stylesheet\" href=\"/assets/app.css?v={s}\"><script src=\"/assets/app.js?v={s}\" defer></script></head><body>", .{ asset_version, asset_version });
    try writer.writeAll("<main id=\"app\" class=\"app-shell job-shell\" data-page-state=\"");
    try writer.writeAll(productState(snapshot));
    try writer.writeAll("\" data-job-id=\"");
    try escapeAttribute(writer, snapshot.data.id);
    try writer.print("\" data-revision=\"{d}\"", .{snapshot.revision});
    if (automatic_navigation and (snapshot.data.intent == .save_original or snapshot.data.direct_delivery)) try writer.writeAll(" data-auto-start");
    if (!snapshot.data.state.terminal()) {
        try writer.writeAll(" data-events=\"");
        try jobUrl(writer, snapshot.data.id, "events");
        try writer.writeByte('"');
    }
    try writer.writeAll("><header class=\"app-header\"><a class=\"brand\" href=\"/\" data-nav-link aria-label=\"xvid home\">xvid</a><span class=\"connection-state\" data-connection-state hidden></span></header>");
    try linkComposer(writer, snapshot.data.source_url, snapshot.data.intent == .inspect, snapshot.data.state == .ready);
    try writer.writeAll("<div id=\"job-state\">");
    try jobState(writer, snapshot);
    try writer.writeAll("</div></main></body></html>");
}

pub fn jobState(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    try writer.print("<section class=\"state-view\" data-state-fragment data-revision=\"{d}\" data-state=\"{s}\">", .{ snapshot.revision, @tagName(snapshot.data.state) });
    try renderSourceSummary(writer, snapshot);

    if (snapshot.data.warning) |warning| {
        try writer.writeAll("<div class=\"inline-message warning\" role=\"status\"><strong>The source file was kept.</strong><p>");
        try escape(writer, warning);
        try writer.writeAll("</p></div>");
    }

    switch (snapshot.data.state) {
        .probing => {
            try renderProgress(writer, snapshot, "Finding media…");
            try renderCancel(writer, snapshot.data.id);
        },
        .awaiting_choice => try renderChoice(writer, snapshot),
        .queued => {
            try renderProgress(writer, snapshot, "Waiting to start…");
            try renderCancel(writer, snapshot.data.id);
        },
        .acquiring => {
            try renderProgress(writer, snapshot, "Downloading…");
            try renderCancel(writer, snapshot.data.id);
        },
        .preparing => {
            if (snapshot.source_available) {
                try writer.writeAll("<div class=\"inline-message source-ready\" role=\"status\"><strong>The source file is ready.</strong><p>You can save it now or wait for the requested MP4.</p></div>");
                try renderReadyActions(writer, snapshot, true);
                try writer.writeAll("<form class=\"secondary-form\" method=\"post\" action=\"");
                try jobUrl(writer, snapshot.data.id, "use-original");
                try writer.writeAll("\" data-nav-form><button class=\"secondary-action\" type=\"submit\">Keep source file now</button></form>");
            }
            try renderProgress(writer, snapshot, if (snapshot.data.delivery != null and snapshot.data.delivery.?.mode == .downscale) "Making a smaller MP4…" else "Preparing a compatible MP4…");
            try renderCancel(writer, snapshot.data.id);
        },
        .ready => try renderReady(writer, snapshot),
        .failed => try renderFailure(writer, snapshot),
        .cancelled => try renderCancelled(writer),
    }

    try renderUtilities(writer, snapshot);
    try writer.writeAll("</section>");
}

pub fn errorPage(writer: *std.Io.Writer, title: []const u8, message: []const u8, url: []const u8, resolution: bool) !void {
    try writer.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\"><meta name=\"theme-color\" content=\"#ffffff\" media=\"(prefers-color-scheme: light)\"><meta name=\"theme-color\" content=\"#0b0b0b\" media=\"(prefers-color-scheme: dark)\"><title>");
    try escape(writer, title);
    try writer.print(" · xvid</title><link rel=\"icon\" href=\"/assets/icon.svg\" type=\"image/svg+xml\"><link rel=\"stylesheet\" href=\"/assets/app.css?v={s}\"><script src=\"/assets/app.js?v={s}\" defer></script></head><body><main id=\"app\" class=\"app-shell problem-shell\" data-page-state=\"problem\"><header class=\"app-header\"><a class=\"brand\" href=\"/\" data-nav-link>xvid</a></header>", .{ asset_version, asset_version });
    try linkComposer(writer, url, resolution, false);
    try writer.writeAll("<section class=\"problem-view\" role=\"alert\"><h1>");
    try escape(writer, title);
    try writer.writeAll("</h1><p>");
    try escape(writer, message);
    try writer.writeAll("</p></section></main></body></html>");
}

fn renderSourceSummary(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    if (snapshot.data.probe) |probe| {
        try writer.writeAll("<header class=\"source-summary\"><p class=\"source-meta\">");
        try writer.writeAll(if (probe.engine == .instagram_native) "Instagram" else "X");
        if (probe.item_count > 1) {
            try writer.writeAll(" · ");
            try writer.print("{d} items", .{probe.item_count});
        } else {
            try writer.writeAll(" · ");
            try writer.writeAll(mediaKindLabel(probe.media_kind));
        }
        try writer.writeAll("</p><h1>");
        try escape(writer, probe.title);
        try writer.writeAll("</h1></header>");
    } else {
        try writer.writeAll("<header class=\"source-summary\"><h1>Checking link…</h1></header>");
    }
}

fn renderProgress(writer: *std.Io.Writer, snapshot: job_mod.Snapshot, fallback_label: []const u8) !void {
    try writer.writeAll("<section class=\"progress-panel\" role=\"status\" aria-live=\"polite\"><div class=\"progress-heading\"><strong>");
    const label = if (snapshot.progress.label.len > 0) snapshot.progress.label else fallback_label;
    try escape(writer, label);
    if (snapshot.progress.fraction) |fraction| {
        const percent: u8 = @intFromFloat(@min(100.0, @max(0.0, fraction * 100.0)));
        try writer.print("</strong><span>{d}%</span></div><progress max=\"100\" value=\"{d}\">{d}%</progress>", .{ percent, percent, percent });
    } else {
        try writer.writeAll("</strong></div><progress aria-label=\"Download progress\"></progress>");
    }
    try writer.writeAll("<p class=\"progress-detail\">");
    var wrote = false;
    if (snapshot.progress.item_index) |index| if (snapshot.progress.item_count) |count| {
        try writer.print("Item {d} of {d}", .{ index, count });
        wrote = true;
    };
    if (snapshot.progress.bytes_downloaded) |downloaded| {
        if (wrote) try writer.writeAll(" · ");
        try formatBytes(writer, downloaded);
        if (snapshot.progress.bytes_total) |total| {
            try writer.writeAll(" of ");
            try formatBytes(writer, total);
        }
        wrote = true;
    }
    if (snapshot.progress.speed_bytes_per_second) |speed| if (speed > 0 and std.math.isFinite(speed)) {
        if (wrote) try writer.writeAll(" · ");
        try formatBytes(writer, @intFromFloat(speed));
        try writer.writeAll("/s");
        wrote = true;
    };
    if (snapshot.progress.eta_seconds) |eta| {
        if (wrote) try writer.writeAll(" · ");
        try formatDuration(writer, eta);
        try writer.writeAll(" left");
        wrote = true;
    }
    try writer.writeAll("</p></section>");
}

fn renderChoice(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    const probe = snapshot.data.probe orelse return;
    if (probe.instagram_plan) |plan| return renderInstagramPicker(writer, snapshot, plan);
    try writer.writeAll("<form class=\"choice-form\" method=\"post\" action=\"");
    try jobUrl(writer, snapshot.data.id, "start");
    try writer.writeAll("\" data-nav-form data-choice-form><div class=\"choice-heading\"><h2>Choose resolution</h2></div><input type=\"hidden\" name=\"delivery\" value=\"original\">");
    if (probe.media_kind == .video) {
        try writer.writeAll("<input type=\"hidden\" name=\"kind\" value=\"video\"><div class=\"resolution-options\">");
        for (probe.variants) |variant| {
            try writer.writeAll("<button class=\"resolution-row\" type=\"submit\" name=\"variant\" value=\"");
            try escapeAttribute(writer, variant.id);
            try writer.writeAll("\"><span>");
            try escape(writer, variant.label);
            try writer.writeAll("</span>");
            if (variant.estimated_size_bytes) |size| {
                try writer.writeAll("<span class=\"row-value\">");
                if (variant.estimated_size_kind == .approximate) try writer.writeAll("~");
                try formatBytes(writer, size);
                try writer.writeAll("</span>");
            }
            try writer.writeAll("</button>");
        }
        try writer.writeAll("</div>");
    } else {
        // Jobs created before this release can still be waiting for a choice.
        try writer.writeAll("<button class=\"primary-action\" type=\"submit\">Download media</button>");
    }
    try writer.writeAll("</form>");
}

fn renderReady(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    if (snapshot.data.direct_delivery) return renderDirect(writer, snapshot);
    try writer.writeAll("<section class=\"ready-view\"><div class=\"ready-heading\" role=\"status\"><h2>Ready to save</h2></div>");
    try renderReadyActions(writer, snapshot, false);
    try renderPlayback(writer, snapshot);
    if (snapshot.data.expires_at) |expires_at| try writer.print("<p class=\"expiry-note\" data-expiry data-expires-at=\"{d}\">Temporary files expire automatically.</p>", .{expires_at});
    try writer.writeAll("</section>");
}

fn renderDirect(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    const probe = snapshot.data.probe orelse return error.InvalidProbe;
    const plan = probe.x_plan orelse return error.InvalidProbe;
    const selection = snapshot.data.selection orelse return error.InvalidSelection;
    try writer.writeAll("<section class=\"ready-view\" data-direct-delivery><div class=\"ready-heading\" role=\"status\"><h2>Ready to download</h2></div><div class=\"artifact-list\">");
    for (plan.items) |item| {
        const transfer = try x.transferForSelection(item, selection);
        const video = transfer.kind == .video;
        var filename_buffer: [96]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buffer, "xvid-{s}-{d}.{s}", .{ plan.status_id, item.ordinal, if (video) "mp4" else "jpg" });
        try writer.writeAll("<article class=\"artifact-row\" data-direct-file data-url=\"");
        try escapeAttribute(writer, transfer.url);
        try writer.writeAll("\" data-item-id=\"");
        try escapeAttribute(writer, item.id);
        try writer.writeAll("\" data-filename=\"");
        try escapeAttribute(writer, filename);
        try writer.print("\" data-kind=\"{s}\"><div class=\"artifact-copy\"><strong>{s} {d}</strong><span>", .{ if (video) "video" else "image", if (video) "Video" else "Photo", item.ordinal });
        try escape(writer, selection.label);
        try writer.writeAll("</span></div><div class=\"artifact-actions\"><button class=\"primary-action\" type=\"button\" data-direct-download hidden>Download</button><button class=\"secondary-action\" type=\"button\" data-direct-share hidden>Save…</button><button class=\"text-action\" type=\"button\" data-direct-cancel hidden>Cancel</button><a class=\"download-action\" target=\"_blank\" rel=\"noreferrer\" referrerpolicy=\"no-referrer\" href=\"");
        try escapeAttribute(writer, transfer.url);
        try writer.writeAll("\">Open original</a></div><div class=\"device-preparation\" data-direct-progress hidden><div><span data-direct-status>Downloading…</span><span data-direct-percent></span></div><progress></progress></div><p class=\"field-error\" data-direct-error role=\"alert\" hidden></p></article>");
    }
    try writer.writeAll("</div>");
    if (plan.items.len == 1) try writer.writeAll(if (plan.items[0].kind == .photo) "<img class=\"playback image-playback\" data-direct-preview hidden alt=\"Original photo\">" else "<video class=\"playback\" data-direct-preview hidden controls playsinline preload=\"metadata\"></video>");
    if (snapshot.data.expires_at) |expires| try writer.print("<p class=\"expiry-note\" data-expiry data-direct-expiry data-expires-at=\"{d}\">Temporary links expire automatically.</p>", .{expires});
    try writer.writeAll("</section>");
}

fn renderReadyActions(writer: *std.Io.Writer, snapshot: job_mod.Snapshot, source_only: bool) !void {
    const prepared = hasPreparedMedia(snapshot.data.output_artifacts);
    const source_artifacts = snapshot.data.source_artifacts;
    const output_artifacts = snapshot.data.output_artifacts;
    const preferred = if (source_only or !prepared) source_artifacts else output_artifacts;
    if (preferred.len == 0 and output_artifacts.len == 0) {
        try writer.writeAll("<div class=\"inline-message error\">No validated file is available.</div>");
        return;
    }

    const automatic_download = automaticDownloadArtifact(snapshot);
    if (!source_only and multiPhotoShareEligible(snapshot)) try writer.writeAll("<button class=\"primary-action photo-share-action\" type=\"button\" data-share-photos hidden>Save all photos…</button>");

    if (!source_only and preferred.len > 1) {
        if (findBundle(output_artifacts)) |bundle| {
            try writer.writeAll("<a class=\"primary-link\" href=\"");
            try artifactUrl(writer, snapshot.data.id, bundle, true);
            try writer.writeAll("\" download");
            if (automatic_download != null and std.mem.eql(u8, automatic_download.?, bundle.id)) try writer.writeAll(" data-auto-download");
            try writer.writeAll(">Download all (.zip)</a>");
        }
    }

    try writer.writeAll("<div class=\"artifact-list\">");
    for (preferred) |artifact| try renderArtifact(writer, snapshot.data.id, artifact, preferred.len == 1, automatic_download != null and std.mem.eql(u8, automatic_download.?, artifact.id));
    if (!source_only and !prepared) for (output_artifacts) |artifact| if (artifact.media_kind == .unknown) {
        if (preferred.len <= 1) try renderArtifact(writer, snapshot.data.id, artifact, false, automatic_download != null and std.mem.eql(u8, automatic_download.?, artifact.id));
    };
    try writer.writeAll("</div>");
}

fn renderArtifact(writer: *std.Io.Writer, job_id: []const u8, artifact: job_mod.Artifact, primary: bool, automatic_download: bool) !void {
    try writer.writeAll("<article class=\"artifact-row\"><div class=\"artifact-copy\"><strong>");
    try escape(writer, artifact.filename);
    try writer.writeAll("</strong><span>");
    try writer.writeAll(mediaKindLabel(artifact.media_kind));
    try writer.writeAll(" · ");
    try formatBytes(writer, artifact.size_bytes);
    try writer.writeAll("</span></div><div class=\"artifact-actions\">");
    if (shareableArtifact(artifact)) {
        try writer.writeAll("<button class=\"share-action\" type=\"button\" data-share-file data-share-url=\"");
        try artifactUrl(writer, job_id, artifact, false);
        try writer.writeAll("\" data-share-id=\"");
        try escapeAttribute(writer, artifact.id);
        try writer.writeAll("\" data-share-name=\"");
        try escapeAttribute(writer, artifact.filename);
        try writer.writeAll("\" data-share-type=\"");
        try escapeAttribute(writer, artifact.mime_type);
        try writer.writeAll("\" data-share-kind=\"");
        try writer.writeAll(@tagName(artifact.media_kind));
        try writer.print("\" data-share-size=\"{d}\"", .{artifact.size_bytes});
        if (primary) try writer.writeAll(" data-share-primary");
        try writer.writeAll(" hidden>Save…</button>");
    }
    try writer.writeAll("<a class=\"download-action\" href=\"");
    try artifactUrl(writer, job_id, artifact, true);
    try writer.writeAll("\" download");
    if (automatic_download) try writer.writeAll(" data-auto-download");
    try writer.writeAll(">");
    try writer.writeAll(if (artifact.media_kind == .unknown) "Download ZIP" else "Download");
    try writer.writeAll("</a></div>");
    if (primary and shareableArtifact(artifact)) try writer.writeAll("<div class=\"device-preparation\" data-device-preparation hidden><div><span>Preparing save on this device…</span><span data-device-percent></span></div><progress data-device-progress></progress></div>");
    try writer.writeAll("</article>");
}

fn renderPlayback(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    const preferred = if (hasPreparedMedia(snapshot.data.output_artifacts)) snapshot.data.output_artifacts else snapshot.data.source_artifacts;
    const primary = playableArtifact(preferred) orelse return;
    switch (primary.media_kind) {
        .video => {
            try writer.writeAll("<video class=\"playback\" controls preload=\"metadata\" playsinline");
            if (primary.poster != null) {
                try writer.writeAll(" poster=\"");
                try posterUrl(writer, snapshot.data.id, primary);
                try writer.writeByte('"');
            }
            try writer.writeAll(" src=\"");
        },
        .audio => try writer.writeAll("<audio class=\"playback audio-playback\" controls preload=\"metadata\" src=\""),
        .image => try writer.writeAll("<img class=\"playback image-playback\" loading=\"eager\" alt=\"Downloaded image\" src=\""),
        else => return,
    }
    try artifactUrl(writer, snapshot.data.id, primary, false);
    try writer.writeAll("\">");
    try writer.writeAll(switch (primary.media_kind) {
        .video => "Your browser cannot play this video.</video>",
        .audio => "Your browser cannot play this audio.</audio>",
        .image => "",
        else => unreachable,
    });
}

fn renderFailure(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    try writer.writeAll("<section class=\"problem-view\" role=\"alert\"><p class=\"section-kicker\">Could not save</p><h2>");
    const code = if (snapshot.data.failure) |failure| failure.code else "";
    if (std.mem.eql(u8, code, "X_PRIVATE") or std.mem.eql(u8, code, "X_LOGIN_REQUIRED")) {
        try writer.writeAll("This media is not public");
    } else if (std.mem.eql(u8, code, "X_RATE_LIMITED") or std.mem.eql(u8, code, "X_TEMPORARY") or std.mem.eql(u8, code, "PROBE_TIMEOUT")) {
        try writer.writeAll("X could not answer right now");
    } else if (std.mem.eql(u8, code, "UNSUPPORTED_URL")) {
        try writer.writeAll("This link is not supported");
    } else {
        try writer.writeAll("The media could not be delivered");
    }
    try writer.writeAll("</h2><p>");
    if (snapshot.data.failure) |failure| try escape(writer, failure.message) else try writer.writeAll("Try another public X post.");
    try writer.writeAll("</p></section>");
}

fn renderCancelled(writer: *std.Io.Writer) !void {
    try writer.writeAll("<section class=\"problem-view calm\" role=\"status\"><p class=\"section-kicker\">Cancelled</p><h2>Download cancelled</h2><p>No file will be published from this job.</p></section>");
}

fn renderCancel(writer: *std.Io.Writer, id: []const u8) !void {
    try writer.writeAll("<form class=\"cancel-form\" method=\"post\" action=\"");
    try jobUrl(writer, id, "cancel");
    try writer.writeAll("\" data-nav-form><button class=\"text-action\" type=\"submit\">Cancel</button></form>");
}

fn renderUtilities(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    if (!snapshot.data.state.terminal()) return;
    try writer.writeAll("<footer class=\"job-utilities\"><form method=\"post\" action=\"");
    try jobUrl(writer, snapshot.data.id, "delete");
    try writer.writeAll("\" data-nav-form><button class=\"danger-action\" type=\"submit\">");
    try writer.writeAll(if (snapshot.data.direct_delivery) "Clear" else "Delete files now");
    try writer.writeAll("</button></form></footer>");
}

fn productState(snapshot: job_mod.Snapshot) []const u8 {
    return switch (snapshot.data.state) {
        .probing => "checking",
        .awaiting_choice => "choose",
        .queued, .acquiring, .preparing => "working",
        .ready => "ready",
        .failed, .cancelled => "problem",
    };
}

fn mediaKindLabel(kind: job_mod.MediaKind) []const u8 {
    return switch (kind) {
        .video => "video",
        .audio => "audio",
        .image => "photo",
        .mixed => "mixed media",
        .unknown => "file",
    };
}

fn automaticDownloadArtifact(snapshot: job_mod.Snapshot) ?[]const u8 {
    if (snapshot.data.state != .ready or snapshot.data.intent != .save_original or snapshot.data.delivery == null or snapshot.data.delivery.?.mode != .original) return null;
    if (snapshot.data.source_artifacts.len == 1) return snapshot.data.source_artifacts[0].id;
    if (snapshot.data.source_artifacts.len < 2) return null;
    if (findBundle(snapshot.data.output_artifacts)) |bundle| return bundle.id;
    return null;
}

fn findBundle(artifacts: []const job_mod.Artifact) ?job_mod.Artifact {
    for (artifacts) |artifact| if (std.mem.eql(u8, artifact.mime_type, "application/zip")) return artifact;
    return null;
}

fn multiPhotoShareEligible(snapshot: job_mod.Snapshot) bool {
    if (snapshot.data.state != .ready or snapshot.data.source_artifacts.len < 2 or snapshot.data.source_artifacts.len > 4 or hasPreparedMedia(snapshot.data.output_artifacts)) return false;
    var total: u64 = 0;
    for (snapshot.data.source_artifacts) |artifact| {
        if (artifact.media_kind != .image or !shareableArtifact(artifact)) return false;
        total = std.math.add(u64, total, artifact.size_bytes) catch return false;
    }
    return total <= maximum_share_bytes;
}

fn shareableArtifact(artifact: job_mod.Artifact) bool {
    return artifact.size_bytes <= maximum_share_bytes and artifact.media_kind != .unknown;
}

fn hasPreparedMedia(artifacts: []const job_mod.Artifact) bool {
    for (artifacts) |artifact| if (artifact.media_kind != .unknown) return true;
    return false;
}

fn playableArtifact(artifacts: []const job_mod.Artifact) ?job_mod.Artifact {
    for (artifacts) |artifact| if (artifact.primary and artifact.media_kind != .unknown) return artifact;
    for (artifacts) |artifact| if (artifact.media_kind != .unknown) return artifact;
    return null;
}

fn artifactUrl(writer: *std.Io.Writer, job_id: []const u8, artifact: job_mod.Artifact, download: bool) !void {
    try jobUrl(writer, job_id, "artifact/");
    try escapeAttribute(writer, artifact.id);
    if (download) try writer.writeAll("?download=1");
}

fn posterUrl(writer: *std.Io.Writer, job_id: []const u8, artifact: job_mod.Artifact) !void {
    try artifactUrl(writer, job_id, artifact, false);
    try writer.writeAll("?poster=1");
}

fn jobUrl(writer: *std.Io.Writer, id: []const u8, suffix: []const u8) !void {
    try writer.writeAll("/j/");
    try escapeAttribute(writer, id);
    if (suffix.len > 0) {
        try writer.writeByte('/');
        try writer.writeAll(suffix);
    }
}

fn formatDuration(writer: *std.Io.Writer, seconds: u64) !void {
    if (seconds >= 3600) return writer.print("{d}h {d}m", .{ seconds / 3600, (seconds % 3600) / 60 });
    if (seconds >= 60) return writer.print("{d}m {d}s", .{ seconds / 60, seconds % 60 });
    return writer.print("{d}s", .{seconds});
}

fn formatBytes(writer: *std.Io.Writer, bytes: u64) !void {
    if (bytes >= 1024 * 1024 * 1024) return writer.print("{d:.1} GB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024)});
    if (bytes >= 1024 * 1024) return writer.print("{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024)});
    if (bytes >= 1024) return writer.print("{d:.1} KB", .{@as(f64, @floatFromInt(bytes)) / 1024});
    return writer.print("{d} B", .{bytes});
}

fn escape(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        0...31, 127 => try writer.print("&#{d};", .{byte}),
        else => try writer.writeByte(byte),
    };
}

fn escapeAttribute(writer: *std.Io.Writer, value: []const u8) !void {
    return escape(writer, value);
}

test "HTML escaping handles markup and control bytes" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try escape(&writer, "<x a='1'>&\"\n\r\x00\t");
    try std.testing.expectEqualStrings("&lt;x a=&#39;1&#39;&gt;&amp;&quot;&#10;&#13;&#0;&#9;", writer.buffered());
}

fn renderInstagramPicker(writer: *std.Io.Writer, snapshot: job_mod.Snapshot, plan: @import("instagram_plan.zig").Plan) !void {
    try writer.writeAll("<section class=\"instagram-picker\" aria-labelledby=\"instagram-title\"><h2 id=\"instagram-title\">Choose a photo or video</h2><div class=\"instagram-grid\">");
    for (plan.items) |item| {
        try writer.print("<article class=\"instagram-item{s}\" id=\"instagram-item-{d}\">", .{ if (plan.highlighted_ordinal == item.ordinal) " is-suggested" else "", item.ordinal });
        if (item.thumbnail_url != null) {
            try writer.writeAll("<img class=\"instagram-thumbnail\" loading=\"lazy\" decoding=\"async\" referrerpolicy=\"no-referrer\" src=\"");
            try jobUrl(writer, snapshot.data.id, "thumbnail/");
            try escapeAttribute(writer, item.id);
            try writer.print("\" alt=\"Preview of item {d}\">", .{item.ordinal});
        } else try writer.writeAll("<div class=\"instagram-thumbnail instagram-placeholder\">Preview unavailable</div>");
        try writer.print("<p class=\"source-meta\">{d} of {d} · {s}", .{ item.ordinal, plan.items.len, switch (item.kind) {
            .image => @as([]const u8, "Photo"),
            .video => "Video",
            .unknown => "Unavailable item",
        } });
        if (item.duration_ms) |duration| {
            try writer.writeAll(" · ");
            try formatDuration(writer, duration / 1000);
        }
        try writer.writeAll("</p>");
        if (plan.highlighted_ordinal == item.ordinal) try writer.writeAll("<p class=\"instagram-hint\">Item referenced by your link</p>");
        if (item.available()) {
            try writer.writeAll("<form method=\"post\" data-nav-form action=\"");
            try jobUrl(writer, snapshot.data.id, "start");
            try writer.writeAll("\"><button class=\"primary-action\" type=\"submit\" name=\"item_id\" value=\"");
            try escapeAttribute(writer, item.id);
            try writer.print("\">Save this {s}</button></form>", .{if (item.kind == .video) @as([]const u8, "video") else "photo"});
        } else try writer.writeAll("<p>This item is unavailable. Its position in the post has been preserved.</p>");
        try writer.writeAll("</article>");
    }
    try writer.writeAll("</div></section>");
    try renderCancel(writer, snapshot.data.id);
}
