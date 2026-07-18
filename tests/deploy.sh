#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
test_root="$(mktemp -d "${TMPDIR:-/tmp}/wrangler-deploy-action-test.XXXXXX")"
readonly test_root
trap 'rm -rf -- "${test_root}"' EXIT

export PATH="${repo_root}/tests/fake-bin:${PATH}"
export GITHUB_WORKSPACE="${test_root}/workspace"
export RUNNER_TEMP="${test_root}/runner"
mkdir -p "${GITHUB_WORKSPACE}/worker" "${RUNNER_TEMP}"
touch "${GITHUB_WORKSPACE}/worker/wrangler.jsonc"

assert_contains() {
	local path="$1"
	local expected="$2"

	if ! grep -Fq -- "${expected}" "${path}"; then
		echo "Expected ${path} to contain: ${expected}" >&2
		echo "Actual contents:" >&2
		sed -n '1,240p' "${path}" >&2
		exit 1
	fi
}

run_action() {
	local name="$1"
	local mode="$2"
	local account_id="${3:-}"
	local api_token="${4:-}"

	export GITHUB_OUTPUT="${test_root}/${name}.output"
	export GITHUB_STEP_SUMMARY="${test_root}/${name}.summary"
	: >"${GITHUB_OUTPUT}"
	: >"${GITHUB_STEP_SUMMARY}"
	INPUT_MODE="${mode}" \
		INPUT_WORKING_DIRECTORY=worker \
		INPUT_CONFIG=wrangler.jsonc \
		INPUT_ENVIRONMENT="" \
		INPUT_PREVIEW_ALIAS=pr-42 \
		INPUT_CLOUDFLARE_ACCOUNT_ID="${account_id}" \
		INPUT_CLOUDFLARE_API_TOKEN="${api_token}" \
		"${repo_root}/src/deploy.sh"
}

run_action dry-run preview-or-dry-run
assert_contains "${test_root}/dry-run.output" "effective-mode=dry-run"
assert_contains "${test_root}/dry-run.summary" "Cloudflare Workers Deploy Dry Run"

run_action preview preview-or-dry-run account token
assert_contains "${test_root}/preview.output" "effective-mode=preview"
assert_contains "${test_root}/preview.output" \
	"preview-alias-url=https://pr-42-worker.example.workers.dev"
# shellcheck disable=SC2016 # backticks are literal Markdown
expected_preview_alias="$(printf 'Preview alias: `%s`' pr-42)"
assert_contains "${test_root}/preview.summary" "${expected_preview_alias}"

run_action production production account token
assert_contains "${test_root}/production.output" "effective-mode=production"
assert_contains "${test_root}/production.output" \
	'deployment-targets=["https://one.example.com","https://two.example.com"]'
assert_contains "${test_root}/production.summary" "https://two.example.com"

if INPUT_MODE=production \
	INPUT_WORKING_DIRECTORY=worker \
	INPUT_CONFIG=wrangler.jsonc \
	INPUT_ENVIRONMENT="" \
	INPUT_PREVIEW_ALIAS="" \
	INPUT_CLOUDFLARE_ACCOUNT_ID="" \
	INPUT_CLOUDFLARE_API_TOKEN="" \
	"${repo_root}/src/deploy.sh" 2>"${test_root}/missing-credentials.stderr"; then
	echo "Production unexpectedly succeeded without credentials." >&2
	exit 1
fi
assert_contains "${test_root}/missing-credentials.stderr" \
	"required for production deployment"

echo "All deploy action tests passed."
