# Working agreement

- Follow the user's requested scope and YAGNI. Do not turn suggestions, review
  notes, or model preferences into permanent repository policy.
- Keep the current product direct: public X status URL -> native Zig resolver ->
  validated temporary media -> save/share.
- Preserve unrelated work and avoid speculative abstractions, dependencies, and
  compatibility layers.
- Never commit or log submitted URLs, media URLs, tokens, cookies, or response
  bodies.
- Match validation to the change. Use focused Zig tests for internals and the
  real-process E2E journey for user-facing/runtime changes. Add another test
  framework or release gate only for a demonstrated need.
- When deployment is requested, use `scripts/vps_deploy.sh` and verify the public
  readiness route and running executable before reporting success.
