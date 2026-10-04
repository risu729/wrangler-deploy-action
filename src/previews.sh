#!/usr/bin/env bash
# Sourced by deploy.sh after shared input and working-directory validation.
# shellcheck disable=SC2154

readonly preview_name="${INPUT_PREVIEW_NAME:-}"
[[ ${preview_name} =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail 'preview-name must be a lowercase DNS label of 1-63 characters.'
[[ -n ${account_id} && -n ${api_token} ]] || fail 'Workers Preview operations require both explicit credentials.'
[[ ${account_id} =~ ^[a-zA-Z0-9_-]+$ && ${worker} =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'Invalid account ID or Worker name.'
[[ ${api_token} != *$'\n'* && ${api_token} != *$'\r'* ]] || fail 'Invalid API token.'
command -v curl >/dev/null 2>&1 || fail 'curl is required for Workers Preview verification and cleanup.'

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

preview_id=''
deployment_id=''
preview_url=''
deployment_url=''
if [[ ${mode} == worker-preview ]]; then
	[[ -f .cloudflare/output/v0/config.json ]] || fail 'Cloudflare Build Output is missing; build a Preview first.'
	resolve_cf "${resolved_working_directory}" "${workspace}"
	export CLOUDFLARE_ACCOUNT_ID="${account_id}" CLOUDFLARE_API_TOKEN="${api_token}" CI=true
	export WRANGLER_OUTPUT_FILE_PATH="${output_directory}/upload.jsonl"
	run_cf previews deploy "${preview_name}" --prebuilt --mode "${build_mode}" --worker "${worker}"
	[[ -f ${WRANGLER_OUTPUT_FILE_PATH} ]] || fail 'cf did not write structured Preview output.'
	if ! upload="$(jq -sce --arg name "${preview_name}" --arg id "${id_pattern}" --arg url "${url_pattern}" '
		map(select(.type == "preview"))
		| if length == 1 then .[0] else error("Expected one Preview") end
		| select(.version == 1 and .preview_name == $name and .preview_slug == $name)
		| select(.preview_id | type == "string" and test($id))
		| select(.deployment_id | type == "string" and test($id))
		| select(.preview_urls | type == "array" and length > 0 and all(.[]; type == "string" and test($url)))
		| select(.deployment_urls | type == "array" and length > 0 and all(.[]; type == "string" and test($url)))
	' "${WRANGLER_OUTPUT_FILE_PATH}")"; then
		fail 'cf output did not identify exactly one deployment of the requested Preview.'
	fi
	preview_id="$(jq -r '.preview_id' <<<"${upload}")"
	deployment_id="$(jq -r '.deployment_id' <<<"${upload}")"
	preview_url="$(jq -r '.preview_urls[0]' <<<"${upload}")"
	deployment_url="$(jq -r '.deployment_urls[0]' <<<"${upload}")"
	preview_request GET "${preview_name}" "${output_directory}/preview.json" || fail 'Uploaded Preview was not found.'
	jq -e --argjson upload "${upload}" '.result | .id == $upload.preview_id and .name == $upload.preview_name and .slug == $upload.preview_slug and .urls == $upload.preview_urls' "${output_directory}/preview.json" >/dev/null || fail 'Preview readback did not match the upload.'
	preview_request GET "${preview_id}/deployments/latest" "${output_directory}/deployment.json" || fail 'Preview deployment was not found.'
	jq -e --argjson upload "${upload}" '.result | .id == $upload.deployment_id and .urls == $upload.deployment_urls' "${output_directory}/deployment.json" >/dev/null || fail 'Latest Preview deployment did not match the upload.'
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
