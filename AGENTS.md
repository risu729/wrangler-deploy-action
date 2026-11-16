# Agent Instructions

This repository publishes the composite GitHub Action
`risu729/wrangler-deploy-action`, which deploys prebuilt Cloudflare Workers with
`cf`. [`action.yml`](action.yml) defines its inputs and outputs, and
[README.md](README.md) documents its behavior for callers; keep both accurate
when behavior changes. Renaming or removing an input or output, or changing what
a mode does, breaks callers.

## Language

Use English for everything published to GitHub: repository files, code comments,
commit messages, branch names, and the titles, descriptions and comments of pull
requests and issues. Do not translate existing content only to change its
language. Preserve intentional localizations, locale-specific fixtures, quoted
source text, and data whose exact wording is required for correctness.

## Development

`mise install` installs the pinned tools.

| Task                                 | Command                     |
| ------------------------------------ | --------------------------- |
| Lint and format with fixes           | `mise run check`            |
| Lint without fixes                   | `mise run check --lint`     |
| Bats tests with fake CLIs            | `mise run test`             |
| Real `cf` checks without credentials | `mise run test-integration` |

Run `mise run check --lint` and `mise run test` after changes. CI also runs the
composite action itself with the fakes in [`tests/fake-bin/`](tests/fake-bin),
and runs `integration:build` and `integration:verify` from
[`mise-tasks/integration/`](mise-tasks/integration) against
[`tests/fixtures/worker`](tests/fixtures/worker), which pins the tested `cf`
version in its `package.json`.

## Action Design

- Keep the action focused on prebuilt `cf` deployment. Callers own workflow
  triggers, permissions, environments, builds, and required-check guards.
  The only exception is `worker-preview`, which runs cf's documented
  `cf previews deploy` build because cf has no standalone Preview build.
- Version uploads and deployments must use the caller's pinned CLI and exact
  Worker name. Never rebuild or silently install a CLI.
- Preserve Worker-scoped tokens by keeping trigger synchronization opt-in.
  Additional permissions depend on the resources explicitly synchronized.
- `cf` beta still writes version metadata to `WRANGLER_OUTPUT_FILE_PATH`.
  Verify this contract and deployment readback when upgrading the tested CLI.

## Releases

Every push to `main` runs semantic-release
([`.github/workflows/release.yml`](.github/workflows/release.yml)), which tags
the commit and creates a GitHub release. The tag points at the committed
`action.yml` and shell scripts; there is no build step or generated bundle. The
release job does not wait for CI, so merging a PR releases whatever its commit
type implies. With the default `releaseRules` of
`@semantic-release/commit-analyzer` (13.0.1, as resolved by
`npm:semantic-release` 25.0.9; `lib/default-release-rules.js`):

- `feat` releases a minor version.
- `fix` and `perf` release a patch version. A revert releases a patch only when
  its message contains `This reverts commit <sha>`, as GitHub's Revert button
  produces; a bare `revert:` header releases nothing.
- A `BREAKING CHANGE:` footer, or `!` after the type such as
  `feat!: drop the prebuilt input`, releases a major version, even with a type
  such as `chore!:`. [`.releaserc.json`](.releaserc.json) sets
  `breakingHeaderPattern` for both the commit analyzer and the release notes
  generator, and `conventional-commits-parser` (6.4.0; `dist/CommitParser.js`)
  adds a `BREAKING CHANGE` note when it matches, so the release notes list the
  commit under BREAKING CHANGES too.
- Other types, such as `chore`, `ci`, `docs`, `refactor`, `build` and `test`,
  release nothing. Renovate uses `chore(deps)` and `ci(deps)` here, so
  dependency updates alone do not release.

Put the `!` or the `BREAKING CHANGE:` footer in a commit message or in the
squash commit message when merging; the PR description is not part of the
squash commit. Tags look like `v3.0.3`; there are no moving major tags. Callers
pin the full commit SHA with the tag as a comment, for example
`uses: risu729/wrangler-deploy-action@a371aa836e01c95d3928ba1a62b052229c7184c2 # v3.0.3`,
and receive a release only when Renovate updates that pin. The README examples
use the placeholder `V3_COMMIT_SHA` instead of a real pin.

## Change Workflow

- Keep one scope per pull request.
- Branch from the latest `main`, or from a prerequisite PR's branch when
  stacking under the global agent rules. Do not push to `main` directly.
- Write commit messages and PR titles as Conventional Commits, for example
  `fix: pass the Preview name with --preview-name for cf beta.32` or
  `chore(deps): update dependency cf to v1.0.0-beta.32`.
- Pull requests are squash-merged. GitHub uses the PR title as the squash commit
  subject only for multi-commit PRs; a single-commit PR keeps its commit
  subject, and the commit body is the concatenated commit messages, not the PR
  description. When merging, set the squash commit subject to the PR title.
- Every PR not opened by Renovate, including documentation-only PRs, needs a
  review by a reviewer that did not write the change (for an agent-authored PR,
  a separate review agent) before merging. Address each finding and summarize
  the review in the PR description.
- Before merging, wait until every CI job has finished. The required `CI Check`
  job runs only to fail when another job failed or was cancelled, so it shows as
  skipped when everything passed. CodeQL is also required. Never skip, disable
  or weaken a test or check to get CI green.
- Do not write an ADR, code or a PR for a design still under discussion with the
  owner. Propose it to the owner first and start only after explicit approval.
- Branches of merged PRs are deleted automatically. Delete branches of closed or
  abandoned PRs and other stale branches you created; leave `renovate/*`
  branches to Renovate.
- Do not merge a PR in a repository other than this one and the five listed in
  [Related Repositories](#related-repositories) unless the owner says to.
- Merging to `main` can publish a release (see [Releases](#releases)).

## Configuration Defaults

Do not set a configuration option to the value its tool already uses. Leave it
unset unless the repository needs a different value. This applies to every tool
configuration here, including `.github/renovate.json`, `.releaserc.json`,
`.yamllint.yaml`, `mise.toml` and `hk.pkl`. Check the default in the tool's
source at the version in use (see [External Tools](#external-tools)), not in its
documentation.

A value equal to the default is still needed when it overrides a different value
from an extended preset or an earlier rule, for example a Renovate
`packageRules` entry that restores a default changed by [the shared
preset](https://github.com/risu729/renovate-config). Keep such a value and say
in a comment what it overrides.

The default must be the same in every tool version the repository allows, such
as each mise version from `min_version`. When an older allowed version has a
different default, raise the minimum in the same change or keep the value.

## Design Decisions

Record every design decision in this repository. Nothing should live only in a
chat, an issue thread or agent memory.

- Large decisions get an ADR at `docs/adr/NNNN-kebab-case-title.md`, numbered
  from `0001`, with Status, Context, Decision and Consequences sections. The
  status of a new ADR is `Accepted (YYYY-MM-DD)`, since designs under discussion
  are not written down yet. A replaced ADR stays in place with its status set to
  `Superseded by NNNN`.
- Smaller decisions go in the `docs/` page, README section or AGENTS.md section
  that owns the behavior.
- Rules for agents live in this file only. Do not add `CLAUDE.md` or other
  agent-specific instruction files.
- Recorded decisions are the current design and stay in force until a change is
  approved. They are not proof that the design is right: when a better design
  exists, propose it with its reasoning.

## External Tools

This repository depends heavily on `cf`, the Cloudflare API, mise, hk, Renovate,
Bats and semantic-release. When their behavior matters and is unclear, read
their source code at the version in use (`mise.toml`, `mise.lock`, and
[`tests/fixtures/worker/package.json`](tests/fixtures/worker/package.json) for
`cf`) instead of guessing or relying on documentation alone. For the Cloudflare
API, read the endpoint's schema in Cloudflare's OpenAPI specification and link
it at a commit of the schema repository. Cite the file and line you relied on,
as a permalink at the tag or commit of that version (or the npm package version
when there is no tag), in the PR or document that depends on it.

## Related Repositories

These repositories are maintained together. The shared configuration
repositories release independently; consumers pin a released version, and
Renovate updates the pin.

- [renovate-config](https://github.com/risu729/renovate-config) provides the
  Renovate preset. Consumers extend it, for example
  `extends: ["github>risu729/renovate-config#3.23.3"]`.
- [hk-config](https://github.com/risu729/hk-config) provides hk `presets.pkl`
  and `helpers.pkl`. Consumers amend and import them in `hk.pkl` by tagged URL,
  for example
  `https://raw.githubusercontent.com/risu729/hk-config/v3.1.0/presets.pkl`.
- [tsconfigs](https://github.com/risu729/tsconfigs) provides the npm package
  `@risu729/tsconfigs`. This repository has no TypeScript and does not use it.

This repository uses renovate-config and hk-config.
[dotfiles](https://github.com/risu729/dotfiles) and
[github-notification-cleanup](https://github.com/risu729/github-notification-cleanup)
consume all three shared configurations and call this action. The shared
configuration repositories also consume each other: renovate-config uses
hk-config and tsconfigs, tsconfigs uses renovate-config and hk-config, and
hk-config uses renovate-config.

This action is also called by other repositories of risu729 outside these six.
Before a change that callers may notice, check every caller that is not
archived. Find them with
`gh search code risu729/wrangler-deploy-action --owner risu729`. Code search
covers only default branches and excludes forks, and its results do not show
whether a repository is archived, so check each one with
`gh api repos/risu729/<repo> --jq .archived` and skip archived ones. Before
changing a shared configuration, follow its AGENTS.md.

When a change needs callers to adapt, update them instead of adding backward
compatibility. Release first, then open a PR in each caller that pins the new
release, and link those PRs from the original PR. Do not merge PRs outside these
six repositories unless the owner says to (see
[Change Workflow](#change-workflow)).

## Renovate Pull Requests

Check open Renovate PRs in this repository and the five listed above every day.

Merge a Renovate PR by hand only when it is a major update, or a grouped PR
containing one, that meets all of these conditions:

- It needs no code or configuration change in this repository.
- It brings no new feature that this repository would want to adopt.
- It does not affect this repository or its callers (see
  [Related Repositories](#related-repositories)). A major update that changes
  what this repository publishes is never merged by an agent.

Judge these from the release notes and changelog, and from the source at the
new version when they are unclear, and follow the merge rules in
[Change Workflow](#change-workflow). Do not merge any other Renovate PR by
hand; Renovate automerges what its settings allow. When a major update fails a
condition, do not change code for it; report to the owner what it would need.

A `cf` update in the fixture's
[`package.json`](tests/fixtures/worker/package.json) is a prerelease bump that
Renovate automerges once CI passes, but `cf` beta releases can change commands
and flags that the action calls. When CI fails on one, or a caller's deploy
breaks after one, fix the action with a `fix:` commit so that a release is
published, as for `--preview-name` in cf 1.0.0-beta.32.

The [shared preset][preset] (consumers pin a release of it, so check the pinned
tag when it differs from `main`) waits one day after a timestamped release
(`minimumReleaseAge`), except for `risu729/**` and `@risu729/**` packages. It
automerges minor, patch, pin, digest and lock file maintenance updates, and
every update of mise itself, including majors, since mise uses CalVer. Renovate
enables GitHub auto-merge on them, so GitHub merges each one once the required
checks pass (renovate-config 3.23.4 and later keep Renovate's default
`platformAutomerge: true`). A Renovate PR that stays open usually has a failing
check or is a major update.

When a Renovate PR fails, find the root cause instead of retrying. The same
update often lands in several of the repositories at once, for example a shared
dev tool such as hk or mise. Check the same update in the other repositories,
fix the cause once, and apply the same fix to every affected repository. When
the cause is in a shared configuration repository, fix it there with a `fix:` or
`feat:` commit so that a release is published; consumers receive it through the
Renovate update of their pin.

[preset]: https://github.com/risu729/renovate-config/blob/main/src/default.json5
