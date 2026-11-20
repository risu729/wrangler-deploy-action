#!/usr/bin/env bash
# Sourced by deploy.sh after shared input and working-directory validation.
# shellcheck disable=SC2154

readonly preview_name="${INPUT_PREVIEW_NAME:-}"
[[ ${preview_name} =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail 'preview-name must be a lowercase DNS label of 1-63 characters.'
[[ -n ${account_id} && -n ${api_token} ]] || fail 'Workers Preview operations require both explicit credentials.'
[[ ${account_id} =~ ^[a-zA-Z0-9_-]+$ && ${worker} =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'Invalid account ID or Worker name.'
[[ ${api_token} != *$'\n'* && ${api_token} != *$'\r'* ]] || fail 'Invalid API token.'
command -v curl >/dev/null 2>&1 || fail 'curl is required for Workers Preview verification and cleanup.'
if [[ ${mode} == worker-preview ]]; then
	[[ $(date +%s%3N 2>/dev/null) =~ ^[0-9]+$ ]] || fail 'GNU date is required for Workers Preview verification.'
fi

umask 077
output_directory="$(mktemp -d "${temporary_root%/}/cf-preview-action.XXXXXX")"
readonly output_directory
trap 'rm -rf -- "${output_directory}"' EXIT
printf 'Authorization: Bearer %s\n' "${api_token}" >"${output_directory}/headers"
readonly preview_base="https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/workers/${worker}/previews"
readonly id_pattern='^[a-zA-Z0-9_-]+$'
readonly url_pattern='^https://[a-zA-Z0-9.-]+\.workers\.dev/?$'

# Only the documented missing-Preview response is treated as absence. In
# particular, authentication failures and a missing Worker are not success.
preview_request() {
	local method="$1" path="$2" destination="$3" status
	status="$(curl --silent --show-error --max-time 60 --request "${method}" \
		--header "@${output_directory}/headers" --output "${destination}" \
		--write-out '%{http_code}' "${preview_base}/${path}")" || fail 'Workers Preview API request failed.'
	if [[ ${status} == 404 ]] && jq -e '.success == false and (.errors | length > 0 and all(.[]; .code == 10025))' "${destination}" >/dev/null 2>&1; then
		return 4
	fi
	if [[ ${status} != 2[0-9][0-9] ]] || ! jq -e '.success == true' "${destination}" >/dev/null 2>&1; then
		fail "Workers Preview API request failed (HTTP ${status})."
	fi
}

# Reads one Preview resource and sets readback_status to matched, missing or mismatched.
preview_readback() {
	local path="$1" file="${output_directory}/$2" filter="$3" request_status=0
	preview_request GET "${path}" "${file}" || request_status=$?
	if ((request_status != 0)); then
		readback_status=missing
		return 1
	fi
	if jq -e --argjson upload "${upload}" ".result | ${filter}" "${file}" >/dev/null; then
		readback_status=matched
		return 0
	fi
	readback_status=mismatched
	return 1
}

# Waits at most one second before the next read, failing with the last state once the budget is spent.
readback_wait() {
	local state="$1" missing_message="$2" mismatch_message="$3" remaining sleep_time
	remaining=$((readback_deadline - $(date +%s%3N)))
	if ((remaining <= 0)); then
		[[ ${state} == missing ]] && fail "${missing_message}"
		fail "${mismatch_message}"
	fi
	((remaining < 1000)) || remaining=1000
	printf -v sleep_time '%d.%03d' "$((remaining / 1000))" "$((remaining % 1000))"
	sleep "${sleep_time}"
}

preview_id=''
deployment_id=''
preview_url=''
deployment_url=''
if [[ ${mode} == worker-preview ]]; then
	resolve_cf "${resolved_working_directory}" "${workspace}"
	export CLOUDFLARE_ACCOUNT_ID="${account_id}" CLOUDFLARE_API_TOKEN="${api_token}" CI=true
	preview_output="${output_directory}/upload.json"
	# cf builds with Preview context, as documented; build logs go to stderr.
	# Since cf beta.32 the positional argument is a static assets directory.
	run_cf previews deploy --preview-name "${preview_name}" --mode "${build_mode}" --worker "${worker}" >"${preview_output}"
	[[ -f ${preview_output} ]] || fail 'cf did not write structured Preview output.'
	if ! upload="$(jq -sce --arg name "${preview_name}" --arg id "${id_pattern}" --arg url "${url_pattern}" '
		map(select(.type == "preview"))
		| if length == 1 then .[0] else error("Expected one Preview") end
		| select(.version == 1 and .preview_name == $name and .preview_slug == $name)
		| select(.preview_id | type == "string" and test($id))
		| select(.deployment_id | type == "string" and test($id))
		| select(.preview_urls | type == "array" and length > 0 and all(.[]; type == "string" and test($url)))
		| select(.deployment_urls | type == "array" and length > 0 and all(.[]; type == "string" and test($url)))
	' "${preview_output}")"; then
		fail 'cf output did not identify exactly one deployment of the requested Preview.'
	fi
	preview_id="$(jq -r '.preview_id' <<<"${upload}")"
	deployment_id="$(jq -r '.deployment_id' <<<"${upload}")"
	preview_url="$(jq -r '.preview_urls[0]' <<<"${upload}")"
	deployment_url="$(jq -r '.deployment_urls[0]' <<<"${upload}")"
	# The Previews API is eventually consistent: right after cf returns, a new
	# Preview can still read as missing and deployments/latest can still name the
	# previous deployment. Both readbacks share one 30-second budget.
	readback_deadline=$(($(date +%s%3N) + 30000))
	# shellcheck disable=SC2016 # jq filters, expanded by preview_readback.
	until preview_readback "${preview_name}" preview.json '.id == $upload.preview_id and .name == $upload.preview_name and .slug == $upload.preview_slug and .urls == $upload.preview_urls'; do
		readback_wait "${readback_status}" 'Uploaded Preview was not found.' 'Preview readback did not match the upload.'
	done
	# shellcheck disable=SC2016 # jq filters, expanded by preview_readback.
	until preview_readback "${preview_id}/deployments/latest" deployment.json '.id == $upload.deployment_id and .urls == $upload.deployment_urls'; do
		readback_wait "${readback_status}" 'Preview deployment was not found.' 'Latest Preview deployment did not match the upload.'
	done
else
	if preview_request GET "${preview_name}" "${output_directory}/preview.json"; then
		preview_id="$(jq -er --arg name "${preview_name}" --arg id "${id_pattern}" '.result | select(.name == $name and .slug == $name) | .id | select(type == "string" and test($id))' "${output_directory}/preview.json")" || fail 'Preview lookup did not match the requested name.'
		preview_request DELETE "${preview_id}" "${output_directory}/deleted.json" || fail 'Preview deletion failed.'
		if preview_request GET "${preview_name}" "${output_directory}/after.json"; then
			fail 'Preview is still present after deletion.'
		fi
	fi
fi

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
	{
		printf 'effective-mode=%s\npreview-id=%s\ndeployment-id=%s\n' "${mode}" "${preview_id}" "${deployment_id}"
		printf 'preview-url=%s\ndeployment-url=%s\ntriggers-deployed=false\n' "${preview_url}" "${deployment_url}"
	} >>"${GITHUB_OUTPUT}"
fi
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
	{
		printf '### Cloudflare Workers: %s\n\nPreview: %s\n\n' "${mode}" "${preview_name}"
		if [[ ${mode} == worker-preview ]]; then
			printf 'Verified Preview: <%s>\n\nDeployment: <%s>\n' "${preview_url}" "${deployment_url}"
		else
			printf 'Verified that the Preview is absent.\n'
		fi
	} >>"${GITHUB_STEP_SUMMARY}"
fi
