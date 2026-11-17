# shellcheck shell=bash
# Loaded before publication; called only with the pinned CLI's exact created UUID or,
# for cf deploy, the exact version it reported.
# shellcheck disable=SC2154

# GNU date and curl are supplied by the supported GitHub-hosted Linux runner.
deployment_now_ms() {
	date +%s%3N
}

# Set once the current-deployment list has shown another or no deployment first, so
# that running out of budget afterwards reports the mismatch instead of a pending read.
current_mismatch_seen=false
current_reads=0

# Prints which deployment the last schema-checked list showed first, then fails.
# A later response is never printed: it may be late, missing or not yet checked.
# Provider messages and annotations are never printed.
fail_current_mismatch() {
	local listed
	listed="$(jq --slurp --raw-output '
		.[0].result.deployments |
		if length == 0 then "none" else .[0] |
		"\(.id) created_on=\(.created_on |
			if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$") then . else "unknown" end) " +
		"versions=\([.versions[] | "\(.version_id)@\(.percentage)%"] | join(","))"
		end
	' "${output_directory}/current-mismatch.json" 2>/dev/null)" || listed=unreadable
	printf 'Current deployment list after %d read(s): expected %s serving %s at 100%%, first listed %s.\n' \
		"${current_reads}" "${deployment_id:-a deployment}" "${version_id}" "${listed}" >&2
	fail 'deployment_readback_current_mismatch'
}

readback_expired() {
	[[ ${current_mismatch_seen} != true ]] || fail_current_mismatch
	fail 'deployment_readback_pending'
}

# Both exact-resource and current-traffic reads consume the same remaining budget.
deployment_readback_request() {
	local endpoint="$1" destination="$2" headers="$3" deadline="$4" remaining request_timeout
	remaining=$((deadline - $(deployment_now_ms)))
	((remaining > 0)) || readback_expired
	printf -v request_timeout '%d.%03d' "$((remaining / 1000))" "$((remaining % 1000))"
	# Ignore user curl config; never follow redirects or print transport/provider errors.
	if ! deployment_readback_status="$(curl -q --silent --proto '=https' --max-redirs 0 \
		--max-time "${request_timeout}" --connect-timeout "${request_timeout}" \
		--max-filesize 1048576 --request GET --header "@${headers}" \
		--output "${destination}" --write-out '%{http_code}' "${endpoint}")"; then
		(($(deployment_now_ms) < deadline)) || readback_expired
		fail 'deployment_readback_request_failed'
	fi
	(($(deployment_now_ms) < deadline)) || readback_expired
}

# Wait at most one second, never past the shared deadline.
deployment_readback_wait() {
	local remaining sleep_time
	remaining=$((deployment_readback_deadline - $(deployment_now_ms)))
	((remaining > 0)) || readback_expired
	((remaining < 1000)) || remaining=1000
	printf -v sleep_time '%d.%03d' "$((remaining / 1000))" "$((remaining % 1000))"
	sleep "${sleep_time}"
	(($(deployment_now_ms) < deployment_readback_deadline)) || readback_expired
}

# One 30-second budget covers every deployment read of this run.
start_deployment_readback() {
	[[ -z ${deployment_readback_deadline:-} ]] || return 0
	deployment_readback_deadline=$(($(deployment_now_ms) + 30000))
	readonly deployment_readback_deadline
	deployment_readback_headers="${output_directory}/readback-headers"
	printf 'Authorization: Bearer %s\n' "${api_token}" >"${deployment_readback_headers}"
}

# Reads the current-deployment list. Returns 0 when its first entry is the created
# deployment (any deployment while deployment_id is still empty, for cf deploy)
# serving the uploaded version at 100%, and 1 while the list still shows
# another or no deployment first: the list can lag the exact resource. HTTP and schema
# failures stop immediately, and so does the created deployment listed with other
# versions, since deployments are immutable.
current_deployment_matches() {
	local endpoint="$1" headers="$2"
	local collection="${output_directory}/current-deployments.json"
	# Never evaluate a previous attempt's body if this one writes none.
	rm -f -- "${collection}" || fail 'deployment_readback_current_failed'
	deployment_readback_request "${endpoint}" "${collection}" "${headers}" "${deployment_readback_deadline}"
	current_reads=$((current_reads + 1))
	[[ ${deployment_readback_status} == 200 ]] || fail 'deployment_readback_current_failed'
	if ! jq --slurp -e --arg uuid "${uuid_pattern}" '
		length == 1 and (.[0] | .success == true and (.errors | type == "array" and length == 0) and
		(.result.deployments | type == "array" and
		 (length == 0 or (.[0] | type == "object" and (.id | type == "string" and test($uuid)) and
		  (.strategy | type == "string") and
		  (.versions | type == "array" and all(.[]; type == "object" and
		   (.version_id | type == "string" and test($uuid)) and (.percentage | type == "number")))))))
	' "${collection}" >/dev/null 2>&1; then
		fail 'deployment_readback_current_failed'
	fi
	if jq --slurp -e --arg id "${deployment_id}" --arg version "${version_id}" '
		.[0].result.deployments | length > 0 and
		(.[0] | ($id == "" or .id == $id) and .strategy == "percentage" and
		 (.versions | length == 1 and .[0].version_id == $version and .[0].percentage == 100))
	' "${collection}" >/dev/null 2>&1; then
		return 0
	fi
	cp -- "${collection}" "${output_directory}/current-mismatch.json" || fail 'deployment_readback_current_failed'
	if jq --slurp -e --arg id "${deployment_id}" '
		.[0].result.deployments | length > 0 and .[0].id == $id
	' "${collection}" >/dev/null 2>&1; then
		fail_current_mismatch
	fi
	current_mismatch_seen=true
	return 1
}

# cf deploy reports the version, not the deployment UUID. Take the UUID of the
# deployment that the current list shows first serving that exact version at 100%,
# reading the list again while it still shows another or no deployment first.
find_active_deployment() {
	local list="https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/scripts/${worker}/deployments"
	start_deployment_readback
	until current_deployment_matches "${list}" "${deployment_readback_headers}"; do
		deployment_readback_wait
	done
	((current_reads == 1)) ||
		printf 'Current deployment list showed the deployed version after %d read(s).\n' "${current_reads}"
	deployment_id="$(jq --slurp --raw-output '.[0].result.deployments[0].id' \
		"${output_directory}/current-deployments.json")" || fail 'deployment_readback_current_failed'
	# The exact-ID proof below reads the list again from a clean state.
	current_reads=0
	current_mismatch_seen=false
	(($(deployment_now_ms) < deployment_readback_deadline)) || fail 'deployment_readback_pending'
}

verify_created_deployment() {
	local deadline remaining now status sleep_time attempt
	local response="${output_directory}/readback-response.json"
	local endpoint="https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/scripts/${worker}/deployments/${deployment_id}"
	start_deployment_readback
	deadline="${deployment_readback_deadline}"
	local headers="${deployment_readback_headers}"
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
		until current_deployment_matches "${endpoint%/*}" "${headers}"; do
			deployment_readback_wait
		done
		# Record how often the list lagged so callers' logs show whether the retry matters.
		((current_reads == 1)) ||
			printf 'Current deployment list matched after %d read(s).\n' "${current_reads}"
		(($(deployment_now_ms) < deadline)) || fail 'deployment_readback_pending'
		jq --slurp '.[0].result' "${response}" >"${output_directory}/verified.json" 2>/dev/null || fail 'deployment_readback_response_failed'
		(($(deployment_now_ms) < deadline)) || fail 'deployment_readback_pending'
		return
	done
	fail 'deployment_readback_pending'
}
