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
	export FAKE_CURL_LOG="${BATS_TEST_TMPDIR}/curl.log"
	export FAKE_CURL_STATE="${BATS_TEST_TMPDIR}/curl.state"
	export FAKE_DEPLOYMENT_STATE="${BATS_TEST_TMPDIR}/deployment.state"
	export FAKE_CLOCK="${BATS_TEST_TMPDIR}/clock"
	printf '0' >"${FAKE_CLOCK}"
	export INPUT_PRODUCTION_STRATEGY=versions
	export INPUT_PREVIEW_NAME=pr-42
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

@test "mise fallback disables automatic installation from the caller config" {
	export MISE_EXEC_AUTO_INSTALL=true

	run run_action dry-run
	[ "${status}" -eq 0 ]
	[[ ${output} == *"Using cf test-version via mise."* ]]
	assert_file_contains "${GITHUB_OUTPUT}" "effective-mode=dry-run"
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

	if [[ ${mode} != delete-preview ]]; then
		"${repo_root}/src/check-cf.sh" || return "$?"
	fi
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
	assert_file_contains "${FAKE_CURL_LOG}" 'GET https://api.cloudflare.com/client/v4/accounts/account/workers/scripts/worker/deployments/22222222-2222-4222-8222-222222222222'
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

@test "Workers Preview deploys prebuilt output and verifies the resource and latest deployment" {
	run run_action worker-preview account token
	[ "${status}" -eq 0 ]
	assert_file_contains "${FAKE_CF_LOG}" 'previews deploy pr-42 --prebuilt --mode production --worker worker'
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers versions'
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers deployments'
	assert_file_contains "${GITHUB_OUTPUT}" 'preview-id=preview-123'
	assert_file_contains "${GITHUB_OUTPUT}" 'deployment-id=deployment-456'
	assert_file_contains "${FAKE_CURL_LOG}" '/workers/workers/worker/previews/preview-123/deployments/latest'
	[ -z "$(find "${RUNNER_TEMP}" -type f -print -quit)" ]
}

@test "Workers Preview requires explicit credentials and a safe name" {
	run run_action worker-preview
	[ "${status}" -ne 0 ]
	for name in '' '../other' 'bad name' 'UPPER' '-leading'; do
		export INPUT_PREVIEW_NAME="${name}"
		run run_action worker-preview account token
		[ "${status}" -ne 0 ]
	done
	assert_file_not_contains "${FAKE_CF_LOG}" 'previews deploy'
}

@test "Workers Preview rejects missing duplicate wrong-name and unsafe URL metadata" {
	for scenario in missing duplicate wrong-name bad-url; do
		export FAKE_CF_OUTPUT="${scenario}"
		run run_action worker-preview account token
		[ "${status}" -ne 0 ]
		[ ! -s "${GITHUB_OUTPUT}" ]
	done
	[ ! -e "${FAKE_CURL_LOG}" ]
}

@test "Workers Preview upload failure cannot fall back to dry run" {
	export FAKE_CF_FAILURE=upload
	run run_action worker-preview account token
	[ "${status}" -ne 0 ]
	[ ! -s "${GITHUB_OUTPUT}" ]
	assert_file_not_contains "${FAKE_CF_LOG}" '--dry-run'
}

@test "Workers Preview mismatched resource or deployment fails verification" {
	for scenario in wrong-name wrong-id wrong-deployment wrong-url; do
		export FAKE_PREVIEW_API="${scenario}"
		run run_action worker-preview account token
		[ "${status}" -ne 0 ]
		[ ! -s "${GITHUB_OUTPUT}" ]
	done
}

@test "cleanup resolves an exact name deletes by ID and verifies absence without cf or a build" {
	rm "${GITHUB_WORKSPACE}/worker/.cloudflare/output/v0/config.json"
	export FAKE_CF_MISSING=1
	run run_action delete-preview account token
	[ "${status}" -eq 0 ]
	[ ! -s "${FAKE_CF_LOG}" ]
	assert_file_contains "${FAKE_CURL_LOG}" 'DELETE https://api.cloudflare.com/client/v4/accounts/account/workers/workers/worker/previews/preview-123'
	assert_file_contains "${GITHUB_OUTPUT}" 'effective-mode=delete-preview'
	assert_file_contains "${GITHUB_STEP_SUMMARY}" 'Verified that the Preview is absent.'
}

@test "cleanup is idempotent only for a missing Preview" {
	export FAKE_PREVIEW_API=missing
	run run_action delete-preview account token
	[ "${status}" -eq 0 ]
	assert_file_not_contains "${FAKE_CURL_LOG}" DELETE
}

@test "cleanup never deletes a mismatched resource" {
	export FAKE_PREVIEW_API=wrong-name
	run run_action delete-preview account token
	[ "${status}" -ne 0 ]
	assert_file_not_contains "${FAKE_CURL_LOG}" DELETE
	[ ! -s "${GITHUB_OUTPUT}" ]
}

@test "authentication network and missing Worker errors fail without exposing the token" {
	for scenario in forbidden network missing-worker malformed; do
		export FAKE_PREVIEW_API="${scenario}"
		run run_action delete-preview account sensitive-example-token
		[ "${status}" -ne 0 ]
		[[ ${output} != *sensitive-example-token* ]]
		[ ! -s "${GITHUB_OUTPUT}" ]
	done
	assert_file_not_contains "${FAKE_CURL_LOG}" DELETE
}

@test "failed deletion and a remaining Preview are not reported as success" {
	for scenario in delete-failure still-present readback-failure; do
		export FAKE_PREVIEW_API="${scenario}"
		rm -f "${FAKE_CURL_STATE}"
		run run_action delete-preview account token
		[ "${status}" -ne 0 ]
		[ ! -s "${GITHUB_OUTPUT}" ]
	done
}

@test "full production deployment verifies the returned version without another activation" {
	export INPUT_PRODUCTION_STRATEGY=deploy INPUT_DEPLOY_TRIGGERS=true
	run run_action production account token
	[ "${status}" -eq 0 ]
	assert_file_contains "${FAKE_CF_LOG}" 'deploy --prebuilt --mode production --worker worker'
	assert_file_contains "${FAKE_CF_LOG}" 'workers deployments list --worker worker'
	assert_file_contains "${FAKE_CF_LOG}" 'workers deployments get 22222222-2222-4222-8222-222222222222 --worker worker'
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers versions create'
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers deployments create'
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers triggers deploy'
	assert_file_contains "${GITHUB_OUTPUT}" 'version-id=11111111-1111-4111-8111-111111111111'
	assert_file_contains "${GITHUB_OUTPUT}" 'triggers-deployed=true'
	assert_file_contains "${GITHUB_STEP_SUMMARY}" 'Container rollout completion requires caller verification.'
}

@test "full deployment requires explicit trigger consent before mutation" {
	export INPUT_PRODUCTION_STRATEGY=deploy
	run run_action production account token
	[ "${status}" -ne 0 ]
	[[ ${output} == *'requires deploy-triggers true'* ]]
	assert_file_not_contains "${FAKE_CF_LOG}" 'deploy --prebuilt'
}

@test "full deployment dry run follows the selected path without trigger consent or credentials" {
	export INPUT_PRODUCTION_STRATEGY=deploy
	run run_action dry-run
	[ "${status}" -eq 0 ]
	assert_file_contains "${FAKE_CF_LOG}" 'deploy --prebuilt --mode production --worker worker --dry-run'
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers versions create'
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers deployments'
	assert_file_contains "${GITHUB_OUTPUT}" 'triggers-deployed=false'
}

@test "production strategy rejects unknown values and nonproduction uploads" {
	for mode in worker-preview delete-preview preview-or-dry-run; do
		export INPUT_PRODUCTION_STRATEGY=deploy
		run run_action "${mode}" account token
		[ "${status}" -ne 0 ]
		[ ! -s "${GITHUB_OUTPUT}" ]
	done
	export INPUT_PRODUCTION_STRATEGY=unknown
	run run_action dry-run
	[ "${status}" -ne 0 ]
	[[ ${output} == *'production-strategy must be versions or deploy'* ]]
}

@test "full deployment refuses untrusted or ambiguous returned version metadata" {
	export INPUT_PRODUCTION_STRATEGY=deploy INPUT_DEPLOY_TRIGGERS=true
	for scenario in missing duplicate wrong-worker bad-id; do
		export FAKE_CF_OUTPUT="${scenario}"
		run run_action production account token
		[ "${status}" -ne 0 ]
		[ ! -s "${GITHUB_OUTPUT}" ]
		assert_file_not_contains "${FAKE_CF_LOG}" 'workers deployments'
	done
}

@test "full deployment rejects a different active version empty list or invalid deployment ID" {
	export INPUT_PRODUCTION_STRATEGY=deploy INPUT_DEPLOY_TRIGGERS=true
	for scenario in wrong-active-version wrong-percentage empty-deployments bad-deployment-id; do
		export FAKE_CF_OUTPUT="${scenario}"
		run run_action production account token
		[ "${status}" -ne 0 ]
		[ ! -s "${GITHUB_OUTPUT}" ]
		[[ ${output} == *'active deployment did not match'* ]]
	done
}

@test "full deployment partial failures never produce success outputs" {
	export INPUT_PRODUCTION_STRATEGY=deploy INPUT_DEPLOY_TRIGGERS=true
	for scenario in upload containers triggers list get; do
		export FAKE_CF_FAILURE="${scenario}"
		run run_action production account token
		[ "${status}" -ne 0 ]
		[ ! -s "${GITHUB_OUTPUT}" ]
	done
}

@test "full deployment still cleans private secrets after a Container failure" {
	export INPUT_PRODUCTION_STRATEGY=deploy INPUT_DEPLOY_TRIGGERS=true
	export INPUT_SECRETS_JSON='{"TOKEN":"test"}' FAKE_CF_FAILURE=containers
	run run_action production account token
	[ "${status}" -ne 0 ]
	[ "$(cat "${FAKE_CF_SECRETS_LOG}.mode")" = 600 ]
	[ -z "$(find "${RUNNER_TEMP}" -type f -print -quit)" ]
	[ ! -s "${GITHUB_OUTPUT}" ]
}

@test "full deployment validates the individual deployment readback after the active list" {
	export INPUT_PRODUCTION_STRATEGY=deploy INPUT_DEPLOY_TRIGGERS=true
	for scenario in wrong-readback-version wrong-readback-percentage; do
		export FAKE_CF_OUTPUT="${scenario}"
		run run_action production account token
		[ "${status}" -ne 0 ]
		[[ ${output} == *'Deployment readback did not match'* ]]
		[ ! -s "${GITHUB_OUTPUT}" ]
	done
}

@test "exact deployment visibility retries reads only then enables opted-in triggers" {
	export FAKE_DEPLOYMENT_API=delayed INPUT_DEPLOY_TRIGGERS=true
	run run_action production account sensitive-example-token
	[ "${status}" -eq 0 ]
	[ "$(cat "${FAKE_DEPLOYMENT_STATE}")" -eq 3 ]
	[ "$(grep -c 'workers versions create ' "${FAKE_CF_LOG}")" -eq 1 ]
	[ "$(grep -c 'workers deployments create ' "${FAKE_CF_LOG}")" -eq 1 ]
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers deployments get'
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers deployments list'
	assert_file_contains "${FAKE_CF_LOG}" 'workers triggers deploy'
	assert_file_contains "${GITHUB_OUTPUT}" 'deployment-id=22222222-2222-4222-8222-222222222222'
	[ "$(cat "${FAKE_DEPLOYMENT_STATE}.timeouts")" = $'30.000\n29.000\n28.000\n28.000' ]
	[[ ${output} != *sensitive-example-token* && ${output} != *sensitive-provider-message* ]]
	[ -z "$(find "${RUNNER_TEMP}" -type f -print -quit)" ]
}

@test "missing exact deployment expires at one 30-second deadline without republication" {
	export FAKE_DEPLOYMENT_API=missing INPUT_DEPLOY_TRIGGERS=true
	run run_action production account token
	[ "${status}" -ne 0 ]
	[[ ${output} == *deployment_readback_pending* ]]
	[ "$(cat "${FAKE_CLOCK}")" -eq 30000 ]
	[ "$(cat "${FAKE_DEPLOYMENT_STATE}")" -eq 30 ]
	[ "$(grep -c 'workers versions create ' "${FAKE_CF_LOG}")" -eq 1 ]
	[ "$(grep -c 'workers deployments create ' "${FAKE_CF_LOG}")" -eq 1 ]
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers triggers'
	[ ! -s "${GITHUB_OUTPUT}" ]
	[ ! -s "${GITHUB_STEP_SUMMARY}" ]
	[ -z "$(find "${RUNNER_TEMP}" -type f -print -quit)" ]
}

@test "near-boundary exact deployment succeeds but late bodies and timeouts cannot" {
	export FAKE_DEPLOYMENT_API=near-boundary
	run run_action production account token
	[ "${status}" -eq 0 ]
	[ "$(cat "${FAKE_CLOCK}")" -eq 29999 ]
	[ "$(tail -1 "${FAKE_DEPLOYMENT_STATE}.timeouts")" = 0.001 ]
	for scenario in late-success request-timeout; do
		export FAKE_DEPLOYMENT_API="${scenario}" INPUT_DEPLOY_TRIGGERS=true
		printf '0' >"${FAKE_CLOCK}"
		: >"${GITHUB_OUTPUT}"
		: >"${FAKE_CF_LOG}"
		run run_action production account token
		[ "${status}" -ne 0 ]
		[[ ${output} == *deployment_readback_pending* ]]
		[ ! -s "${GITHUB_OUTPUT}" ]
		assert_file_not_contains "${FAKE_CF_LOG}" 'workers triggers'
	done
}

@test "only typed40410336 retries and all schema or identity failures stop immediately" {
	for scenario in wrong-missing mixed-errors string-code malformed-missing empty-errors unauthorized forbidden rate-limit server redirect network malformed wrong-id wrong-readback-version wrong-percentage wrong-strategy multiple-versions non-array false-success multiple-json missing-multiple-json; do
		export FAKE_DEPLOYMENT_API="${scenario}" INPUT_DEPLOY_TRIGGERS=true
		rm -f "${FAKE_DEPLOYMENT_STATE}"
		printf '0' >"${FAKE_CLOCK}"
		: >"${GITHUB_OUTPUT}"
		: >"${GITHUB_STEP_SUMMARY}"
		: >"${FAKE_CF_LOG}"
		run run_action production account sensitive-example-token
		[ "${status}" -ne 0 ]
		[ "$(cat "${FAKE_DEPLOYMENT_STATE}")" -eq 1 ]
		[ "$(cat "${FAKE_CLOCK}")" -eq 0 ]
		[ "$(grep -c 'workers deployments create ' "${FAKE_CF_LOG}")" -eq 1 ]
		[ "$(grep -c 'workers versions create ' "${FAKE_CF_LOG}")" -eq 1 ]
		[ ! -s "${GITHUB_OUTPUT}" ]
		[ ! -s "${GITHUB_STEP_SUMMARY}" ]
		assert_file_not_contains "${FAKE_CF_LOG}" 'workers triggers'
		[[ ${output} != *sensitive-example-token* && ${output} != *sensitive-provider-message* ]]
		[ -z "$(find "${RUNNER_TEMP}" -type f -print -quit)" ]
	done
}

@test "unsafe production identifiers or token headers fail before upload" {
	export INPUT_WORKER=worker
	# run_action fixes the Worker; account and token still exercise the actual input boundary.
	for account in '../other' 'bad name'; do
		run run_action production "${account}" token
		[ "${status}" -ne 0 ]
		assert_file_not_contains "${FAKE_CF_LOG}" 'workers versions create'
	done
	run run_action production account $'token\nextra-header'
	[ "${status}" -ne 0 ]
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers versions create'
}

@test "historical resource proof cannot pass after another deployment owns current traffic" {
	for scenario in wrong-id wrong-version wrong-percentage empty malformed collection-multiple-json forbidden missing network late timeout; do
		export FAKE_CURRENT_DEPLOYMENT="${scenario}" INPUT_DEPLOY_TRIGGERS=true
		rm -f "${FAKE_DEPLOYMENT_STATE}"
		printf '0' >"${FAKE_CLOCK}"
		: >"${GITHUB_OUTPUT}"
		: >"${GITHUB_STEP_SUMMARY}"
		: >"${FAKE_CF_LOG}"
		: >"${FAKE_CURL_LOG}"
		run run_action production account sensitive-example-token
		[ "${status}" -ne 0 ]
		[ "$(cat "${FAKE_DEPLOYMENT_STATE}")" -eq 1 ]
		[ "$(wc -l <"${FAKE_CURL_LOG}")" -eq 2 ]
		[ "$(grep -c 'workers deployments create ' "${FAKE_CF_LOG}")" -eq 1 ]
		[ "$(grep -c 'workers versions create ' "${FAKE_CF_LOG}")" -eq 1 ]
		[ ! -s "${GITHUB_OUTPUT}" ]
		[ ! -s "${GITHUB_STEP_SUMMARY}" ]
		assert_file_not_contains "${FAKE_CF_LOG}" 'workers triggers'
		[[ ${output} != *sensitive-example-token* ]]
		[ -z "$(find "${RUNNER_TEMP}" -type f -print -quit)" ]
	done
}

@test "v2 environments without GNU date retain the existing pinned CLI readback" {
	export FAKE_DATE_UNSUPPORTED=true
	run run_action production account token
	[ "${status}" -eq 0 ]
	assert_file_contains "${FAKE_CF_LOG}" 'workers deployments get 22222222-2222-4222-8222-222222222222 --worker worker'
	[ ! -e "${FAKE_CURL_LOG}" ]
	assert_file_contains "${GITHUB_OUTPUT}" 'deployment-id=22222222-2222-4222-8222-222222222222'
}

@test "v2 environments without curl retain the existing pinned CLI readback" {
	local minimal_path="${BATS_TEST_TMPDIR}/without-curl"
	mkdir -p "${minimal_path}"
	for name in env bash dirname jq date cat mktemp rm; do
		ln -s "$(command -v "${name}")" "${minimal_path}/${name}"
	done
	ln -s "${repo_root}/tests/fake-bin/mise" "${minimal_path}/mise"
	ln -s "${repo_root}/tests/fake-bin/cf" "${minimal_path}/cf"
	run env PATH="${minimal_path}" INPUT_MODE=production INPUT_WORKING_DIRECTORY=worker \
		INPUT_WORKER=worker INPUT_CLOUDFLARE_ACCOUNT_ID=account INPUT_CLOUDFLARE_API_TOKEN=token \
		"${repo_root}/src/deploy.sh"
	[ "${status}" -eq 0 ]
	assert_file_contains "${FAKE_CF_LOG}" 'workers deployments get 22222222-2222-4222-8222-222222222222 --worker worker'
	[ ! -e "${FAKE_CURL_LOG}" ]
	assert_file_contains "${GITHUB_OUTPUT}" 'deployment-id=22222222-2222-4222-8222-222222222222'
}

@test "a missing enhanced readback helper fails before publication" {
	local action_copy="${BATS_TEST_TMPDIR}/action"
	mkdir -p "${action_copy}/src"
	cp "${repo_root}/src/deploy.sh" "${repo_root}/src/cf.sh" "${action_copy}/src/"
	run env INPUT_MODE=production INPUT_WORKING_DIRECTORY=worker INPUT_WORKER=worker \
		INPUT_CLOUDFLARE_ACCOUNT_ID=account INPUT_CLOUDFLARE_API_TOKEN=token \
		"${action_copy}/src/deploy.sh"
	[ "${status}" -ne 0 ]
	[[ ${output} == *deployment_readback_helper_unavailable* ]]
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers versions create'
	assert_file_not_contains "${FAKE_CF_LOG}" 'workers deployments create'
	[ ! -s "${GITHUB_OUTPUT}" ]
}

@test "the native composite production invocation works without Bats observation variables" {
	run env -u FAKE_CURL_LOG -u FAKE_CURL_STATE -u FAKE_DEPLOYMENT_STATE -u FAKE_CLOCK \
		-u FAKE_CF_LOG -u FAKE_MISE_LOG -u FAKE_CF_SECRETS_LOG \
		INPUT_MODE=production INPUT_WORKING_DIRECTORY=worker INPUT_WORKER=worker \
		INPUT_BUILD_MODE=production INPUT_CLOUDFLARE_ACCOUNT_ID=account \
		INPUT_CLOUDFLARE_API_TOKEN=token INPUT_PRODUCTION_STRATEGY=versions \
		INPUT_DEPLOY_TRIGGERS=false \
		bash -c '"$1/src/check-cf.sh" && "$1/src/deploy.sh"' -- "${repo_root}"
	[ "${status}" -eq 0 ]
	assert_file_contains "${GITHUB_OUTPUT}" 'effective-mode=production'
	assert_file_contains "${GITHUB_OUTPUT}" 'version-id=11111111-1111-4111-8111-111111111111'
	assert_file_contains "${GITHUB_OUTPUT}" 'deployment-id=22222222-2222-4222-8222-222222222222'
	assert_file_contains "${GITHUB_OUTPUT}" 'triggers-deployed=false'
	[ -z "$(find "${RUNNER_TEMP}" -type f -print -quit)" ]
	[ ! -e "${FAKE_DEPLOYMENT_STATE}" ]
	[ ! -e "${FAKE_CURL_LOG}" ]
}
