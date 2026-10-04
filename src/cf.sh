#!/usr/bin/env bash

# This file is sourced; callers consume the resolved command and source.
# shellcheck disable=SC2034

cf_command=()
cf_source=""

resolve_working_directory() {
	local input_working_directory="$1"
	local input_workspace="$2"
	local canonical_workspace
	local candidate
	local canonical_working_directory

	if [[ ${input_working_directory} == /* ]]; then
		echo "working-directory must be relative to GITHUB_WORKSPACE: ${input_working_directory}" >&2
		return 1
	fi

	canonical_workspace="$(cd "${input_workspace}" && pwd -P)"
	candidate="${canonical_workspace%/}/${input_working_directory}"
	if [[ ! -d ${candidate} ]]; then
		echo "Working directory does not exist: ${candidate}" >&2
		return 1
	fi

	canonical_working_directory="$(cd "${candidate}" && pwd -P)"
	if [[ ${canonical_working_directory} != "${canonical_workspace}" ]] &&
		[[ ${canonical_working_directory} != "${canonical_workspace%/}/"* ]]; then
		echo "working-directory must stay within GITHUB_WORKSPACE: ${input_working_directory}" >&2
		return 1
	fi

	printf '%s\n' "${canonical_working_directory}"
}

resolve_cf() {
	local input_working_directory="$1"
	local input_workspace="$2"
	local search_directory
	local parent_directory
	local package_directory=""
	local candidate
	local yarn_pnp_file=""

	search_directory="$(cd "${input_working_directory}" && pwd -P)"
	input_workspace="$(cd "${input_workspace}" && pwd -P)"
	if [[ ${search_directory} != "${input_workspace}" ]] &&
		[[ ${search_directory} != "${input_workspace%/}/"* ]]; then
		echo "cf working directory must stay within GITHUB_WORKSPACE." >&2
		return 1
	fi

	while true; do
		if [[ -f ${search_directory}/package.json ]] &&
			command -v jq >/dev/null 2>&1 &&
			jq -e \
				'(.dependencies.cf // .devDependencies.cf // .optionalDependencies.cf) != null' \
				"${search_directory}/package.json" >/dev/null 2>&1; then
			package_directory="${search_directory}"
			break
		fi

		if [[ ${search_directory} == "${input_workspace}" ]]; then
			break
		fi

		parent_directory="$(dirname "${search_directory}")"
		if [[ ${parent_directory} == "${search_directory}" ]] ||
			[[ ${parent_directory}/ != "${input_workspace}/"* ]]; then
			break
		fi
		search_directory="${parent_directory}"
	done

	search_directory="${package_directory}"
	while [[ -n ${search_directory} ]]; do
		candidate="${search_directory}/node_modules/.bin/cf"
		if [[ -x ${candidate} ]]; then
			cf_command=("${candidate}")
			cf_source="project node_modules"
			return 0
		fi
		if [[ -z ${yarn_pnp_file} && -f ${search_directory}/.pnp.cjs ]]; then
			yarn_pnp_file="${search_directory}/.pnp.cjs"
		fi

		if [[ ${search_directory} == "${input_workspace}" ]]; then
			break
		fi

		parent_directory="$(dirname "${search_directory}")"
		if [[ ${parent_directory} == "${search_directory}" ]] ||
			[[ ${parent_directory}/ != "${input_workspace}/"* ]]; then
			break
		fi
		search_directory="${parent_directory}"
	done

	if [[ -n ${yarn_pnp_file} ]] && command -v yarn >/dev/null 2>&1; then
		cf_command=(yarn --cwd "${package_directory}" run -B cf)
		cf_source="project Yarn Plug'n'Play"
		return 0
	fi

	if command -v mise >/dev/null 2>&1 && mise which cf >/dev/null 2>&1; then
		cf_command=(mise exec -- cf)
		cf_source="mise"
		return 0
	fi

	echo "cf is required; install it in the project or configure it as a mise tool." >&2
	return 1
}

run_cf() {
	"${cf_command[@]}" "$@"
}
