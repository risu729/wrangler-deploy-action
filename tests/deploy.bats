#!/usr/bin/env bats

setup() {
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	readonly repo_root

	export PATH="${repo_root}/tests/fake-bin:${PATH}"
	export GITHUB_WORKSPACE="${BATS_TEST_TMPDIR}/workspace"
	export RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/action.output"
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/action.summary"
	export FAKE_MISE_LOG="${BATS_TEST_TMPDIR}/mise.log"

	mkdir -p "${GITHUB_WORKSPACE}/worker" "${RUNNER_TEMP}"
	touch "${GITHUB_WORKSPACE}/worker/wrangler.jsonc"
	: >"${GITHUB_OUTPUT}"
	: >"${GITHUB_STEP_SUMMARY}"
	: >"${FAKE_MISE_LOG}"
}

assert_file_contains() {
	local path="$1"
	local expected="$2"

	if ! grep -Fq -- "${expected}" "${path}"; then
		echo "Expected ${path} to contain: ${expected}" >&2
		echo "Actual contents:" >&2
		sed -n '1,240p' "${path}" >&2
		return 1
	fi
}

run_action() {
	local mode="$1"
	local account_id="${2:-}"
	local api_token="${3:-}"

	export INPUT_MODE="${mode}"
	export INPUT_WORKING_DIRECTORY=worker
	export INPUT_CONFIG=wrangler.jsonc
	export INPUT_ENVIRONMENT=""
	export INPUT_PREVIEW_ALIAS=pr-42
	export INPUT_CLOUDFLARE_ACCOUNT_ID="${account_id}"
	export INPUT_CLOUDFLARE_API_TOKEN="${api_token}"

	"${repo_root}/src/check-wrangler.sh" || return "$?"
	"${repo_root}/src/deploy.sh"
}

@test "preview mode falls back to a dry run without credentials" {
	run run_action preview-or-dry-run
	[ "${status}" -eq 0 ]
	assert_file_contains "${GITHUB_OUTPUT}" "effective-mode=dry-run"
	assert_file_contains "${GITHUB_STEP_SUMMARY}" "Cloudflare Workers Deploy Dry Run"
	assert_file_contains "${FAKE_MISE_LOG}" \
		"${GITHUB_WORKSPACE}/worker :: which wrangler"
}

@test "action rejects a missing Wrangler before deployment" {
	export FAKE_WRANGLER_MISSING=1
	run run_action dry-run
	[ "${status}" -ne 0 ]
	[[ ${output} == *"Wrangler is required"* ]]
	! grep -Fq -- "wrangler deploy" "${FAKE_MISE_LOG}"
}

@test "action rejects an unsupported Wrangler version before deployment" {
	export FAKE_WRANGLER_VERSION=4.20.0
	run run_action dry-run
	[ "${status}" -ne 0 ]
	[[ ${output} == *"Wrangler 4.21.0 or newer is required; found 4.20.0"* ]]
	! grep -Fq -- "wrangler deploy" "${FAKE_MISE_LOG}"
}

@test "preview mode reports Wrangler preview URLs" {
	run run_action preview-or-dry-run account token
	[ "${status}" -eq 0 ]
	assert_file_contains "${GITHUB_OUTPUT}" "effective-mode=preview"
	assert_file_contains "${GITHUB_OUTPUT}" \
		"preview-alias-url=https://pr-42-worker.example.workers.dev"
	assert_file_contains "${GITHUB_STEP_SUMMARY}" 'Preview alias: `pr-42`'
}

@test "production mode reports Wrangler deployment targets" {
	run run_action production account token
	[ "${status}" -eq 0 ]
	assert_file_contains "${GITHUB_OUTPUT}" "effective-mode=production"
	assert_file_contains "${GITHUB_OUTPUT}" \
		'deployment-targets=["https://one.example.com","example.com/*","schedule: 0 0 * * *"]'
	assert_file_contains "${GITHUB_STEP_SUMMARY}" '<https://one.example.com>'
	assert_file_contains "${GITHUB_STEP_SUMMARY}" '`example.com/*`'
}

@test "production mode accepts a deployment without targets" {
	export FAKE_WRANGLER_OUTPUT=empty-targets
	run run_action production account token
	[ "${status}" -eq 0 ]
	assert_file_contains "${GITHUB_OUTPUT}" 'deployment-targets=[]'
	assert_file_contains "${GITHUB_STEP_SUMMARY}" "no deployment targets"
}

@test "production mode rejects output without a deploy entry" {
	export FAKE_WRANGLER_OUTPUT=missing-deploy-entry
	run run_action production account token
	[ "${status}" -ne 0 ]
	[[ ${output} == *"did not include a deploy entry"* ]]
}

@test "production mode requires Cloudflare credentials" {
	run run_action production
	[ "${status}" -ne 0 ]
	[[ ${output} == *"required for production deployment"* ]]
}

@test "preview mode identifies a missing Wrangler output file" {
	export FAKE_WRANGLER_OUTPUT=missing
	run run_action preview-or-dry-run account token
	[ "${status}" -ne 0 ]
	[[ ${output} == *"did not write preview output to"* ]]
}
