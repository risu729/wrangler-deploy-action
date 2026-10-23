# Agent Instructions

- Use `mise` for repository tools.
- Run `mise run check --lint` and `mise run test` after changes.
- Use Conventional Commit subjects; breaking v2 changes require a breaking marker.
- Keep the action focused on prebuilt `cf` deployment. Callers own workflow
  triggers, permissions, environments, builds, and required-check guards.
  The only exception is `worker-preview` with `prebuilt: false`, which runs
  cf's documented `cf previews deploy` build because cf has no standalone
  Preview build command.
- Version uploads and deployments must use the caller's pinned CLI and exact
  Worker name. Never rebuild or silently install a CLI.
- Preserve Worker-scoped tokens by keeping trigger synchronization opt-in.
  Additional permissions depend on the resources explicitly synchronized.
- `cf` beta still writes version metadata to `WRANGLER_OUTPUT_FILE_PATH`.
  Verify this contract and deployment readback when upgrading the tested CLI.

## Language

- Use English for repository documentation, source comments, commit messages,
  and pull request titles and descriptions.
- Preserve the meaning of intentional localization content and test fixtures.
