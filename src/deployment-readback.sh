#!/usr/bin/env bash
# Loaded before publication; called only with the pinned CLI's exact created UUID.
# shellcheck disable=SC2154

# GNU date and curl are supplied by the supported GitHub-hosted Linux runner.
deployment_now_ms() {
	date +%s%3N
}

# Both exact-resource and current-traffic reads consume the same remaining budget.
deployment_readback_request() {
	local endpoint="$1" destination="$2" headers="$3" deadline="$4" remaining request_timeout
	remaining=$((deadline - $(deployment_now_ms)))
	((remaining > 0)) || fail 'deployment_readback_pending'
	printf -v request_timeout '%d.%03d' "$((remaining / 1000))" "$((remaining % 1000))"
	# Ignore user curl config; never follow redirects or print transport/provider errors.
	if ! deployment_readback_status="$(curl -q --silent --proto '=https' --max-redirs 0 \
		--max-time "${request_timeout}" --connect-timeout "${request_timeout}" \
		--max-filesize 1048576 --request GET --header "@${headers}" \
		--output "${destination}" --write-out '%{http_code}' "${endpoint}")"; then
		(($(deployment_now_ms) < deadline)) || fail 'deployment_readback_pending'
		fail 'deployment_readback_request_failed'
	fi
	(($(deployment_now_ms) < deadline)) || fail 'deployment_readback_pending'
}

verify_created_deployment() {
	local deadline remaining now status sleep_time attempt
	local response="${output_directory}/readback-response.json"
	local headers="${output_directory}/readback-headers"
	local endpoint="https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/scripts/${worker}/deployments/${deployment_id}"
	deployment_readback_deadline=$(($(deployment_now_ms) + 30000))
	readonly deployment_readback_deadline
	deadline="${deployment_readback_deadline}"
	printf 'Authorization: Bearer %s\n' "${api_token}" >"${headers}"
	for ((attempt = 0; attempt < 30; attempt++)); do
		now="$(deployment_now_ms)"
		remaining=$((deadline - now))
		((remaining > 0)) || fail 'deployment_readback_pending'
		deployment_readback_request "${endpoint}" "${response}" "${headers}" "${deadline}"
		status="${deployment_readback_status}"
		if [[ ${status} == 404 ]] && jq --slurp -e '
			length == 1 and (.[0] | .success == false and (.errors | type == "array" and length > 0 and all(.[]; .code == 10336)))
		' "${response}" >/dev/null 2>&1; then
			remaining=$((deadline - $(deployment_now_ms)))
			((remaining > 0)) || fail 'deployment_readback_pending'
			((remaining < 1000)) || remaining=1000
			printf -v sleep_time '%d.%03d' "$((remaining / 1000))" "$((remaining % 1000))"
			sleep "${sleep_time}"
			continue
		fi
		[[ ${status} == 200 ]] || fail 'deployment_readback_response_failed'
		if ! jq --slurp -e --arg id "${deployment_id}" --arg version "${version_id}" '
			length == 1 and (.[0] | .success == true and (.errors | type == "array" and length == 0) and
			(.result | type == "object" and .id == $id and .strategy == "percentage" and
			(.versions | type == "array" and length == 1 and
			 .[0].version_id == $version and .[0].percentage == 100)))
		' "${response}" >/dev/null 2>&1; then
			fail 'Deployment readback did not match the uploaded version at 100%.'
		fi
		(($(deployment_now_ms) < deadline)) || fail 'deployment_readback_pending'
		# Historical exact-ID evidence alone cannot prove that it still serves traffic.
		deployment_readback_request "${endpoint%/*}" "${output_directory}/current-deployments.json" "${headers}" "${deadline}"
		[[ ${deployment_readback_status} == 200 ]] || fail 'deployment_readback_current_failed'
		if ! jq --slurp -e --arg id "${deployment_id}" --arg version "${version_id}" '
			length == 1 and (.[0] | .success == true and (.errors | type == "array" and length == 0) and
			(.result.deployments | type == "array" and length > 0 and
			(.[0] | .id == $id and .strategy == "percentage" and
			 (.versions | type == "array" and length == 1 and
			  .[0].version_id == $version and .[0].percentage == 100))))
		' "${output_directory}/current-deployments.json" >/dev/null 2>&1; then
			fail 'deployment_readback_current_mismatch'
		fi
		(($(deployment_now_ms) < deadline)) || fail 'deployment_readback_pending'
		jq --slurp '.[0].result' "${response}" >"${output_directory}/verified.json" 2>/dev/null || fail 'deployment_readback_response_failed'
		(($(deployment_now_ms) < deadline)) || fail 'deployment_readback_pending'
		return
	done
	fail 'deployment_readback_pending'
}
