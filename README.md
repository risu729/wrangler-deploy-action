# Wrangler Deploy Action

Deploy Cloudflare Workers from GitHub Actions with a consistent preview,
dry-run, and production workflow.

This action uses the Wrangler version already declared and installed as a
caller package dependency or configured through [`mise`](https://mise.jdx.dev/).
It does not install another Wrangler version or modify the caller's package
files.

## Features

- Uploads stable pull-request previews with `wrangler versions upload`.
- Falls back to a credential-free `wrangler deploy --dry-run` for forks and
  repositories without preview credentials.
- Fails production deployments when Cloudflare credentials are missing.
- Reads Wrangler's structured output instead of parsing terminal output.
- Writes preview URLs, deployment targets reported by Wrangler, or dry-run
  status to the GitHub Actions job summary.
- Exposes the same information as action outputs.

## Usage

Install the repository's dependencies or mise tools and build the Worker before
invoking the action. Every action reference uses a full commit SHA.

### Pull-request preview or dry-run

```yaml
name: Worker Deploy Check
on:
  pull_request:
    branches:
      - main
permissions: {}
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  worker-deploy-check:
    name: Worker Deploy Check
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    permissions:
      contents: read
    steps:
      - name: Checkout
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          persist-credentials: false
      - name: Install mise
        uses: jdx/mise-action@dad1bfd3df957f44999b559dd69dc1671cb4e9ea # v4.2.1
        with:
          version: 2026.7.7
      - name: Build Worker
        run: mise run worker:build
      - name: Upload preview or validate deployment
        id: worker
        uses: risu729/wrangler-deploy-action@16a6985780586b6143b924f88973fb26848caf83
        with:
          mode: preview-or-dry-run
          working-directory: worker
          config: wrangler.jsonc
          preview-alias: pr-${{ github.event.pull_request.number }}
          cloudflare-account-id: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}
          cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

Keep the preview account ID in a repository variable and the API token in a
repository secret. Both are unavailable to `pull_request` workflows from forks,
so `preview-or-dry-run` performs a dry-run. Supplying only one credential is a
configuration error.

Authenticated previews require Wrangler 4.21.0 or newer with Preview URLs
enabled. Enable `preview_urls` when `workers_dev` is disabled. Cloudflare does
not currently generate Preview URLs for Workers that implement Durable Objects
or Workers for Platforms user Workers; use `dry-run` mode for those Workers.

### Production deployment

```yaml
name: Deploy Worker
on:
  push:
    branches:
      - main
  workflow_dispatch:
permissions: {}
concurrency:
  group: worker-production
  cancel-in-progress: false
jobs:
  deploy:
    name: Deploy
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    environment: production
    permissions:
      contents: read
    steps:
      - name: Checkout
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          persist-credentials: false
      - name: Install mise
        uses: jdx/mise-action@dad1bfd3df957f44999b559dd69dc1671cb4e9ea # v4.2.1
        with:
          version: 2026.7.7
      - name: Build Worker
        run: mise run worker:build
      - name: Deploy Worker
        uses: risu729/wrangler-deploy-action@16a6985780586b6143b924f88973fb26848caf83
        with:
          mode: production
          working-directory: worker
          config: wrangler.jsonc
          cloudflare-account-id: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}
          cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

Use `environment: production` on the calling job so deployment protection rules
and environment-scoped credentials remain under the caller's control.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `mode` | Yes | — | `preview-or-dry-run`, `dry-run`, or `production`. |
| `working-directory` | No | `.` | Wrangler working directory. |
| `config` | No | `wrangler.toml` | Wrangler configuration path. |
| `environment` | No | — | Wrangler environment passed with `--env`. |
| `preview-alias` | `preview-or-dry-run` mode | — | Stable preview alias. |
| `cloudflare-account-id` | Authenticated modes | — | Account ID. |
| `cloudflare-api-token` | Authenticated modes | — | API token. |

## Outputs

| Output | Description |
| --- | --- |
| `effective-mode` | `preview`, `dry-run`, or `production`. |
| `preview-url` | Version-specific Workers preview URL. |
| `preview-alias-url` | Stable Workers preview alias URL. |
| `deployment-targets` | JSON array of production targets reported by Wrangler. |

## Cloudflare token permissions

For version uploads and deployments, start with a token restricted to the
target account with:

- Account / Workers Scripts / Edit

Account / Account Settings / Read is part of Cloudflare's broader
[Edit Cloudflare Workers token template](https://developers.cloudflare.com/fundamentals/api/reference/template/),
but it is not an additional minimum permission for this action's Wrangler
commands: the [Worker Account Settings endpoint](https://developers.cloudflare.com/api/resources/workers/subresources/account_settings/methods/get/)
also accepts Workers Scripts / Edit.

User / User Details / Read is also unnecessary. Wrangler may suggest it while
printing diagnostic account information after another API request fails, but
the deployment operations do not require it.

For production deployment of every zone referenced by a Custom Domain, also
grant:

- Zone / Workers Routes / Read

Wrangler currently
[lists the zone's Worker routes](https://developers.cloudflare.com/api/resources/workers/subresources/routes/methods/list/)
before publishing any configured route, including a route with
`custom_domain = true`, so it can detect assignments to another Worker. This
read-only preflight is why the zone permission is needed even though the
[Attach Domain endpoint](https://developers.cloudflare.com/api/resources/workers/subresources/domains/methods/update/)
itself accepts Workers Scripts / Edit.

If the Wrangler configuration declares an ordinary route, grant Zone / Workers
Routes / Edit instead; Edit also satisfies the preflight read. Wrangler
synchronizes ordinary routes during deployment, including routes that already
exist. Ordinary routes require
[proxied DNS records configured separately](https://developers.cloudflare.com/workers/configuration/routing/routes/);
add Zone / DNS / Edit only if the workflow separately creates or changes those
records.

For a Custom Domain, Cloudflare creates the DNS record and certificate on the
Worker's behalf. The token therefore does not need Zone / DNS / Edit.

Add KV, R2, D1, or other product scopes only when the Worker deployment actively
manages those resources.

For pull-request previews, store `CLOUDFLARE_ACCOUNT_ID` as a repository variable
and `CLOUDFLARE_API_TOKEN` as a repository secret. For production, store the token
as an environment-scoped secret; the account ID may be an environment or
repository variable.

## Runner requirements

The action currently supports Linux runners with Bash and `jq`; both are
available on GitHub-hosted Ubuntu runners. The caller must check out the Worker
source and make Wrangler 4.21.0 or newer available either as a package
dependency or a mise tool. Package dependencies require a Wrangler-supported
Node.js version. A declared package-local Wrangler takes precedence, including
an installation hoisted between the working directory and workspace root or a
Yarn Plug'n'Play installation. Undeclared transitive installations are ignored.

## Releases

Semantic Release runs after each push to `main`. Conventional Commit subjects
determine the next version, and release-worthy changes create a
`vMAJOR.MINOR.PATCH` tag and GitHub release.

This composite action has no generated `dist/` artifact. Each release tags the
committed `action.yml` and shell implementation directly.

## Development

```sh
mise install
mise run check --lint
mise run test
```

Run `mise run check` to apply safe formatting fixes before committing.

## License

[MIT](LICENSE)
