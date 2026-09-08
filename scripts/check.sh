#!/usr/bin/env bash
set -euo pipefail

script_directory="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(CDPATH= cd -- "$script_directory/.." && pwd)"

swift test --package-path "$repository_root"
swift build \
    --configuration release \
    --product codex-switch \
    --package-path "$repository_root"

bash -n \
    "$script_directory/build.sh" \
    "$script_directory/install.sh" \
    "$script_directory/check.sh" \
    "$script_directory/check-distribution.sh" \
    "$script_directory/uninstall.sh"

"$script_directory/check-distribution.sh"

echo "Checks passed"
exit 0
