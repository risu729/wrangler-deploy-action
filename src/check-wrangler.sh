#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_directory
# shellcheck source=src/wrangler.sh
source "${script_directory}/wrangler.sh"

readonly working_directory="${INPUT_WORKING_DIRECTORY:-.}"
readonly workspace="${GITHUB_WORKSPACE:-${PWD}}"

if ! command -v jq >/dev/null 2>&1; then
	echo "jq is required; use a GitHub-hosted Linux runner or install it first." >&2
	exit 1
fi

resolved_working_directory="$(resolve_working_directory "${working_directory}" "${workspace}")"
readonly resolved_working_directory

cd "${resolved_working_directory}"

resolve_wrangler "${resolved_working_directory}" "${workspace}"

if ! wrangler_version_output="$(run_wrangler --version)"; then
	echo "Unable to run the resolved Wrangler executable." >&2
	exit 1
fi
readonly wrangler_version_output

echo "Using Wrangler ${wrangler_version_output} via ${wrangler_source}."
