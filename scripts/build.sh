#!/usr/bin/env bash
set -euo pipefail

script_directory="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(CDPATH= cd -- "$script_directory/.." && pwd)"

usage() {
    echo "usage: $0 [output-binary-path]" >&2
}

if [[ "$#" -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
    exit 0
fi
if [[ "$#" -gt 1 ]]; then
    usage
    exit 2
fi

output_path="${1:-$repository_root/dist/codex-switch}"
if [[ "$output_path" != /* ]]; then
    output_path="$PWD/$output_path"
fi

if [[ "$output_path" == */* ]]; then
    output_parent="${output_path%/*}"
else
    output_parent="$PWD"
fi
if [[ -z "$output_parent" ]]; then
    output_parent="/"
fi

is_trusted_macos_system_symlink() {
    local symlink_path="$1"
    local symlink_target
    local owner_id

    if ! owner_id="$(stat -f '%u' "$symlink_path" 2>/dev/null)"; then
        return 1
    fi
    [[ "$owner_id" == "0" ]] || return 1

    case "$symlink_path" in
        /var)
            symlink_target="$(readlink "$symlink_path")"
            [[ "$symlink_target" == "private/var" || "$symlink_target" == "/private/var" ]]
            ;;
        /tmp)
            symlink_target="$(readlink "$symlink_path")"
            [[ "$symlink_target" == "private/tmp" || "$symlink_target" == "/private/tmp" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_directory_tree() {
    local directory_path="$1"
    local current_path="/"
    local component
    local component_path
    local -a components

    if [[ "$directory_path" != /* ]]; then
        echo "directory path must be absolute: $directory_path" >&2
        return 1
    fi

    IFS='/' read -r -a components <<< "${directory_path#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        component_path="$current_path$component"
        if [[ -L "$component_path" ]] && ! is_trusted_macos_system_symlink "$component_path"; then
            echo "refusing symlink directory component: $component_path" >&2
            return 1
        fi
        if [[ -e "$component_path" && ! -d "$component_path" ]]; then
            echo "directory component is not a directory: $component_path" >&2
            return 1
        fi
        current_path="$component_path/"
    done

    if [[ ! -d "$directory_path" ]]; then
        mkdir -p -- "$directory_path"
    fi

    if [[ -L "$directory_path" || ! -d "$directory_path" ]]; then
        echo "build output parent is not a directory: $directory_path" >&2
        return 1
    fi
}

ensure_directory_tree "$output_parent"

if [[ -L "$output_path" ]]; then
    echo "refusing to replace a symlink build output: $output_path" >&2
    exit 1
fi
if [[ -e "$output_path" && ! -f "$output_path" ]]; then
    echo "build output is not a regular file: $output_path" >&2
    exit 1
fi

if [[ -x /usr/bin/codesign ]]; then
    codesign_path="/usr/bin/codesign"
elif codesign_path="$(command -v codesign 2>/dev/null)" && [[ -n "$codesign_path" ]]; then
    :
else
    echo "codesign is required on macOS to create the ad-hoc signed CLI" >&2
    exit 1
fi

staging_directory="$(mktemp -d "$output_parent/.codex-switch-build.XXXXXX")"
staged_binary=""
remove_staging_directory() {
    local remove_status=0

    if [[ -z "$staging_directory" || ! -d "$staging_directory" ]]; then
        return 0
    fi
    if [[ -L "$staging_directory" ]]; then
        echo "refusing to remove a replaced build staging symlink: $staging_directory" >&2
        return 1
    fi
    if [[ -n "$staged_binary" && ( -e "$staged_binary" || -L "$staged_binary" ) ]]; then
        if [[ -d "$staged_binary" && ! -L "$staged_binary" ]]; then
            echo "refusing to remove an unexpected build staging directory: $staged_binary" >&2
            return 1
        fi
        if ! rm -f -- "$staged_binary"; then
            remove_status=1
        fi
    fi
    if ! rmdir "$staging_directory"; then
        remove_status=1
    fi
    return "$remove_status"
}
cleanup() {
    if ! remove_staging_directory; then
        echo "could not clean build staging directory: $staging_directory" >&2
    fi
}
trap cleanup EXIT

swift build \
    --configuration release \
    --product codex-switch \
    --package-path "$repository_root"

binary_directory="$(swift build \
    --configuration release \
    --show-bin-path \
    --package-path "$repository_root")"
built_binary="$binary_directory/codex-switch"
if [[ ! -f "$built_binary" || ! -x "$built_binary" || -L "$built_binary" ]]; then
    echo "release CLI binary was not produced: $built_binary" >&2
    exit 1
fi

staged_binary="$staging_directory/codex-switch"
install -m 0755 "$built_binary" "$staged_binary"

"$codesign_path" --force --sign - "$staged_binary"
"$codesign_path" --verify --strict --verbose=2 "$staged_binary"
staged_digest="$(shasum -a 256 "$staged_binary" | awk '{print $1}')"

if [[ -L "$output_path" ]]; then
    echo "refusing to replace a symlink build output: $output_path" >&2
    exit 1
fi
mv -f -- "$staged_binary" "$output_path"

if [[ -L "$output_path" || ! -f "$output_path" || ! -x "$output_path" ]]; then
    echo "build output failed post-placement verification: $output_path" >&2
    exit 1
fi
if ! installed_digest="$(shasum -a 256 "$output_path" | awk '{print $1}')" || [[ "$installed_digest" != "$staged_digest" ]]; then
    echo "build output changed during placement: $output_path" >&2
    exit 1
fi
if ! "$codesign_path" --verify --strict --verbose=2 "$output_path"; then
    echo "build output failed post-placement code-signature verification: $output_path" >&2
    exit 1
fi

echo "Built and verified: $output_path"
