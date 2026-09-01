const std = @import("std");
const job_mod = @import("job.zig");

const maximum_share_bytes = 64 * 1024 * 1024;
const asset_version = "3";

pub const home =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    \\  <meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
    \\  <meta name="theme-color" content="#0b0b0b" media="(prefers-color-scheme: dark)">
    \\  <title>xvid</title>
    \\  <meta name="description" content="Save photos and videos from public X posts.">
    \\  <link rel="icon" href="/assets/icon.svg" type="image/svg+xml">
    \\  <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
    \\  <link rel="manifest" href="/manifest.webmanifest">
    \\  <link rel="stylesheet" href="/assets/app.css?v=3">
    \\  <script src="/assets/app.js?v=3" defer></script>
    \\</head>
    \\<body>
    \\  <main id="app" class="app-shell compose-shell" data-page-state="compose">
    \\    <header class="app-header"><a class="brand" href="/" aria-label="xvid home">xvid</a></header>
    \\    <section class="compose-view" aria-labelledby="compose-title">
    \\      <div class="compose-copy">
    \\        <h1 id="compose-title">Save media from an X link</h1>
    \\        <p>Photos and videos from public X or Twitter posts. Files remain temporary.</p>
    \\      </div>
    \\      <form class="link-form" action="/jobs" method="post" data-link-form data-nav-form>
    \\        <label for="url">Public X post link</label>
    \\        <div class="url-control">
    \\          <input id="url" name="url" type="url" inputmode="url" autocomplete="url" autocapitalize="none" autocorrect="off" spellcheck="false" required maxlength="4096" placeholder="https://x.com/…/status/…" aria-describedby="link-help link-error">
    \\          <button class="clear-input" type="button" data-clear-input hidden aria-label="Clear link">×</button>
    \\        </div>
    \\        <p id="link-error" class="field-error" data-link-error hidden></p>
    \\        <button class="primary-action" type="submit" data-basic-submit><span data-basic-label>Save media</span></button>
    \\        <button class="text-action advanced-entry" type="submit" name="advanced" value="1" data-advanced-submit>Choose quality or format</button>
    \\      </form>
    \\      <p id="link-help" class="privacy-note">Public status links only · no accounts · files expire automatically</p>
    \\    </section>
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
    if (automatic_navigation and snapshot.data.intent == .save_original) try writer.writeAll(" data-auto-start");
    if (!snapshot.data.state.terminal()) {
        try writer.writeAll(" data-events=\"");
        try jobUrl(writer, snapshot.data.id, "events");
        try writer.writeByte('"');
    }
    try writer.writeAll("><header class=\"app-header\"><a class=\"brand\" href=\"/\" data-nav-link aria-label=\"xvid home\">xvid</a><span class=\"connection-state\" data-connection-state hidden></span></header><div id=\"job-state\">");
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

pub fn errorPage(writer: *std.Io.Writer, title: []const u8, message: []const u8) !void {
    try writer.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\"><meta name=\"theme-color\" content=\"#ffffff\" media=\"(prefers-color-scheme: light)\"><meta name=\"theme-color\" content=\"#0b0b0b\" media=\"(prefers-color-scheme: dark)\"><title>");
    try escape(writer, title);
    try writer.print(" · xvid</title><link rel=\"icon\" href=\"/assets/icon.svg\" type=\"image/svg+xml\"><link rel=\"stylesheet\" href=\"/assets/app.css?v={s}\"><script src=\"/assets/app.js?v={s}\" defer></script></head><body><main id=\"app\" class=\"app-shell problem-shell\" data-page-state=\"problem\"><header class=\"app-header\"><a class=\"brand\" href=\"/\" data-nav-link>xvid</a></header><section class=\"problem-view\" role=\"alert\"><p class=\"section-kicker\">Could not continue</p><h1>", .{ asset_version, asset_version });
    try escape(writer, title);
    try writer.writeAll("</h1><p>");
    try escape(writer, message);
    try writer.writeAll("</p><a class=\"primary-link\" href=\"/\" data-nav-link>Change link</a></section></main></body></html>");
}

fn renderSourceSummary(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    if (snapshot.data.probe) |probe| {
        try writer.writeAll("<header class=\"source-summary\"><p class=\"source-meta\">X");
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
        try writer.writeAll("<header class=\"source-summary\"><p class=\"source-meta\">X</p><h1>Checking link…</h1></header>");
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
        try writer.writeAll("</strong><span>Working</span></div><progress>Working</progress>");
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
    if (!wrote) try writer.writeAll(fallback_label);
    try writer.writeAll("</p></section>");
}

fn renderChoice(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    const probe = snapshot.data.probe orelse return;
    try writer.writeAll("<form class=\"choice-form\" method=\"post\" action=\"");
    try jobUrl(writer, snapshot.data.id, "start");
    try writer.writeAll("\" data-nav-form data-choice-form><div class=\"choice-heading\"><p class=\"section-kicker\">Choose what to save</p><h2>Available options</h2><p>Only choices that change the resulting file are shown.</p></div>");

    switch (probe.media_kind) {
        .mixed => try writer.writeAll("<input type=\"hidden\" name=\"kind\" value=\"all\"><input type=\"hidden\" name=\"delivery\" value=\"original\"><fieldset><legend>Media</legend><label class=\"radio-row selected-static\"><span><strong>All attached media</strong><small>Photos and videos in post order, plus a ZIP</small></span></label></fieldset>"),
        .image => try writer.writeAll("<input type=\"hidden\" name=\"kind\" value=\"image\"><input type=\"hidden\" name=\"delivery\" value=\"original\"><fieldset><legend>Media</legend><label class=\"radio-row selected-static\"><span><strong>Original photos</strong><small>No video conversion</small></span></label></fieldset>"),
        .video => {
            try writer.writeAll("<input type=\"hidden\" name=\"kind\" value=\"video\">");
            try renderQualityChoices(writer, probe);
            if (probe.item_count == 1) try renderPreparationChoices(writer, probe) else try writer.writeAll("<input type=\"hidden\" name=\"delivery\" value=\"original\">");
        },
        else => return,
    }

    try writer.writeAll("<div class=\"choice-action-bar\"><p data-selection-summary>");
    try initialSelectionSummary(writer, probe);
    try writer.writeAll("</p><button class=\"primary-action\" type=\"submit\">");
    try writer.writeAll(if (probe.item_count > 1) "Download media" else if (probe.media_kind == .image) "Download photos" else "Download video");
    try writer.writeAll("</button></div></form>");
}

fn renderQualityChoices(writer: *std.Io.Writer, probe: job_mod.Probe) !void {
    if (probe.variants.len == 0) return;
    try writer.writeAll("<fieldset class=\"choice-group\"><legend>Quality</legend>");
    for (probe.variants, 0..) |variant, index| {
        try writer.writeAll("<label class=\"radio-row\"><input type=\"radio\" name=\"variant\" value=\"");
        try escapeAttribute(writer, variant.id);
        try writer.writeAll("\"");
        if (index == 0) try writer.writeAll(" checked");
        if (variant.height) |height| try writer.print(" data-variant-height=\"{d}\"", .{height});
        try writer.writeAll("><span><strong>");
        try escape(writer, if (index == 0) "Best available" else variant.label);
        try writer.writeAll("</strong><small>Source file");
        if (variant.height) |height| try writer.print(" · {d}p", .{height});
        try writer.writeAll("</small></span><span class=\"row-value\">");
        if (variant.estimated_size_bytes) |size| {
            if (variant.estimated_size_kind == .approximate) try writer.writeAll("~");
            try formatBytes(writer, size);
        } else try writer.writeAll("—");
        try writer.writeAll("</span></label>");
    }
    try writer.writeAll("</fieldset>");
}

fn renderPreparationChoices(writer: *std.Io.Writer, probe: job_mod.Probe) !void {
    try writer.writeAll("<fieldset class=\"choice-group preparation-group\"><legend>File preparation</legend><label class=\"radio-row\"><input type=\"radio\" name=\"delivery\" value=\"original\" checked><span><strong>Keep source file</strong><small>Fastest. No extra video encoding.</small></span></label><label class=\"radio-row\"><input type=\"radio\" name=\"delivery\" value=\"optimise\"><span><strong>Compatible MP4</strong><small>H.264/AAC when the source needs it.</small></span></label>");
    if (probe.source_height) |height| {
        if (firstLowerTarget(height) != null) {
            try writer.writeAll("<label class=\"radio-row\"><input type=\"radio\" name=\"delivery\" value=\"downscale\"><span><strong>Smaller MP4</strong><small>Re-encode at a lower resolution.</small></span></label><div class=\"target-heights\" data-target-heights><p>Target resolution</p>");
            var first = true;
            inline for ([_]u32{ 2160, 1440, 1080, 720, 480, 360, 240 }) |target| {
                if (target < height) {
                    try writer.writeAll("<label class=\"target-chip\"><input type=\"radio\" name=\"target_height\" value=\"");
                    try writer.print("{d}\" data-target-height=\"{d}\"", .{ target, target });
                    if (first) {
                        try writer.writeAll(" checked");
                        first = false;
                    }
                    try writer.print("><span>{d}p</span></label>", .{target});
                }
            }
            try writer.writeAll("</div>");
        }
    }
    try writer.writeAll("</fieldset>");
}

fn initialSelectionSummary(writer: *std.Io.Writer, probe: job_mod.Probe) !void {
    switch (probe.media_kind) {
        .mixed => try writer.print("{d} items · source files", .{probe.item_count}),
        .image => try writer.print("{d} photo{s} · source files", .{ probe.item_count, if (probe.item_count == 1) "" else "s" }),
        .video => if (probe.variants.len > 0) {
            const best = probe.variants[0];
            if (best.height) |height| try writer.print("{d}p · keep source", .{height}) else try writer.writeAll("Best available · keep source");
            if (best.estimated_size_bytes) |size| {
                try writer.writeAll(" · ");
                if (best.estimated_size_kind == .approximate) try writer.writeAll("~");
                try formatBytes(writer, size);
            }
        } else try writer.writeAll("Best available · keep source"),
        else => try writer.writeAll("Source file"),
    }
}

fn renderReady(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    try writer.writeAll("<section class=\"ready-view\"><div class=\"ready-heading\" role=\"status\"><p class=\"section-kicker\">Ready</p><h2>Ready to save</h2></div>");
    try renderReadyActions(writer, snapshot, false);
    try renderPlayback(writer, snapshot);
    if (snapshot.data.expires_at) |expires_at| try writer.print("<p class=\"expiry-note\" data-expiry data-expires-at=\"{d}\">Temporary files expire automatically.</p>", .{expires_at});
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
    try writer.writeAll("</p><a class=\"primary-link\" href=\"/\" data-nav-link>Change link</a></section>");
}

fn renderCancelled(writer: *std.Io.Writer) !void {
    try writer.writeAll("<section class=\"problem-view calm\" role=\"status\"><p class=\"section-kicker\">Cancelled</p><h2>Download cancelled</h2><p>No file will be published from this job.</p><a class=\"primary-link\" href=\"/\" data-nav-link>Start another</a></section>");
}

fn renderCancel(writer: *std.Io.Writer, id: []const u8) !void {
    try writer.writeAll("<form class=\"cancel-form\" method=\"post\" action=\"");
    try jobUrl(writer, id, "cancel");
    try writer.writeAll("\" data-nav-form><button class=\"text-action\" type=\"submit\">Cancel</button></form>");
}

fn renderUtilities(writer: *std.Io.Writer, snapshot: job_mod.Snapshot) !void {
    if (!snapshot.data.state.terminal()) return;
    try writer.writeAll("<footer class=\"job-utilities\"><a href=\"/\" data-nav-link>Start another</a><form method=\"post\" action=\"");
    try jobUrl(writer, snapshot.data.id, "delete");
    try writer.writeAll("\" data-nav-form><button class=\"danger-action\" type=\"submit\">Delete files now</button></form></footer>");
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

fn firstLowerTarget(height: u32) ?u32 {
    inline for ([_]u32{ 2160, 1440, 1080, 720, 480, 360, 240 }) |target| if (target < height) return target;
    return null;
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

test "downscale targets remain below the source" {
    try std.testing.expectEqual(@as(?u32, 1080), firstLowerTarget(1440));
    try std.testing.expectEqual(@as(?u32, 360), firstLowerTarget(480));
    try std.testing.expect(firstLowerTarget(240) == null);
}
