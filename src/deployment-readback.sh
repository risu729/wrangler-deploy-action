# shellcheck shell=bash
# Loaded before publication; called only with the pinned CLI's exact created UUID
# or, for cf deploy, the exact version it reported.
# shellcheck disable=SC2154

# GNU date and curl are supplied by the supported GitHub-hosted Linux runner.
deployment_now_ms() {
	date +%s%3N
}

# One 30-second budget covers every deployment read of this run.
start_deployment_readback() {
	[[ -z ${deployment_readback_deadline:-} ]] || return 0
	deployment_readback_deadline=$(($(deployment_now_ms) + 30000))
	readonly deployment_readback_deadline
	deployment_readback_headers="${output_directory}/readback-headers"
	printf 'Authorization: Bearer %s\n' "${api_token}" >"${deployment_readback_headers}"
}

# Both exact-resource and current-traffic reads consume the same remaining budget.
# The optional prefix names the failure codes of a read with its own budget.
deployment_readback_request() {
	local endpoint="$1" destination="$2" headers="$3" deadline="$4" prefix="${5:-deployment_readback}"
	local remaining request_timeout
	remaining=$((deadline - $(deployment_now_ms)))
	((remaining > 0)) || fail "${prefix}_pending"
	printf -v request_timeout '%d.%03d' "$((remaining / 1000))" "$((remaining % 1000))"
	# Ignore user curl config; never follow redirects or print transport/provider errors.
	if ! deployment_readback_status="$(curl -q --silent --proto '=https' --max-redirs 0 \
		--max-time "${request_timeout}" --connect-timeout "${request_timeout}" \
		--max-filesize 1048576 --request GET --header "@${headers}" \
		--output "${destination}" --write-out '%{http_code}' "${endpoint}")"; then
		(($(deployment_now_ms) < deadline)) || fail "${prefix}_pending"
		fail "${prefix}_request_failed"
	fi
	(($(deployment_now_ms) < deadline)) || fail "${prefix}_pending"
}

# Wait at most one second, never past the shared deadline; expiry reports the given code.
deployment_readback_wait() {
	local code="$1" remaining sleep_time
	remaining=$((deployment_readback_deadline - $(deployment_now_ms)))
	((remaining > 0)) || fail "${code}"
	((remaining < 1000)) || remaining=1000
	printf -v sleep_time '%d.%03d' "$((remaining / 1000))" "$((remaining % 1000))"
	sleep "${sleep_time}"
	(($(deployment_now_ms) < deployment_readback_deadline)) || fail "${code}"
}

# Reads the current deployment collection. Returns 0 when its first entry serves the
# version at 100% (and, when given, is the expected deployment), 1 when another or no
# deployment is listed first yet. HTTP and schema failures stop immediately.
current_deployment_matches() {
	local expected_id="$1"
	local collection="${output_directory}/current-deployments.json"
	deployment_readback_request \
		"https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/scripts/${worker}/deployments" \
		"${collection}" "${deployment_readback_headers}" "${deployment_readback_deadline}"
	[[ ${deployment_readback_status} == 200 ]] || fail 'deployment_readback_current_failed'
	if ! jq --slurp -e --arg uuid "${uuid_pattern}" '
		length == 1 and (.[0] | .success == true and (.errors | type == "array" and length == 0) and
		(.result.deployments | type == "array" and
		 (length == 0 or (.[0] | type == "object" and (.id | type == "string" and test($uuid))))))
	' "${collection}" >/dev/null 2>&1; then
		fail 'deployment_readback_current_failed'
	fi
	jq --slurp -e --arg id "${expected_id}" --arg version "${version_id}" '
		.[0].result.deployments | length > 0 and
		(.[0] | ($id == "" or .id == $id) and
		 .strategy == "percentage" and
		 (.versions | type == "array" and length == 1 and
		  .[0].version_id == $version and .[0].percentage == 100))
	' "${collection}" >/dev/null 2>&1
}

# cf deploy reports the version, not the deployment UUID. Identify the deployment that
# serves that exact version at 100%, retrying only while the collection still lists
# another or no deployment first.
find_active_deployment() {
	start_deployment_readback
	until current_deployment_matches ''; do
		deployment_readback_wait 'deployment_readback_current_mismatch'
	done
	deployment_id="$(jq --slurp --raw-output '.[0].result.deployments[0].id' \
		"${output_directory}/current-deployments.json")"
}

verify_created_deployment() {
	local status attempt
	local response="${output_directory}/readback-response.json"
	local endpoint="https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/scripts/${worker}/deployments/${deployment_id}"
	start_deployment_readback
	for ((attempt = 0; attempt < 30; attempt++)); do
		deployment_readback_request "${endpoint}" "${response}" "${deployment_readback_headers}" "${deployment_readback_deadline}"
		status="${deployment_readback_status}"
		if [[ ${status} == 404 ]] && jq --slurp -e '
			length == 1 and (.[0] | .success == false and (.errors | type == "array" and length > 0 and all(.[]; .code == 10336)))
		' "${response}" >/dev/null 2>&1; then
			deployment_readback_wait 'deployment_readback_pending'
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
		(($(deployment_now_ms) < deployment_readback_deadline)) || fail 'deployment_readback_pending'
		# Historical exact-ID evidence alone cannot prove that it still serves traffic.
		# The collection can lag the exact resource, so only a not-yet-current listing waits.
		until current_deployment_matches "${deployment_id}"; do
			deployment_readback_wait 'deployment_readback_current_mismatch'
		done
		(($(deployment_now_ms) < deployment_readback_deadline)) || fail 'deployment_readback_pending'
		jq --slurp '.[0].result' "${response}" >"${output_directory}/verified.json" 2>/dev/null || fail 'deployment_readback_response_failed'
		(($(deployment_now_ms) < deployment_readback_deadline)) || fail 'deployment_readback_pending'
		return
	done
	fail 'deployment_readback_pending'
}
