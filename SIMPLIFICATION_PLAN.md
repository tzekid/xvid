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
