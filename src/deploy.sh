#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_directory
# shellcheck source=src/cf.sh
source "${script_directory}/cf.sh"

readonly mode="${INPUT_MODE:?mode is required}"
readonly worker="${INPUT_WORKER:?worker is required}"
readonly build_mode="${INPUT_BUILD_MODE:-production}"
readonly preview_alias="${INPUT_PREVIEW_ALIAS:-}"
readonly account_id="${INPUT_CLOUDFLARE_ACCOUNT_ID:-}"
readonly api_token="${INPUT_CLOUDFLARE_API_TOKEN:-}"
readonly secrets_json="${INPUT_SECRETS_JSON:-}"
readonly production_strategy="${INPUT_PRODUCTION_STRATEGY:-versions}"
readonly deploy_triggers="${INPUT_DEPLOY_TRIGGERS:-false}"
readonly workspace="${GITHUB_WORKSPACE:-${PWD}}"
readonly temporary_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

fail() {
	echo "$*" >&2
	exit 1
}

case "${mode}" in
preview-or-dry-run | dry-run | production | worker-preview | delete-preview) ;;
*) fail "Unsupported mode: ${mode}" ;;
esac
case "${production_strategy}" in
versions | deploy) ;;
*) fail 'production-strategy must be versions or deploy.' ;;
esac
if [[ ${production_strategy} == deploy ]]; then
	[[ ${mode} == production || ${mode} == dry-run ]] || fail 'production-strategy deploy is only supported in production or dry-run mode.'
	if [[ ${mode} == production && ${deploy_triggers} != true ]]; then
		fail 'production-strategy deploy requires deploy-triggers true because cf deploy synchronizes triggers.'
	fi
fi
case "${deploy_triggers}" in
true | false) ;;
*) fail 'deploy-triggers must be true or false.' ;;
esac
if [[ ${deploy_triggers} == true && ${mode} != production ]]; then
	fail 'deploy-triggers is only supported in production mode.'
fi
if [[ -n ${account_id} && -z ${api_token} ]] || [[ -z ${account_id} && -n ${api_token} ]]; then
	fail 'Cloudflare account ID and API token must be supplied together.'
fi
if [[ ${mode} == production && -z ${account_id} ]]; then
	fail 'Cloudflare account ID and API token are required for production deployment.'
fi
if [[ ${mode} == preview-or-dry-run && -z ${preview_alias} ]]; then
	fail 'preview-alias is required in preview-or-dry-run mode.'
fi
if [[ -n ${secrets_json} && ${mode} != production ]]; then
	fail 'secrets-json is only supported in production mode.'
fi
command -v jq >/dev/null 2>&1 || fail 'jq is required; use a GitHub-hosted Linux runner or install it first.'
deployment_readback_available=false
if [[ ${mode} == production && ${production_strategy} == versions ]]; then
	[[ ${account_id} =~ ^[a-zA-Z0-9_-]+$ && ${worker} =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'Invalid account ID or Worker name.'
	[[ ${api_token} != *$'\n'* && ${api_token} != *$'\r'* ]] || fail 'Invalid API token.'
	if command -v curl >/dev/null 2>&1 && [[ $(date +%s%3N 2>/dev/null) =~ ^[0-9]+$ ]]; then
		deployment_readback_available=true
		# Load trusted readback code before any version upload or activation.
		# shellcheck source=src/deployment-readback.sh
		source "${script_directory}/deployment-readback.sh" 2>/dev/null || fail 'deployment_readback_helper_unavailable'
	fi
fi

resolved_working_directory="$(resolve_working_directory "${INPUT_WORKING_DIRECTORY:-.}" "${workspace}")"
readonly resolved_working_directory
cd "${resolved_working_directory}"
if [[ ${mode} == worker-preview || ${mode} == delete-preview ]]; then
	# Preview resources have a separate deployment and cleanup lifecycle.
	# shellcheck source=src/previews.sh
	source "${script_directory}/previews.sh"
	exit 0
fi
[[ -f .cloudflare/output/v0/config.json ]] || fail 'Cloudflare Build Output is missing; run cf build before invoking this action.'
resolve_cf "${resolved_working_directory}" "${workspace}"

# Restrict secret files from creation and remove them on both success and failure.
umask 077
output_directory="$(mktemp -d "${temporary_root%/}/cf-deploy-action.XXXXXX")"
readonly output_directory
trap 'rm -rf -- "${output_directory}"' EXIT
# cf beta currently retains the deployment backend's structured output contract.
export WRANGLER_OUTPUT_FILE_PATH="${output_directory}/upload.jsonl"
export CLOUDFLARE_ACCOUNT_ID="${account_id}"
export CLOUDFLARE_API_TOKEN="${api_token}"
export CI=true

arguments=(--prebuilt --mode "${build_mode}" --worker "${worker}")
effective_mode="${mode}"
if [[ ${mode} == preview-or-dry-run ]]; then
	if [[ -n ${account_id} ]]; then
		effective_mode=preview
		arguments+=(--preview-alias "${preview_alias}")
	else
		effective_mode=dry-run
	fi
fi
if [[ ${effective_mode} == dry-run ]]; then
	arguments+=(--dry-run)
fi
if [[ -n ${secrets_json} ]]; then
	secrets_file="${output_directory}/secrets.json"
	if ! printf '%s' "${secrets_json}" | jq --compact-output --exit-status \
		'if type == "object" and all(.[]; type == "string") then . else error("invalid secrets") end' \
		>"${secrets_file}" 2>/dev/null; then
		fail 'secrets-json must be a JSON object with string values.'
	fi
	arguments+=(--secrets-file "${secrets_file}")
fi

upload_type=version-upload
if [[ ${production_strategy} == deploy ]]; then
	# cf owns Container images, application updates, and trigger synchronization.
	# It deploys the prebuilt Worker once; do not activate another version later.
	upload_type=deploy
	run_cf deploy "${arguments[@]}"
else
	run_cf workers versions create "${arguments[@]}"
fi
version_id=""
deployment_id=""
preview_url=""
preview_alias_url=""
triggers_deployed=false
readonly uuid_pattern='^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
if [[ ${effective_mode} != dry-run ]]; then
	[[ -f ${WRANGLER_OUTPUT_FILE_PATH} ]] || fail 'cf did not write structured upload output.'
	if ! upload="$(jq --slurp --compact-output --exit-status --arg worker "${worker}" --arg uuid "${uuid_pattern}" --arg type "${upload_type}" '
		map(select(.type == $type))
		| if length == 1 then .[0] else error("Expected one uploaded version") end
		| select(.worker_name == $worker)
		| select(.version_id | type == "string" and test($uuid))
	' "${WRANGLER_OUTPUT_FILE_PATH}")"; then
		fail 'cf upload output must identify exactly one version of the requested Worker.'
	fi
	version_id="$(jq -r '.version_id' <<<"${upload}")"
	preview_url="$(jq -r '.preview_url // empty' <<<"${upload}")"
	preview_alias_url="$(jq -r '.preview_alias_url // empty' <<<"${upload}")"
	for url in "${preview_url}" "${preview_alias_url}"; do
		if [[ -n ${url} ]] && { [[ ${url} != https://* ]] || [[ ${url} == *$'\n'* ]] || [[ ${url} == *$'\r'* ]]; }; then
			fail 'cf returned an invalid preview URL.'
		fi
	done
	if [[ ${effective_mode} == preview && (-z ${preview_url} || -z ${preview_alias_url}) ]]; then
		fail 'cf upload output did not include both preview URLs.'
	fi
fi

if [[ ${effective_mode} == production ]]; then
	if [[ ${production_strategy} == deploy ]]; then
		# cf deploy reports the version, not the deployment UUID. The first entry
		# is the deployment actively serving traffic, according to the API.
		run_cf workers deployments list --worker "${worker}" >"${output_directory}/deployment.json"
		if ! deployment_id="$(jq --raw-output --exit-status --arg uuid "${uuid_pattern}" --arg version "${version_id}" '
			.deployments | select(type == "array" and length > 0) | .[0]
			| select(.strategy == "percentage")
			| select(.versions | type == "array" and length == 1 and .[0].version_id == $version and .[0].percentage == 100)
			| .id | select(type == "string" and test($uuid))
		' "${output_directory}/deployment.json")"; then
			fail 'The active deployment did not match the version returned by cf deploy at 100%.'
		fi
		triggers_deployed=true
	else
		versions="$(jq --null-input --compact-output --arg id "${version_id}" '[{version_id: $id, percentage: 100}]')"
		run_cf workers deployments create --worker "${worker}" --strategy percentage --versions "${versions}" \
			>"${output_directory}/deployment.json"
		if ! deployment_id="$(jq --raw-output --exit-status --arg uuid "${uuid_pattern}" \
			'.id | select(type == "string" and test($uuid))' "${output_directory}/deployment.json")"; then
			fail 'cf did not return a valid deployment ID.'
		fi
	fi
	# Never repeat an upload or activation when the exact new deployment is not yet visible.
	if [[ ${production_strategy} == versions && ${deployment_readback_available} == true ]]; then
		verify_created_deployment
	else
		run_cf workers deployments get "${deployment_id}" --worker "${worker}" >"${output_directory}/verified.json"
	fi
	if ! jq --exit-status --arg id "${deployment_id}" --arg version "${version_id}" '
		.id == $id and .strategy == "percentage" and
		(.versions | length == 1 and .[0].version_id == $version and .[0].percentage == 100)
	' "${output_directory}/verified.json" >/dev/null; then
		fail 'Deployment readback did not match the uploaded version at 100%.'
	fi
	if [[ ${production_strategy} == versions && ${deployment_readback_available} == true ]]; then
		# The common schema check must not let verification outlive its original budget.
		(($(deployment_now_ms) < deployment_readback_deadline)) || fail 'deployment_readback_pending'
	fi
	if [[ ${deploy_triggers} == true && ${production_strategy} == versions ]]; then
		run_cf workers triggers deploy --prebuilt --mode "${build_mode}" --worker "${worker}"
		triggers_deployed=true
	fi
fi

write_output() {
	if [[ -n ${GITHUB_OUTPUT:-} ]]; then
		printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT}"
	fi
}
write_output effective-mode "${effective_mode}"
write_output version-id "${version_id}"
write_output deployment-id "${deployment_id}"
write_output preview-url "${preview_url}"
write_output preview-alias-url "${preview_alias_url}"
write_output triggers-deployed "${triggers_deployed}"

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
	{
		printf '### Cloudflare Workers: %s\n\n' "${effective_mode}"
		if [[ ${effective_mode} == dry-run ]]; then
			printf 'cf validated the prebuilt Worker without uploading or rebuilding it.\n'
		else
			# Literal Markdown code spans.
			# shellcheck disable=SC2016
			printf 'Worker version: `%s`\n\n' "${version_id}"
			if [[ ${effective_mode} == preview ]]; then
				printf 'Version preview: <%s>\n\nAlias preview: <%s>\n' "${preview_url}" "${preview_alias_url}"
			else
				# Literal Markdown code spans.
				# shellcheck disable=SC2016
				printf 'Deployment: `%s` (verified at 100%%).\n\nTriggers synchronized: `%s`.\n' "${deployment_id}" "${triggers_deployed}"
				if [[ ${production_strategy} == deploy ]]; then
					printf '\ncf applied configured Container applications. Container rollout completion requires caller verification.\n'
				fi
			fi
		fi
	} >>"${GITHUB_STEP_SUMMARY}"
fi
