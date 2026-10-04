# Agent Instructions

- Use `mise` for repository tools.
- Run `mise run check --lint` and `mise run test` after changes.
- Use Conventional Commit subjects; breaking v2 changes require a breaking marker.
- Keep the action focused on prebuilt `cf` deployment. Callers own workflow
  triggers, permissions, environments, builds, and required-check guards.
- Version uploads and deployments must use the caller's pinned CLI and exact
  Worker name. Never rebuild or silently install a CLI.
- Preserve Worker-scoped tokens by keeping trigger synchronization opt-in.
  Additional permissions depend on the resources explicitly synchronized.
- `cf` beta still writes version metadata to `WRANGLER_OUTPUT_FILE_PATH`.
  Verify this contract and deployment readback when upgrading the tested CLI.
