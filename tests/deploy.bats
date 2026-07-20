#!/usr/bin/env bats

setup() {
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	readonly repo_root

	export PATH="${repo_root}/tests/fake-bin:${PATH}"
	export GITHUB_WORKSPACE="${BATS_TEST_TMPDIR}/workspace"
	export RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner"
	export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/action.output"
	export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/action.summary"

	mkdir -p "${GITHUB_WORKSPACE}/worker" "${RUNNER_TEMP}"
	touch "${GITHUB_WORKSPACE}/worker/wrangler.jsonc"
	: >"${GITHUB_OUTPUT}"
	: >"${GITHUB_STEP_SUMMARY}"
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

	INPUT_MODE="${mode}" \
		INPUT_WORKING_DIRECTORY=worker \
		INPUT_CONFIG=wrangler.jsonc \
		INPUT_ENVIRONMENT="" \
		INPUT_PREVIEW_ALIAS=pr-42 \
		INPUT_CLOUDFLARE_ACCOUNT_ID="${account_id}" \
		INPUT_CLOUDFLARE_API_TOKEN="${api_token}" \
		"${repo_root}/src/deploy.sh"
}

@test "preview mode falls back to a dry run without credentials" {
	run run_action preview-or-dry-run
	[ "${status}" -eq 0 ]
	assert_file_contains "${GITHUB_OUTPUT}" "effective-mode=dry-run"
	assert_file_contains "${GITHUB_STEP_SUMMARY}" "Cloudflare Workers Deploy Dry Run"
}

@test "preview mode reports Wrangler preview URLs" {
	run run_action preview-or-dry-run account token
	[ "${status}" -eq 0 ]
	assert_file_contains "${GITHUB_OUTPUT}" "effective-mode=preview"
	assert_file_contains "${GITHUB_OUTPUT}" \
		"preview-alias-url=https://pr-42-worker.example.workers.dev"
	assert_file_contains "${GITHUB_STEP_SUMMARY}" 'Preview alias: `pr-42`'
}

@test "production mode reports every deployment target" {
	run run_action production account token
	[ "${status}" -eq 0 ]
	assert_file_contains "${GITHUB_OUTPUT}" "effective-mode=production"
	assert_file_contains "${GITHUB_OUTPUT}" \
		'deployment-targets=["https://one.example.com","https://two.example.com"]'
	assert_file_contains "${GITHUB_STEP_SUMMARY}" "https://two.example.com"
}

@test "production mode requires Cloudflare credentials" {
	run run_action production
	[ "${status}" -ne 0 ]
	[[ ${output} == *"required for production deployment"* ]]
}
