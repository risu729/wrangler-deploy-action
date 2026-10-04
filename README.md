# Cloudflare Deploy Action

Publish prebuilt Cloudflare Workers with `cf`, Workers Previews, version URLs, and
Worker-scoped tokens. The repository name remains `wrangler-deploy-action`;
**v2 runs cf**. Existing v1 releases continue to run Wrangler.

The caller installs and pins `cf`, builds the project, and verifies any artifact
revision/checksum before invoking this action. The action neither builds nor
installs tools. It resolves a declared package-local `cf` (including hoisted
packages and Yarn Plug'n'Play), then a configured mise tool. Undeclared
transitive binaries are ignored.

Tested with `cf@1.0.0-beta.12`. cf is beta: pin its version and verify upgrades.
Version uploads still use `WRANGLER_OUTPUT_FILE_PATH` internally for structured
metadata. Workers Previews use the documented JSON stdout response instead.
Human-readable terminal output is never parsed.

## Operations

| Mode | Behavior |
| --- | --- |
| `worker-preview` | Deploy Preview Build Output to a named Workers Preview and verify the resource and latest deployment. |
| `delete-preview` | Delete the exact named Preview and verify its absence; already missing is success. No build or cf installation is required. |
| `preview-or-dry-run` | With credentials, upload a version with a stable preview alias. With neither credential, validate without uploading. |
| `dry-run` | Validate existing Build Output without uploading, rebuilding, or changing traffic. |
| `production` | Upload a version, deploy that exact version at 100%, then read the deployment back and verify the allocation. |

Production and legacy version uploads use `cf workers versions create --prebuilt --mode <build-mode>
--worker <worker>`. Production uses `cf workers deployments create` followed by
`cf workers deployments get`. No operation calls `cf deploy`.

Legacy `preview-or-dry-run` uses version URLs on an existing Worker.
Use `worker-preview` for branch and PR environments. Neither changes production
traffic. For legacy version URLs, enable `previewUrls`
in `cloudflare.config.ts`; Workers without version URL support should use
`dry-run` mode.

Routes, Custom Domains, cron schedules, queue consumers, and other triggers
are preserved by default. Set `deploy-triggers: 'true'` explicitly to run
`cf workers triggers deploy --prebuilt` after a verified production deployment.
If trigger synchronization fails, the action fails, but the new version has
already been deployed. No automatic rollback is attempted.

## Usage

Migrate the project to `cloudflare.config.ts` first. Install dependencies from
the lockfile, then build with `cf build`. A Vite build records `production` by
default; a different build mode must be passed through `build-mode`.

Replace `V2_COMMIT_SHA` below with the full commit SHA of the selected v2 release.
Keep workflow triggers, permissions, concurrency, environments, and required
checks in the calling workflow. Only deploy production after those checks pass.

### Workers Previews for pull requests

Build Preview output explicitly, then deploy it with the pinned Cloudflare Vite plugin, then deploy with the pinned cf:

```yaml
- name: Build Preview
  working-directory: worker
  run: bun run cf-vite build --preview
- name: Deploy Preview
  uses: risu729/wrangler-deploy-action@V2_COMMIT_SHA
  with:
    mode: worker-preview
    working-directory: worker
    worker: dotfiles-worker
    preview-name: pr-${{ github.event.pull_request.number }}
    cloudflare-account-id: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}
    cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

The action calls `cf previews deploy <preview-name> --prebuilt`. cf rejects
production output here, and rejects Preview output for production deployment.
Archive production artifacts before creating Preview output in the same folder.
Preview names must be lowercase DNS labels of 1–63 characters. Both credentials
are required; there is no Preview dry-run or authentication-error fallback.
Run the regular production build and `dry-run` for PRs without credentials.

On PR close, invoke `mode: delete-preview` with the same Worker, Preview name,
and credentials. Cleanup does not require Build Output or cf. Use trusted base
workflow code for cleanup, never checkout PR code in `pull_request_target`.
Serialize deployment and cleanup with the same per-PR concurrency group and
`cancel-in-progress: false`. Recheck that a PR is open and its head matches the
build inside that group before deploying, so queued builds cannot recreate a
closed Preview or replace newer code. These policies belong to the caller.

The pinned cf currently has no Preview delete/read command. The action uses
Cloudflare's Preview API for readback and cleanup, with the same account and
Worker as the CLI. It never lists or deletes other Previews. Only error 10025
with HTTP 404 counts as an absent Preview; auth errors fail. Secrets and
trigger synchronization inputs remain production-only. Preview resource
bindings and isolation are defined by the caller's Preview configuration;
KV, D1, and R2 require explicitly separate bindings for isolated data.

See [Workers Previews](https://developers.cloudflare.com/workers/previews/) and
[cf Preview builds](https://developers.cloudflare.com/cf/projects/#deploy-a-preview).

### Legacy version URL or dry-run

```yaml
- name: Build Worker
  working-directory: worker
  run: bun run cf build
- name: Preview Worker
  id: preview
  uses: risu729/wrangler-deploy-action@V2_COMMIT_SHA
  with:
    mode: preview-or-dry-run
    working-directory: worker
    worker: dotfiles-worker
    preview-alias: pr-${{ github.event.pull_request.number }}
    cloudflare-account-id: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}
    cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

Fork PRs without credentials get a dry run. Supplying only one credential is an
error. Authentication errors from an attempted upload are not masked by a
fallback. Production always requires both explicit credentials.

### Production from a validated artifact

Restore and verify the earlier build in the Worker project directory before
this step. The Build Output must be at `.cloudflare/output/v0`.

```yaml
- name: Deploy validated Worker
  id: production
  uses: risu729/wrangler-deploy-action@V2_COMMIT_SHA
  with:
    mode: production
    working-directory: worker
    worker: dotfiles-worker
    build-mode: production
    cloudflare-account-id: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}
    cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

For environment-scoped credentials and deployment approvals, set
`environment: production` on the calling job. Configure concurrency in that
workflow so production deployments cannot race.

Optional Worker secrets are uploaded with the new production version:

```yaml
    secrets-json: >-
      {"API_TOKEN":${{ toJSON(secrets.WORKER_API_TOKEN) }}}
```

Use `toJSON` on each value. The action validates a JSON object of strings,
creates a private temporary file, and removes it on success or failure. It
passes the file to `cf workers versions create --secrets-file`; it does not run
separate secret updates. Secrets omitted from the object are preserved by the
version upload operation. This option is restricted to production mode.

## Inputs and outputs

| Input | Default | Description |
| --- | --- | --- |
| `mode` | Required | `worker-preview`, `delete-preview`, `preview-or-dry-run`, `dry-run`, or `production`. |
| `worker` | Required | Exact Worker name in the prebuilt output. |
| `working-directory` | `.` | Project directory relative to `GITHUB_WORKSPACE`. |
| `build-mode` | `production` | Mode recorded by the build; passed as cf `--mode`. |
| `preview-name` | Empty | Required for Workers Preview deployment and deletion. |
| `preview-alias` | Empty | Required for `preview-or-dry-run`. |
| `cloudflare-account-id` | Empty | Required for authenticated operations. |
| `cloudflare-api-token` | Empty | Required for authenticated operations. |
| `secrets-json` | Empty | String-valued JSON object for production version upload. |
| `deploy-triggers` | `false` | Opt-in trigger synchronization, production only. |

| Output | Description |
| --- | --- |
| `effective-mode` | Requested operation; legacy `preview-or-dry-run` resolves to `preview` or `dry-run`. |
| `version-id` | Uploaded version UUID; empty for dry runs. |
| `deployment-id` | Verified production or Workers Preview deployment ID; otherwise empty. |
| `preview-url` | Stable Workers Preview URL, or version URL in legacy modes. |
| `preview-alias-url` | Stable alias URL for preview mode. |
| `preview-id` | Workers Preview resource ID; empty when cleanup found it already absent. |
| `deployment-url` | Immutable Workers Preview deployment URL. |
| `triggers-deployed` | `true` only after requested trigger synchronization succeeds. |

The same results appear in the GitHub Actions job summary. Outputs are written
only after the requested operation completes successfully.

## Permissions and runner requirements

Use `Individual Workers Editor` restricted to the existing target Worker for
version uploads and deployments. Always supply the account ID as well. The
default deployment preserves an existing Custom Domain without updating it.
Per-Worker tokens cannot manage Custom Domains; an explicit trigger update
needs suitable permissions for its declared resources. Queue, database, or
other resource provisioning can need additional product permissions.

The action supports Linux runners with Bash, jq, curl, and a Node.js version supported
by the caller's pinned cf (currently Node.js 22.18 or later). It does not create
or broaden API tokens.

## Migrating from v1

- Migrate the project and pin cf, then build before invoking the action.
- Replace `config` and `environment` with `worker` and `build-mode`.
- `mode` still selects the action operation; `build-mode` selects cf's mode.
- Replace `deployment-targets` consumers with `version-id` and `deployment-id`.
- Trigger synchronization is now explicit; production no longer updates routes
  or Custom Domains by default.
- Pin a v2 release commit. Existing v1 tags and commit references are unchanged.

See the [v1 documentation](https://github.com/risu729/wrangler-deploy-action/blob/v1.2.0/README.md)
for Wrangler callers and the [cf migration guide](https://developers.cloudflare.com/cf/wrangler/migrate/)
for project conversion.

## Development and releases

```sh
mise install
mise run check --lint
mise run test
```

CI also invokes the composite action with a fake CLI and builds a real fixture
with pinned cf before a credential-free dry run. Real scoped-token preview and
production validation is performed in dotfiles.

Semantic Release runs on main. Conventional Commit breaking-change markers
create major releases. Releases tag the committed composite action and shell
scripts directly; there is no generated action bundle.

## License

[MIT](LICENSE)
