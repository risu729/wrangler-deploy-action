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
	export FAKE_CF_LOG="${BATS_TEST_TMPDIR}/cf.log"
	export FAKE_CF_SECRETS_LOG="${BATS_TEST_TMPDIR}/cf-secrets.json"

	mkdir -p "${GITHUB_WORKSPACE}/worker" "${RUNNER_TEMP}"
	mkdir -p "${GITHUB_WORKSPACE}/worker/.cloudflare/output/v0"
	touch "${GITHUB_WORKSPACE}/worker/.cloudflare/output/v0/config.json"
	: >"${GITHUB_OUTPUT}"
	: >"${GITHUB_STEP_SUMMARY}"
	: >"${FAKE_MISE_LOG}"
	: >"${FAKE_CF_LOG}"
	: >"${FAKE_CF_SECRETS_LOG}"
}

@test "action prefers a package-local cf over mise" {
	mkdir -p "${GITHUB_WORKSPACE}/node_modules/.bin"
	printf '%s\n' '{"devDependencies":{"cf":"1.0.0-beta.12"}}' \
		>"${GITHUB_WORKSPACE}/worker/package.json"
	ln -s "${repo_root}/tests/fake-bin/cf" \
		"${GITHUB_WORKSPACE}/node_modules/.bin/cf"

	run run_action dry-run
	[ "${status}" -eq 0 ]
	[[ ${output} == *"Using cf test-version via project node_modules."* ]]
	[ ! -s "${FAKE_MISE_LOG}" ]
	assert_file_contains "${FAKE_CF_LOG}" \
		"${GITHUB_WORKSPACE}/worker :: workers versions create --prebuilt --mode production --worker worker --dry-run"
}

@test "action ignores an undeclared node_modules cf" {
	mkdir -p "${GITHUB_WORKSPACE}/node_modules/.bin"
	ln -s "${repo_root}/tests/fake-bin/cf" \
		"${GITHUB_WORKSPACE}/node_modules/.bin/cf"

	run run_action dry-run
	[ "${status}" -eq 0 ]
	[[ ${output} == *"Using cf test-version via mise."* ]]
	assert_file_contains "${FAKE_MISE_LOG}" \
		"${GITHUB_WORKSPACE}/worker :: which cf"
}

@test "action runs a declared cf through Yarn Plug'n'Play" {
	printf '%s\n' '{"devDependencies":{"cf":"1.0.0-beta.12"}}' \
		>"${GITHUB_WORKSPACE}/worker/package.json"
	touch "${GITHUB_WORKSPACE}/.pnp.cjs"
	ln -s "${repo_root}/tests/fake-bin/yarn" "${BATS_TEST_TMPDIR}/yarn"
	export PATH="${BATS_TEST_TMPDIR}:${PATH}"

	run run_action dry-run
	[ "${status}" -eq 0 ]
	[[ ${output} == *"Using cf test-version via project Yarn Plug'n'Play."* ]]
	[ ! -s "${FAKE_MISE_LOG}" ]
	assert_file_contains "${FAKE_CF_LOG}" \
		"${GITHUB_WORKSPACE}/worker :: workers versions create --prebuilt --mode production --worker worker --dry-run"
}

@test "action diagnoses a missing jq before resolving cf" {
	local minimal_path="${BATS_TEST_TMPDIR}/minimal-bin"
	mkdir -p "${minimal_path}"
	ln -s /usr/bin/env "${minimal_path}/env"
	ln -s /usr/bin/bash "${minimal_path}/bash"
	ln -s /usr/bin/dirname "${minimal_path}/dirname"

	run env PATH="${minimal_path}" \
		GITHUB_WORKSPACE="${GITHUB_WORKSPACE}" \
		INPUT_WORKING_DIRECTORY=worker \
		"${repo_root}/src/check-cf.sh"
	[ "${status}" -ne 0 ]
	[[ ${output} == *"jq is required"* ]]
}

@test "action rejects an absolute working directory" {
	export INPUT_WORKING_DIRECTORY="${GITHUB_WORKSPACE}/worker"

	run run_action dry-run
	[ "${status}" -ne 0 ]
	[[ ${output} == *"working-directory must be relative to GITHUB_WORKSPACE"* ]]
}

@test "action rejects a working-directory symlink outside the workspace" {
	local outside_directory="${BATS_TEST_TMPDIR}/outside"
	mkdir -p "${outside_directory}"
	ln -s "${outside_directory}" "${GITHUB_WORKSPACE}/outside"
	export INPUT_WORKING_DIRECTORY=outside

	run run_action dry-run
	[ "${status}" -ne 0 ]
	[[ ${output} == *"working-directory must stay within GITHUB_WORKSPACE"* ]]
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

assert_file_not_contains() {
	local path="$1"
	local unexpected="$2"

	if grep -Fq -- "${unexpected}" "${path}"; then
		echo "Expected ${path} not to contain: ${unexpected}" >&2
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
	export INPUT_WORKING_DIRECTORY="${INPUT_WORKING_DIRECTORY:-worker}"
	export INPUT_WORKER=worker
	export INPUT_BUILD_MODE="${INPUT_BUILD_MODE:-production}"
	export INPUT_PREVIEW_ALIAS=pr-42
	export INPUT_CLOUDFLARE_ACCOUNT_ID="${account_id}"
	export INPUT_CLOUDFLARE_API_TOKEN="${api_token}"
	export INPUT_SECRETS_JSON="${INPUT_SECRETS_JSON:-}"

	"${repo_root}/src/check-cf.sh" || return "$?"
	"${repo_root}/src/deploy.sh"
}

@test "preview mode falls back to a dry run without credentials" {
	run run_action preview-or-dry-run
	[ "${status}" -eq 0 ]
	assert_file_contains "${GITHUB_OUTPUT}" "effective-mode=dry-run"
	assert_file_contains "${GITHUB_STEP_SUMMARY}" "Cloudflare Workers: dry-run"
	assert_file_contains "${FAKE_MISE_LOG}" \
		"${GITHUB_WORKSPACE}/worker :: which cf"
	[[ ${output} == *"Using cf test-version"* ]]
}

@test "action rejects a missing cf before deployment" {
	export FAKE_CF_MISSING=1
	run run_action dry-run
	[ "${status}" -ne 0 ]
	[[ ${output} == *"cf is required"* ]]
	! grep -Fq -- "cf deploy" "${FAKE_MISE_LOG}"
}

@test "preview mode reports cf preview URLs" {
	run run_action preview-or-dry-run account token
	[ "${status}" -eq 0 ]
	assert_file_contains "${GITHUB_OUTPUT}" "effective-mode=preview"
	assert_file_contains "${GITHUB_OUTPUT}" \
		"preview-alias-url=https://pr-42-worker.example.workers.dev"
	assert_file_contains "${GITHUB_STEP_SUMMARY}" 'Alias preview: <https://pr-42-worker.example.workers.dev>'
}

@test "production publishes the uploaded version at 100 percent and reads it back" {
	run run_action production account token
	[ "${status}" -eq 0 ]
	assert_file_contains "${GITHUB_OUTPUT}" 'version-id=11111111-1111-4111-8111-111111111111'
	assert_file_contains "${GITHUB_OUTPUT}" 'deployment-id=22222222-2222-4222-8222-222222222222'
	assert_file_contains "${FAKE_CF_LOG}" 'workers deployments create --worker worker --strategy percentage --versions [{"version_id":"11111111-1111-4111-8111-111111111111","percentage":100}]'
	assert_file_contains "${FAKE_CF_LOG}" 'workers deployments get 22222222-2222-4222-8222-222222222222 --worker worker'
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers triggers'
	assert_file_contains "${GITHUB_STEP_SUMMARY}" 'verified at 100%'
}

@test "trigger synchronization requires explicit production opt-in" {
	export INPUT_DEPLOY_TRIGGERS=true
	run run_action production account token
	[ "${status}" -eq 0 ]
	assert_file_contains "${FAKE_CF_LOG}" 'workers triggers deploy --prebuilt --mode production --worker worker'
	assert_file_contains "${GITHUB_OUTPUT}" 'triggers-deployed=true'
}

@test "trigger synchronization cannot be requested for previews" {
	export INPUT_DEPLOY_TRIGGERS=true
	run run_action preview-or-dry-run account token
	[ "${status}" -ne 0 ]
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers versions create'
}

@test "invalid trigger boolean is rejected" {
	export INPUT_DEPLOY_TRIGGERS=yes
	run run_action production account token
	[ "${status}" -ne 0 ]
	[[ ${output} == *'deploy-triggers must be true or false'* ]]
}

@test "preview uploads never deploy traffic or triggers" {
	run run_action preview-or-dry-run account token
	[ "${status}" -eq 0 ]
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers deployments'
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers triggers'
	assert_file_contains "${FAKE_CF_LOG}" '--preview-alias pr-42'
}

@test "build mode is forwarded without rebuilding" {
	export INPUT_BUILD_MODE=staging
	run run_action dry-run
	[ "${status}" -eq 0 ]
	assert_file_contains "${FAKE_CF_LOG}" '--prebuilt --mode staging --worker worker --dry-run'
}

@test "missing prebuilt output fails before upload" {
	rm "${GITHUB_WORKSPACE}/worker/.cloudflare/output/v0/config.json"
	run run_action production account token
	[ "${status}" -ne 0 ]
	[[ ${output} == *'Cloudflare Build Output is missing'* ]]
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers versions create'
}

@test "production requires both explicit credentials" {
	run run_action production
	[ "${status}" -ne 0 ]
	[[ ${output} == *'required for production deployment'* ]]
}

@test "partial preview credentials fail instead of falling back" {
	run run_action preview-or-dry-run account
	[ "${status}" -ne 0 ]
	[[ ${output} == *'must be supplied together'* ]]
}

@test "secrets are private temporary files and preserve special characters" {
	local expected=$'quote" backslash\\ newline\nend'
	export INPUT_SECRETS_JSON
	INPUT_SECRETS_JSON="$(jq -nc --arg token "${expected}" '{TOKEN:$token}')"
	run run_action production account token
	[ "${status}" -eq 0 ]
	[ "$(jq -r '.TOKEN' "${FAKE_CF_SECRETS_LOG}")" = "${expected}" ]
	[ "$(cat "${FAKE_CF_SECRETS_LOG}.mode")" = 600 ]
	local secrets_file
	secrets_file="$(sed -n 's/.* --secrets-file \([^ ]*\).*/\1/p' "${FAKE_CF_LOG}")"
	[ ! -e "${secrets_file}" ]
	[[ ${output} != *"${expected}"* ]]
}

@test "failed uploads clean up secrets and never deploy" {
	export INPUT_SECRETS_JSON='{"TOKEN":"test"}' FAKE_CF_FAILURE=upload
	run run_action production account token
	[ "${status}" -ne 0 ]
	[ -z "$(find "${RUNNER_TEMP}" -type f -print -quit)" ]
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers deployments'
}

@test "production without secrets omits the secrets file" {
	run run_action production account token
	[ "${status}" -eq 0 ]
	assert_file_not_contains "${FAKE_CF_LOG}" '--secrets-file'
}

@test "secrets cannot be sent with previews or dry runs" {
	export INPUT_SECRETS_JSON='{"TOKEN":"test"}'
	run run_action dry-run
	[ "${status}" -ne 0 ]
	[[ ${output} == *'secrets-json is only supported in production mode'* ]]
}

@test "malformed or non-string secrets fail without printing values" {
	for value in '{"TOKEN":"sensitive-example"' '{"TOKEN":1}' '[]'; do
		export INPUT_SECRETS_JSON="${value}"
		run run_action production account token
		[ "${status}" -ne 0 ]
		[[ ${output} == *'secrets-json must be a JSON object with string values'* ]]
		[[ ${output} != *sensitive-example* ]]
	done
}

@test "missing duplicate wrong-Worker or invalid version output cannot deploy" {
	for scenario in missing duplicate wrong-worker bad-id; do
		export FAKE_CF_OUTPUT="${scenario}"
		run run_action production account token
		[ "${status}" -ne 0 ]
		assert_file_not_contains "${FAKE_CF_LOG}" 'workers deployments'
	done
}

@test "preview requires both URLs" {
	export FAKE_CF_OUTPUT=missing-url
	run run_action preview-or-dry-run account token
	[ "${status}" -ne 0 ]
	[[ ${output} == *'did not include both preview URLs'* ]]
}

@test "deployment failure prevents triggers and success outputs" {
	export FAKE_CF_FAILURE=deploy INPUT_DEPLOY_TRIGGERS=true
	run run_action production account token
	[ "${status}" -ne 0 ]
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers triggers'
	[ ! -s "${GITHUB_OUTPUT}" ]
}

@test "readback mismatch fails the action" {
	export FAKE_CF_OUTPUT=wrong-percentage
	run run_action production account token
	[ "${status}" -ne 0 ]
	[[ ${output} == *'Deployment readback did not match'* ]]
	[ ! -s "${GITHUB_OUTPUT}" ]
}

@test "readback and trigger API failures are not reported as success" {
	for scenario in get triggers; do
		export FAKE_CF_FAILURE="${scenario}" INPUT_DEPLOY_TRIGGERS=true
		run run_action production account token
		[ "${status}" -ne 0 ]
		[ ! -s "${GITHUB_OUTPUT}" ]
	done
}
