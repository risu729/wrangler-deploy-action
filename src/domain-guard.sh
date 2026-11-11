# shellcheck shell=bash
# shellcheck disable=SC2154

prepare_domain_guard() {
	local configs=() config
	if ! jq --slurp --exit-status --arg account "${account_id}" '
		length == 1 and (.[0] | type == "object" and
		((has("accountId") | not) or .accountId == $account))
	' .cloudflare/output/v0/config.json >/dev/null 2>&1; then
		fail 'domain_guard_account_mismatch'
	fi
	for config in .cloudflare/output/v0/workers/*/worker.config.json; do
		[[ -f ${config} ]] && configs+=("${config}")
	done
	((${#configs[@]} > 0)) || fail 'domain_guard_build_output_missing'
	if ! jq --slurp --exit-status --arg worker "${worker}" '
		map(select(.name == $worker))
		| if length == 1 then .[0] else error("ambiguous worker") end
		| if .domains == null then [] else .domains end
		| if type == "array" then . else error("invalid domains") end
		| map(if type == "string" then {hostname: .}
			elif type == "object" and (.production | type == "boolean") and (.previews | type == "boolean")
			then {hostname, enabled: .production, previews_enabled: .previews}
			else error("invalid domain") end)
		| if all(.[]; .hostname | type == "string" and test("^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$"))
			and (map(.hostname) | length == (unique | length)) then . else error("invalid hostname") end
	' "${configs[@]}" >"${output_directory}/domain-origins.json" 2>/dev/null; then
		fail 'domain_guard_build_output_invalid'
	fi
	domain_guard_enabled=false
	if [[ $(jq 'length' "${output_directory}/domain-origins.json") != 0 ]]; then
		command -v curl >/dev/null 2>&1 || fail 'domain_guard_curl_required'
		[[ ${account_id} =~ ^[a-zA-Z0-9_-]+$ && ${worker} =~ ^[a-zA-Z0-9_-]+$ ]] || fail 'domain_guard_identity_invalid'
		[[ ${api_token} != *$'\n'* && ${api_token} != *$'\r'* ]] || fail 'domain_guard_token_invalid'
		printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "${api_token}" >"${output_directory}/domain-headers"
		domain_guard_enabled=true
	fi
}

verify_domain_changeset() {
	local phase="$1" status codes
	[[ ${domain_guard_enabled} == true ]] || return 0
	if ! status="$(curl -q --silent --proto '=https' --max-redirs 0 --max-time 30 --connect-timeout 10 \
		--max-filesize 1048576 --request POST --header "@${output_directory}/domain-headers" \
		--data-binary "@${output_directory}/domain-origins.json" --output "${output_directory}/domain-changeset.json" \
		--write-out '%{http_code}' "https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/scripts/${worker}/domains/changeset?replace_state=true")"; then
		fail 'domain_guard_request_failed'
	fi
	if [[ ${status} != 200 ]]; then
		[[ ${status} =~ ^[0-9]{3}$ ]] || status=unknown
		codes="$(jq --slurp --compact-output --exit-status '
			if length == 1 and (.[0] | type == "object") then .[0].errors else null end
			| if type == "array" and length <= 10 then
				[.[] | .code | select(type == "number") | select(. >= 0 and . <= 999999999 and floor == .)]
			else [] end
		' "${output_directory}/domain-changeset.json" 2>/dev/null)" || codes='[]'
		printf 'Domain changeset HTTP status: %s; Cloudflare error codes: %s\n' "${status}" "${codes}" >&2
		fail 'domain_guard_response_failed'
	fi
	if ! jq --slurp --exit-status --arg phase "${phase}" --arg worker "${worker}" \
		--slurpfile desired "${output_directory}/domain-origins.json" '
		length == 1 and (.[0] | .success == true and (.errors | type == "array" and length == 0)
		and (.result | type == "object"
		and (.added | type == "array") and (.updated | type == "array")
		and (.removed | type == "array" and length == 0)
		and (.conflicting | type == "array" and length == 0)
		and (all(.updated[]; .modified == false and .service == $worker
			and (.enabled | type == "boolean") and (.previews_enabled | type == "boolean")))
		and (all(.updated[]; . as $actual | $desired[0][] | select(.hostname == $actual.hostname)
			| ((has("enabled") | not) or .enabled == $actual.enabled)
			and ((has("previews_enabled") | not) or .previews_enabled == $actual.previews_enabled)))
		and (([.added[], .updated[]] | map(.hostname) | sort) == ($desired[0] | map(.hostname) | sort))
		and (if $phase == "after" then (.added | length == 0) else true end)))
	' "${output_directory}/domain-changeset.json" >/dev/null 2>&1; then
		fail 'domain_guard_conflict_or_unverified_state'
	fi
}
