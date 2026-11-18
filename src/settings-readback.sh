# shellcheck shell=bash
# Loaded before publication for production-strategy deploy.
# Uses the request and clock helpers of deployment-readback.sh.
# shellcheck disable=SC2154

# cf deploy applies non-versioned script settings after it activates the version, but
# reports a failed settings write only as a warning. Read the setting back instead.
prepare_script_settings_expectation() {
	local configs=() config
	for config in .cloudflare/output/v1/workers/*/worker.config.json; do
		[[ -f ${config} ]] && configs+=("${config}")
	done
	((${#configs[@]} > 0)) || fail 'script_settings_build_output_missing'
	# Build Output uses camelCase keys; the API uses snake_case, and cf maps each key
	# one to one. Without a declaration, what cf writes depends on its upload path: the
	# settings PATCH sends observability disabled, while a full script upload omits it.
	if ! jq --slurp --exit-status --arg worker "${worker}" '
		def snake: gsub("(?<upper>[A-Z])"; "_" + (.upper | ascii_downcase));
		def snake_keys: if type == "object" then with_entries(.key |= snake | .value |= snake_keys)
			elif type == "array" then map(snake_keys) else . end;
		map(select(.name == $worker))
		| if length == 1 then .[0] else error("ambiguous worker") end
		| {observability: (if .observability == null then null
			elif (.observability | type) == "object" then (.observability | snake_keys)
			else error("invalid observability") end)}
	' "${configs[@]}" >"${output_directory}/script-settings-desired.json" 2>/dev/null; then
		fail 'script_settings_build_output_invalid'
	fi
	if jq --exit-status '.observability == null' "${output_directory}/script-settings-desired.json" >/dev/null 2>&1; then
		script_settings_declared=false
	else
		script_settings_declared=true
	fi
}

script_settings_declared=false

# A mismatch observed before the budget ran out is reported as that mismatch, with
# the differing setting paths, never as a pending read.
script_settings_mismatch=""
script_settings_expired() {
	if [[ -n ${script_settings_mismatch} ]]; then
		# Setting paths are configuration keys, never values or secrets.
		printf 'Script settings differing from the Build Output: %s\n' "${script_settings_mismatch}" >&2
		fail 'script_settings_readback_mismatch'
	fi
	fail 'script_settings_readback_pending'
}

# Every declared observability value must be present unchanged in the readback; fields
# that are not declared are ignored. A declared field the response omits is a mismatch:
# the API defaults of omitted fields are not filled in. Nothing is read without a
# declaration, since cf may then leave the stored setting unchanged.
verify_script_settings() {
	local response="${output_directory}/script-settings.json" deadline mismatched codes status remaining sleep_time
	[[ ${script_settings_declared} == true ]] || return 0
	deadline=$(($(deployment_now_ms) + 30000))
	while true; do
		# Never evaluate a previous attempt's body if this one writes none.
		rm -f -- "${response}" || fail 'script_settings_readback_response_failed'
		deployment_readback_request \
			"https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/scripts/${worker}/script-settings" \
			"${response}" "${deployment_readback_headers}" "${deadline}" \
			script_settings_expired script_settings_readback_request_failed
		status="${deployment_readback_status}"
		if [[ ${status} != 200 ]]; then
			[[ ${status} =~ ^[0-9]{3}$ ]] || status=unknown
			codes="$(jq --slurp --compact-output --exit-status '
				if length == 1 and (.[0] | type == "object") then .[0].errors else null end
				| if type == "array" and length <= 10 then
					[.[] | .code | select(type == "number") | select(. >= 0 and . <= 999999999 and floor == .)]
				else [] end
			' "${response}" 2>/dev/null)" || codes='[]'
			printf 'Script settings HTTP status: %s; Cloudflare error codes: %s\n' "${status}" "${codes}" >&2
			fail 'script_settings_readback_response_failed'
		fi
		if ! mismatched="$(jq --slurp --compact-output --exit-status \
			--slurpfile desired "${output_directory}/script-settings-desired.json" '
			if length == 1 and (.[0] | .success == true and (.errors | type == "array" and length == 0)
				and (.result | type == "object")
				and (.result.observability | type == "object" or type == "null"))
			then (.[0].result | .observability //= {enabled: false}) as $actual
				| [$desired[0] | paths(type != "object") as $path
					# Arrays are compared whole; a different response shape is a mismatch.
					| select($path | all(.[]; type == "string"))
					| select(($actual | try getpath($path) catch "type mismatch") != ($desired[0] | getpath($path)))
					| $path | map(tostring) | join(".")]
			else error("invalid script settings") end
		' "${response}" 2>/dev/null)"; then
			fail 'script_settings_readback_response_failed'
		fi
		[[ ${mismatched} != '[]' ]] || return 0
		script_settings_mismatch="${mismatched}"
		remaining=$((deadline - $(deployment_now_ms)))
		if ((remaining > 0)); then
			((remaining < 1000)) || remaining=1000
			printf -v sleep_time '%d.%03d' "$((remaining / 1000))" "$((remaining % 1000))"
			sleep "${sleep_time}"
		fi
		(($(deployment_now_ms) < deadline)) || script_settings_expired
	done
}
