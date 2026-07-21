#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_directory
# shellcheck source=src/wrangler.sh
source "${script_directory}/wrangler.sh"

readonly mode="${INPUT_MODE:?mode is required}"
readonly working_directory="${INPUT_WORKING_DIRECTORY:-.}"
readonly config="${INPUT_CONFIG:-wrangler.toml}"
readonly environment="${INPUT_ENVIRONMENT:-}"
readonly preview_alias="${INPUT_PREVIEW_ALIAS:-}"
readonly account_id="${INPUT_CLOUDFLARE_ACCOUNT_ID:-}"
readonly api_token="${INPUT_CLOUDFLARE_API_TOKEN:-}"
readonly workspace="${GITHUB_WORKSPACE:-${PWD}}"
readonly temporary_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"

case "${mode}" in
preview-or-dry-run | dry-run | production) ;;
*)
	echo "Unsupported mode: ${mode}" >&2
	exit 1
	;;
esac

if ! command -v jq >/dev/null 2>&1; then
	echo "jq is required; use a GitHub-hosted Linux runner or install it first." >&2
	exit 1
fi

resolved_working_directory="$(resolve_working_directory "${working_directory}" "${workspace}")"
readonly resolved_working_directory

if [[ ! -f "${resolved_working_directory}/${config}" ]]; then
	echo "Wrangler configuration does not exist: ${resolved_working_directory}/${config}" >&2
	exit 1
fi

if [[ -n ${account_id} && -z ${api_token} ]] ||
	[[ -z ${account_id} && -n ${api_token} ]]; then
	echo "Cloudflare account ID and API token must be supplied together." >&2
	exit 1
fi

if [[ ${mode} == "preview-or-dry-run" && -z ${preview_alias} ]]; then
	echo "preview-alias is required in preview-or-dry-run mode." >&2
	exit 1
fi

if [[ ${mode} == "production" && -z ${account_id} ]]; then
	echo "Cloudflare account ID and API token are required for production deployment." >&2
	exit 1
fi

cd "${resolved_working_directory}"
resolve_wrangler "${resolved_working_directory}" "${workspace}"

wrangler_output_directory="$(mktemp -d "${temporary_root%/}/wrangler-deploy-action.XXXXXX")"
readonly wrangler_output_directory
readonly wrangler_output_path="${wrangler_output_directory}/wrangler-output.json"
trap 'rm -rf -- "${wrangler_output_directory}"' EXIT

export WRANGLER_OUTPUT_FILE_PATH="${wrangler_output_path}"

wrangler_arguments=()
if [[ -n ${environment} ]]; then
	wrangler_arguments+=(--env "${environment}")
fi

effective_mode=""
case "${mode}" in
preview-or-dry-run)
	if [[ -n ${account_id} ]]; then
		effective_mode="preview"
		CLOUDFLARE_ACCOUNT_ID="${account_id}" \
			CLOUDFLARE_API_TOKEN="${api_token}" \
			run_wrangler versions upload \
			--config "${config}" \
			--preview-alias "${preview_alias}" \
			"${wrangler_arguments[@]}"
	else
		effective_mode="dry-run"
		run_wrangler deploy \
			--config "${config}" \
			--dry-run \
			"${wrangler_arguments[@]}"
	fi
	;;
dry-run)
	effective_mode="dry-run"
	run_wrangler deploy \
		--config "${config}" \
		--dry-run \
		"${wrangler_arguments[@]}"
	;;
production)
	effective_mode="production"
	CLOUDFLARE_ACCOUNT_ID="${account_id}" \
		CLOUDFLARE_API_TOKEN="${api_token}" \
		run_wrangler deploy \
		--config "${config}" \
		"${wrangler_arguments[@]}"
	;;
esac

write_output() {
	local name="$1"
	local value="$2"

	if [[ -n ${GITHUB_OUTPUT:-} ]]; then
		printf '%s=%s\n' "${name}" "${value}" >>"${GITHUB_OUTPUT}"
	fi
}

append_summary() {
	if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
		printf '%s\n' "$@" >>"${GITHUB_STEP_SUMMARY}"
	fi
}

write_output effective-mode "${effective_mode}"
write_output preview-url ""
write_output preview-alias-url ""
write_output deployment-targets '[]'

case "${effective_mode}" in
dry-run)
	append_summary \
		"### Cloudflare Workers Deploy Dry Run" \
		"" \
		"Wrangler validated \`${config}\` without uploading or deploying a Worker." \
		""
	;;
preview)
	if [[ ! -f ${wrangler_output_path} ]]; then
		echo "Wrangler did not write preview output to ${wrangler_output_path}." >&2
		exit 1
	fi

	preview_url="$(jq -rs \
		'map(select(.type == "version-upload"))[0].preview_url // empty' \
		"${wrangler_output_path}")"
	preview_alias_url="$(jq -rs \
		'map(select(.type == "version-upload"))[0].preview_alias_url // empty' \
		"${wrangler_output_path}")"

	if [[ -z ${preview_url} || -z ${preview_alias_url} ]]; then
		echo "Wrangler output at ${wrangler_output_path} did not include both preview URLs." >&2
		exit 1
	fi

	write_output preview-url "${preview_url}"
	write_output preview-alias-url "${preview_alias_url}"
	append_summary \
		"### Cloudflare Workers Preview" \
		"" \
		"Preview alias: \`${preview_alias}\`" \
		"" \
		"| Name | URL |" \
		"| - | - |" \
		"| Version preview | <${preview_url}> |" \
		"| Alias preview | <${preview_alias_url}> |" \
		""
	;;
production)
	if [[ ! -f ${wrangler_output_path} ]]; then
		echo "Wrangler did not write production output to ${wrangler_output_path}." >&2
		exit 1
	fi

	if ! jq -es 'any(.[]; .type == "deploy")' "${wrangler_output_path}" >/dev/null; then
		echo "Wrangler output at ${wrangler_output_path} did not include a deploy entry." >&2
		exit 1
	fi

	mapfile -t deployment_targets < <(
		jq -r 'select(.type == "deploy") | (.targets // [])[]' "${wrangler_output_path}"
	)

	deployment_targets_json="$(
		jq -sc '[.[] | select(.type == "deploy") | (.targets // [])[]]' \
			"${wrangler_output_path}"
	)"
	write_output deployment-targets "${deployment_targets_json}"

	summary_lines=(
		"### Cloudflare Workers Production Deploy"
		""
	)
	if [[ ${#deployment_targets[@]} -eq 0 ]]; then
		summary_lines+=("Wrangler reported no deployment targets.")
	else
		summary_lines+=("#### Targets" "")
		for target in "${deployment_targets[@]}"; do
			case "${target}" in
			http://* | https://*) summary_lines+=("- <${target}>") ;;
			*) summary_lines+=("- \`${target}\`") ;;
			esac
		done
	fi
	summary_lines+=("")
	append_summary "${summary_lines[@]}"
	;;
esac
