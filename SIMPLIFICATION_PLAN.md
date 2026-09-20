# xvid simplification plan

Planning snapshot: 2026-09-04. Implementation and qualification: 2026-09-05.

## Current state and evidence

- `master` is `7e5a480`, matching the recorded remote. The current product uses a native Zig X resolver, SQLite usage state, temporary job files, and FFmpeg/FFprobe. It no longer needs a generic external extractor architecture.
- The real-process E2E harness covers source selection, downloads, conversion choices, rejection, cancellation, restart, expiry, and related HTTP behavior. Its encoder/prober and media responses are synthetic: conversion assertions match `fixture-output height=...`, not a decodable MP4.
- `src/x.zig` is roughly 1,900 lines and combines network acquisition, JSON interpretation, and media validation. Existing GraphQL/syndication paths serve concrete source behavior; they are not redundant just because there is more than one path.
- `scripts/vps_auto_deploy.sh` watches `master` and the exact revision's successful `Verify` workflow, then installs it. The workflow installs SQLite/tools but not real FFmpeg for its current fixture-only E2E run. The explicit deploy wrapper reruns verification before installation.

## Intended result

Keep the direct public-X-link-to-save/share flow. Improve the evidence for actual conversion, trim genuinely duplicated test scaffolding, and make only source refactors that clarify existing responsibilities. No provider framework, replacement extractor, new browser framework, or speculative compatibility layers.

## Implementation sequence

1. Verify the current default, deployed executable, compiler, and automatic deployment state. Record existing recovery/source identity before any future push, because an accepted master commit can deploy automatically even when the change is primarily tests.
2. Keep synthetic FFmpeg/probe fixtures for deliberate hangs, descendant-process cancellation, malformed output, and failure injection. Add one small real-media scenario to the same E2E harness: generate a short local video with real FFmpeg, serve it through the fixture upstream, submit it to the actual xvid process, request conversion, download the result, and inspect/decode the delivered artifact.
3. Give the fixture upstream an explicit test-only input-file option for this scenario, with advertised dimensions/duration matching the generated file; do not add a fixture switch or URL-validation bypass to the production application. Run the real-tools scenario in a separate disposable application/data directory with FFmpeg/FFprobe paths selected through existing configuration. Configure every upstream endpoint to the existing allowed loopback fixture, preserving production validation. Keep the ordinary failure fixtures independent.
4. Install the required FFmpeg tools/codecs in the existing CI job and document the local prerequisite. Missing tools must fail the real-media check clearly, not silently skip or fall back to the fake encoder. Keep the clip short and resource limits modest; no large binary fixture or new workflow is needed.
5. Review parser/network helpers for duplicated actual logic or confused ownership. Extract a cohesive internal parsing or media-validation module only if it removes coupling and makes existing tests clearer. Leave the file intact where extraction would merely add forwarding calls. Preserve URL/redirect validation, origin restrictions, bounded downloads, source precedence, and existing error classifications.
6. Consolidate repeated E2E request/wait/assertion scaffolding where it helps readability, while preserving distinct user outcomes. Remove literal markup/prose assertions only when a stronger observable outcome remains. Keep save/share behavior and useful failure paths; do not delete all small tests or all code called fallback.

## Verification and delivery

- Run the existing pinned ReleaseSafe test/E2E/build sequence, formatting, and JavaScript syntax checks. The new real-media scenario must exercise the actual application conversion path and HTTP download, not just a standalone FFmpeg command.
- Check video/audio codecs, dimensions, pixel format, nonzero duration, and successful decoding of the delivered file. Generate an MP4 with a supported but non-H.264 source video codec and a short audio track, then require the delivered H.264/AAC result to decode without errors. This forces the conversion branch instead of allowing an already-compatible source copy to pass. Retain controlled fixture tests for advanced selection, smaller output, cancellation, descendant cleanup, recovery, rejection, and expiry.
- Exercise only local synthetic media and upstream responses; live X availability is not a deterministic CI prerequisite. Preserve supported GraphQL/syndication behavior with existing source fixtures. Keep real submitted URLs, response bodies, credentials, and media links out of commits and diagnostic artifacts.
- Ensure failed setup and timed-out encoders clean up only the test's owned processes and temporary files. No process-name-wide kill or real data-directory cleanup. If browser save/share behavior changes, verify the actual affected browser flow in addition to server E2E; do not infer browser acceptance from curl.
- Review implementation, tests, process lifetime, and deploy interactions adversarially; repair findings and repeat until a full pass has no new or unresolved blockers. Push only reviewed task commits to `master` and verify the exact revision's `Verify` result.
- Coordinate with the existing auto-deployer rather than racing a second installation. For an explicit deployment use `scripts/vps_deploy.sh`; account for its clean-checkout requirement and required local media tools. Verify the running executable/revision, local/public readiness, a representative application route, and retained rollback before reporting deployment complete. Do not describe a push as tests-only/no-deployment if the active watcher will install it.

## Planning review

- Pass 1 found that a compatible generated input could bypass encoding, that fixture metadata must match the real media, and that a master push can deploy through the active watcher even for test-focused changes. The plan now forces actual conversion, uses existing loopback configuration rather than weakening URL validation, and explicitly coordinates deployment.
- Pass 2 inspected encoding eligibility/output checks, fixture routing, production install/rollback, and the active `xvid-auto-deploy.timer`. No unresolved or new planning blockers were found. Passing this local-media journey will prove conversion behavior, not current reachability or compatibility of every live X response.


## Implementation review correction

The implementation inspection found that the synthetic encoder's failure and
TERM-ignoring descendant branches existed but were not reached by the current
E2E script. They are useful failure mechanisms, not existing acceptance coverage.
The implementation adds explicit local-upstream scenarios for both, checking the
established source-retention behavior after optional encoding fails and actual
descendant termination on cancellation. The baseline passed 39 focused tests
and the existing HTTP journey (9/9 build steps).

The parser/network review found shared metadata transport and shared item
normalization already serving distinct GraphQL/syndication shapes. Binary
acquisition owns different streaming, cancellation, redirect, and file-validation
contracts. Moving these into another file would add interfaces without removing
duplicated logic, so `src/x.zig` remains intact. Production source, compiler,
configuration, URL policy, and save/share JavaScript are unchanged.

## Implemented changes and verification

- Added an explicit `--video-file` option to the test upstream and a separate
  real-tools/data-directory phase in the existing E2E script. It generates a
  one-second 320x240 MPEG-4/AAC MP4, checks source metadata against the advertised
  dimensions/duration, requests Compatible MP4 through the real application,
  downloads the prepared artifact over HTTP, verifies H.264/AAC/yuv420p and its
  dimensions/duration, and decodes both streams with FFmpeg's error-exit behavior.
  No binary fixture, production bypass, or new workflow was introduced.
- Installed FFmpeg in the existing Verify job and documented the prerequisite.
  Missing tools fail before startup. Requests and standalone media tools have
  bounded time limits; every configured upstream remains the local fixture.
- Wired the existing encoder failure and descendant-stall behaviors into actual
  application jobs. The first proves the current warning/source-retention
  outcome and downloadable source bytes; the second proves cancellation removes
  the TERM-ignoring descendant before the test's cleanup runs.
- Replaced copied page prose/version assertions with served-JavaScript byte
  equality, available form choices, and validation of the HTTP-downloaded ZIP.
  Replaced ineffective standalone `! rg` assertions with a helper that requires
  the no-match exit status; unreadable files also fail. Privacy checks look for
  the actual fixture URL/token markers. Failure diagnostics report stage/line
  without printing commands, provider payloads, manifests, or captured pages.
- Each application instance owns a separate process session. Failure and signal
  cleanup terminate that session's children, including separate encoder process
  groups, without process-name kills or stale descendant PID-file cleanup.

### Adversarial review evidence

1. Baseline: 9/9 build steps, 39/39 focused tests, and the original real-process
   journey passed. The expanded journey passed with real FFmpeg/FFprobe, encoder
   failure/source retention, and actual descendant cancellation.
2. Review found the previously dormant failure fixtures and Bash negation issue;
   corrected both. The final complete review checked fixture metadata, forced
   conversion, complete HTTP delivery/decoding, process/session lifetime, quiet
   failure diagnostics, actual assertion failure, source limits, and deploy
   interaction. No unresolved or new implementation blockers remained.
3. Local negative checks proved missing FFprobe fails at bootstrap; injected
   forbidden log data fails without being printed; a forced failure with the
   descendant alive removes both the application session and descendant; and
   corrupting the delivered MP4 after its metadata check fails at the decoder.
   Every negative run removed its owned temporary data.
4. Final ReleaseSafe test/E2E completed all 9 build steps and the full expanded
   journey; the executable install build passed all 3 steps. JavaScript syntax,
   Zig formatting, shell syntax, and diff checks passed. Production source,
   assets, compiler pin, schema/configuration, and deployment scripts are
   unchanged. The existing focused tests remain intact.

## Delivery boundary

Before push, the active service was PID `862641`, the installed controller
recorded `7e5a480`, local/public readiness passed, and the auto-deploy timer was
active. Binary/unit/configuration hashes, the rollback pair, and database
identity/count aggregates were recorded without retaining submitted URLs or
media. Publish the reviewed commit and await its exact Verify run and the
existing auto-deployer, then prove the installed/running executable match,
revision record, public/local routes, retained rollback pair, and persistent
usage state. Delivery identifiers are recorded outside this source commit to
avoid another deployment merely to record its own hash.

## Follow-up: 2026-09-20

### Current facts and scope

Current default and installed production are59a8481 (Verify35258319485 passed).
The clean primary checkout remains3177549 and UX worktreeb662287; this task uses
an isolated current-default checkout. Production PID1710925 matches installed
SHA256d84194bc5c9eba1c79118df89ebc3132259d1a8d4538402793bdc12f67c3b043, zero restarts.
The minute timer still deploys only successful exact-master Verify revisions.

Baseline ReleaseSafe test/E2E passes10/10steps and43tests, including current
browser direct-download behavior, Instagram, real MPEG-4/AAC input converted to
fully decoded H.264/AAC, source retention and descendant cancellation. The
reviewed upstream extractor blob is unchanged today. One reviewed upstream
public sample returnedXProviderChanged; inspect safe stage/status traces and
real provider behavior before drawing a compatibility conclusion.

New independent failure evidence:
- With10s inactivity configured, trickled headers keep all16HTTP workers busy
  beyond11s and readiness stalls; TERM does not exit while those peers progress.
  An entirely idle partial request does time out correctly. Preserve that
  distinction rather than replacing a working path without evidence.
- TERM during a fixture encode leaves the application and its owned,
  TERM-ignoring encoder descendant running; normal explicit job cancellation
  already works. Shutdown must use that cancellation ownership without marking
  resumable work as a user cancellation.
- A disposable installer fixture whose systemd restart fails exits73 with the
  candidate binary and unit still installed. Only readiness failure currently
  triggers rollback. No real service/data/configuration was used in the fixture.

### Acceptance and narrow implementation

1. Bound cumulative request-read waiting using the existing HTTP timeout and
   monotonic nonblocking reads, so trickles cannot retain workers forever.
   Preserve response-write inactivity semantics: large file transfers and SSE
   must remain valid while progressing. Do not impose a total download limit,
   new provider framework or consumer SDK adoption. Make overload reply writes
   nonblocking. Preserve URL/origin/body limits and privacy-safe errors.
2. Track active HTTP descriptors under the existing queue lock from dequeue
   through final close. Stop accepting/queued work, allow a short bounded drain,
   then shut down remaining registered sockets before joining. Make SSE observe
   shutdown. Interrupt owned probe/media operations through existing per-job
   cancellation flags; preserve persisted states for restart recovery. Test
   TERM with stalled HTTP, nonterminal SSE and an actual TERM-ignoring encoder
   descendant, then restart the same disposable data and prove recoverability.
3. Extend the existing install/rollback transaction to every failure after
   promotion begins, including restart and executable-identity verification.
   Keep its lock, exact-source builds, old binary/unit pair and auto watcher.
   Remove the redundant default-data mkdir (doctor already requires the actual
   configured data directory). Use isolated command fixtures to prove success,
   restart/readiness/hash/post-install failure rollback, preserved prior
   revision/auto-controller files, and refusal of concurrent installation.
   Do not introduce another deployment mechanism.
4. Investigate the live canary using only redacted stage/status/shape evidence.
   Repair a demonstrated resolver or delivery defect with generated fixtures;
   repeat an actual application/browser canary where upstream access permits.
   Do not log real submitted/media links, auth values or provider bodies, copy
   real responses into fixtures, bypass access controls, or claim one fixture
   or canary covers every live response.
5. Run meaningful new failure regressions, existing ReleaseSafe test/E2E/build,
   browser direct/save/share/navigation coverage, source export, formatting and
   shell checks. Require two consecutive complete clean implementation reviews
   after fixing findings; retain existing real conversion and process proofs.
6. Before push, take an online SQLite backup with integrity/schema/aggregate
   evidence and record configuration, data identity, installed/rollback hashes.
   Push only task changes to default; verify exact Verify and let the existing
   watcher install. Verify revision -> artifact -> PID/hash, local/public
   routes/assets, usage integrity/schema, rollback identities and fresh logs.
   No real-data failure injection, unrelated checkout edits, or second installer
   races. Fix and re-review/redeploy if post-deployment evidence fails.

### Follow-up plan reviews

- Pass1, complete product/failure perspective found that applying a cumulative
  budget to response writes would break legitimate large downloads. Restrict
  the cumulative bound to request reads and preserve write inactivity. Also
  distinguish in-memory shutdown interruption from persisted user cancellation
  so unfinished work survives restart. The installer must restore controller
  and revision state as well as binary/unit on later failures. Resolved these
  in acceptance above; clean count reset.
- Pass2, complete behavior/security/lifetime perspective: traced HTTP queue,
  read/write semantics, SSE loop, existing process-group cancellation, registry
  ownership and persisted recovery. Failure tests retain real descendant and
  conversion behavior, with no body/credential logging or speculative parser
  changes. Zero planning findings; clean1.
- Pass3, complete operational/preservation perspective: checked exact remote,
  current runtime, auto-deploy lock and Verify gate, installer failure boundary,
  native backup procedure and isolated checkouts. Live-source investigation has
  explicit evidence and external-access criteria; synthetic success cannot
  replace it. No app pin, schema, environment or unrelated work is adopted.
  Zero planning findings; clean2.

- Pass4, final shutdown-path audit found that flags alone cannot interrupt a
  provider blocked inside DNS/TLS/body reads, including synchronous link refresh
  in an HTTP worker. Use the existing Zig Io.Group concurrent/cancel ownership
  for the bounded HTTP and background worker sets, replacing their manual
  thread arrays. Preserve the same configured worker counts and queue behavior.
  Set job interruption flags before group cancellation, and treat canceled work
  as interrupted rather than persisting a provider failure. Add a deliberate
  progressing-but-incomplete metadata response to the shutdown/restart journey.
  This is task cancellation, not a new provider abstraction. Reset clean count.
- Pass5, complete cancellation/data review: checked std.Io.Group cancellation
  against the pinned implementation and existing native HTTP/process call
  boundaries. Groups own their tasks until cancellation/join completes; socket
  shutdown remains under the descriptor registry lock. Persisted job states and
  retained source survive cancellation and restart. Zero findings; clean1.
- Pass6, complete operations/product review: long outgoing transfers retain
  inactivity semantics; active provider, SSE and encoder work have explicit
  shutdown acceptance; startup failures cancel already-started tasks before
  freeing queues/state. Installer transaction and automatic delivery boundaries
  remain unchanged in scope. Zero findings; clean2.

### Follow-up implementation review and acceptance

- Pass1, complete failure/recovery review found an actual descendant leak when
  Io cancellation reached the encoder. `defer child.kill` ran before the older
  `errdefer` group signal, reaped the leader and cleared its PID. Reordered both
  process runners so group cleanup runs before reaping. Strengthened acceptance
  to force immediate I/O cancellation separately from held-HTTP drain, checking
  descendant absence before cleanup, persisted states, restarted probing and
  preparation, and byte-identical retained-source recovery. Also preserved
  cancellation as a terminal transport outcome instead of retrying it, and
  removed preparation's cancellation-flag reset. Clean count reset to zero.
- Pass2, complete functional/security/ownership review: traced per-request read
  budgets, outgoing inactivity, registered-fd dequeue/close/force ordering,
  concurrent group startup/cancellation, SSE termination, background interruption,
  process-group cleanup and persisted recovery. Full ReleaseSafe suite passes
  11/11steps and43tests, including held/trickled HTTP, immediate shutdown with
  SSE/provider/encoder work, all existing browser and Instagram journeys, actual
  MPEG-4/AAC conversion through HTTP with full decoding, and source-retention
  failure paths. Seven installer scenarios pass: success, restart failure,
  readiness failure, wrong running hash, late controller/timer failure, dirty
  source rejection and lock serialization. No new URL/response/credential logs,
  format changes, provider fallback or application dependency were introduced.
  Zero findings; clean1.
- Pass3, complete package/live-product/delivery review: clean source export
  (62files,850482bytes, no generated caches) independently passes the full
  11-step/43-test ReleaseSafe graph. Two native-video public samples resolve
  through real GraphQL, and an actual Chromium journey with CSP/CORS enforced
  downloads537709bytes directly from the CDN, fully decodes720pH.264/AAC and
  removes its owned job without server media staging. Older upstream examples
  remain unavailable/unsupported; no universal live-response claim is made.
  The private canary verifier was corrected to accept reflected allowed CORS
  origins and use the actual /j/<id>/delete route; application behavior was sound.
  Verified the unchanged upstream reference, auto-deployer's exact Zig2085,
  untouched config/schema/assets/unit/UX worktree, online SQLite integrity and
  candidate/actual rollback doctors against isolated backup copies. Existing
  source/revision/lock/rollback mechanisms remain authoritative. Zero findings;
  clean2. Exact Verify and live automatic delivery are recorded externally.
