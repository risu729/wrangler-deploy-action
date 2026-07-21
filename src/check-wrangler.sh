#!/usr/bin/env bash

set -euo pipefail

readonly working_directory="${INPUT_WORKING_DIRECTORY:-.}"
readonly workspace="${GITHUB_WORKSPACE:-${PWD}}"

if ! command -v mise >/dev/null 2>&1; then
	echo "mise is required; install it before invoking this action." >&2
	exit 1
fi

if [[ ${working_directory} == /* ]]; then
	resolved_working_directory="${working_directory}"
else
	resolved_working_directory="${workspace}/${working_directory}"
fi

if [[ ! -d ${resolved_working_directory} ]]; then
	echo "Working directory does not exist: ${resolved_working_directory}" >&2
	exit 1
fi

cd "${resolved_working_directory}"

if ! mise which wrangler >/dev/null 2>&1; then
	echo "Wrangler is required; configure it as a mise tool in the calling project." >&2
	exit 1
fi

if ! wrangler_version_output="$(mise exec -- wrangler --version)"; then
	echo "Unable to run Wrangler through mise." >&2
	exit 1
fi
readonly wrangler_version_output

echo "Using Wrangler ${wrangler_version_output}."
