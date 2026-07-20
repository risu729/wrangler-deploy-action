# Wrangler Deploy Action

Deploy Cloudflare Workers from GitHub Actions with a consistent preview,
dry-run, and production workflow.

This action uses the Wrangler version already installed by
[`mise`](https://mise.jdx.dev/). It does not install another Wrangler version or
modify the caller's package files.

## Features

- Uploads stable pull-request previews with `wrangler versions upload`.
- Falls back to a credential-free `wrangler deploy --dry-run` for forks and
  repositories without preview credentials.
- Fails production deployments when Cloudflare credentials are missing.
- Reads Wrangler's structured output instead of parsing terminal output.
- Writes preview URLs, every production target, or dry-run status to the GitHub
  Actions job summary.
- Exposes the same information as action outputs.

## Usage

Install the repository's tools and build the Worker before invoking the action.
The examples use immutable release tags for readability. Pin actions to a full
commit SHA in security-sensitive workflows.

### Pull-request preview or dry-run

```yaml
jobs:
  worker-deploy-check:
    name: Worker Deploy Check
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - name: Checkout
        uses: actions/checkout@v7
        with:
          persist-credentials: false
      - name: Install mise
        uses: jdx/mise-action@v4
        with:
          install_args: --locked
      - name: Build Worker
        run: mise run worker:build
      - name: Upload preview or validate deployment
        id: worker
        uses: risu729/wrangler-deploy-action@v1.0.0
        with:
          mode: preview-or-dry-run
          working-directory: worker
          config: wrangler.jsonc
          preview-alias: pr-${{ github.event.pull_request.number }}
          cloudflare-account-id: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}
          cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

Secrets are unavailable to workflows from forks. When both credential inputs
are empty, `preview-or-dry-run` automatically performs the dry-run. Supplying
only one credential is treated as a configuration error.

To make validation merge-blocking, include this job in the repository's stable
required-check guard:

```yaml
  ci-check:
    name: CI Check
    needs:
      - lint
      - test
      - worker-deploy-check
    if: >-
      ${{ !cancelled() &&
      (contains(needs.*.result, 'failure') ||
      contains(needs.*.result, 'cancelled')) }}
    runs-on: ubuntu-24.04
    steps:
      - run: exit 1
```

### Production deployment

```yaml
jobs:
  deploy:
    name: Deploy
    runs-on: ubuntu-24.04
    environment: production
    permissions:
      contents: read
    steps:
      - name: Checkout
        uses: actions/checkout@v7
        with:
          persist-credentials: false
      - name: Install mise
        uses: jdx/mise-action@v4
        with:
          install_args: --locked
      - name: Build Worker
        run: mise run worker:build
      - name: Deploy Worker
        uses: risu729/wrangler-deploy-action@v1.0.0
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
| `preview-alias` | Preview mode | — | Stable preview alias. |
| `cloudflare-account-id` | Authenticated modes | — | Account ID. |
| `cloudflare-api-token` | Authenticated modes | — | API token. |

## Outputs

| Output | Description |
| --- | --- |
| `effective-mode` | `preview`, `dry-run`, or `production`. |
| `preview-url` | Version-specific Workers preview URL. |
| `preview-alias-url` | Stable Workers preview alias URL. |
| `deployment-targets` | JSON array of production targets. |

## Cloudflare token permissions

For an existing Worker and existing routes, use a token restricted to the
target account with:

- Account / Workers Scripts / Edit
- Account / Account Settings / Read

The action does not edit DNS records, so Zone / DNS / Edit is not required.
Zone / Workers Routes / Edit is only needed when a deployment must create or
change Worker routes or custom domains. Add KV, R2, D1, or other product scopes
only when the Worker deployment actively manages those resources.

Store the token as an environment-scoped `CLOUDFLARE_API_TOKEN` secret and the
account ID as `CLOUDFLARE_ACCOUNT_ID`. Do not grant Zone / DNS / Edit merely for
routine uploads to already configured routes.

## Runner requirements

The action currently supports Linux runners with Bash and `jq`; both are
available on GitHub-hosted Ubuntu runners. The caller must install `mise`,
configure Wrangler as a mise tool, and check out the Worker source before
calling the action.

## Development

```sh
mise install
mise run check --lint
mise run test
```

Run `mise run check` to apply safe formatting fixes before committing.

## License

[MIT](LICENSE)
