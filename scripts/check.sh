#!/usr/bin/env bash
set -euo pipefail

script_directory="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(CDPATH= cd -- "$script_directory/.." && pwd)"

swift test --package-path "$repository_root"
swift build \
    --configuration release \
    --product codex-switch \
    --package-path "$repository_root"

for script_path in "$script_directory"/*.sh; do
    bash -n "$script_path"
done

"$script_directory/check-distribution.sh"
"$script_directory/check-release.sh"

echo "Checks passed"
exit 0
