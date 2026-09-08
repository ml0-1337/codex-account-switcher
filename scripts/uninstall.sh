#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 [--yes] [--destination path] [destination-path]" >&2
}

assume_yes=0
destination_path=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --yes)
            if [[ "$assume_yes" -eq 1 ]]; then
                usage
                exit 2
            fi
            assume_yes=1
            shift
            ;;
        --destination)
            if [[ "$#" -lt 2 || -n "$destination_path" || -z "$2" ]]; then
                usage
                exit 2
            fi
            destination_path="$2"
            shift 2
            ;;
        --destination=*)
            if [[ -n "$destination_path" || -z "${1#--destination=}" ]]; then
                usage
                exit 2
            fi
            destination_path="${1#--destination=}"
            shift
            ;;
        --)
            shift
            while [[ "$#" -gt 0 ]]; do
                if [[ -z "$destination_path" ]]; then
                    [[ -n "$1" ]] || { usage; exit 2; }
                    destination_path="$1"
                else
                    usage
                    exit 2
                fi
                shift
            done
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            if [[ -n "$destination_path" || -z "$1" ]]; then
                usage
                exit 2
            fi
            destination_path="$1"
            shift
            ;;
    esac
done

if [[ -z "$destination_path" ]]; then
    user_home="${HOME:?HOME is not set}"
    destination_path="$user_home/.local/bin/codex-switch"
fi

if [[ "$destination_path" != /* ]]; then
    destination_path="$PWD/$destination_path"
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

ensure_existing_components_are_safe() {
    local candidate_path="$1"
    local current_path="/"
    local component
    local component_path
    local -a components

    if [[ "$candidate_path" != /* ]]; then
        echo "path must be absolute: $candidate_path" >&2
        return 1
    fi

    IFS='/' read -r -a components <<< "${candidate_path#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        component_path="$current_path$component"
        if [[ -L "$component_path" ]] && ! is_trusted_macos_system_symlink "$component_path"; then
            echo "refusing a path containing a symlink: $component_path" >&2
            return 1
        fi
        current_path="$component_path/"
    done
}

ensure_existing_components_are_safe "$destination_path"
if [[ ! -e "$destination_path" && ! -L "$destination_path" ]]; then
    echo "CLI is not installed at: $destination_path"
    exit 0
fi
if [[ -L "$destination_path" ]]; then
    echo "refusing to remove a symlink: $destination_path" >&2
    exit 1
fi
if [[ ! -f "$destination_path" || ! -x "$destination_path" ]]; then
    echo "refusing to remove a non-executable or non-regular file: $destination_path" >&2
    exit 1
fi

if [[ "$assume_yes" -eq 0 ]]; then
    if [[ ! -t 0 ]]; then
        echo "interactive confirmation is required, or pass --yes" >&2
        exit 1
    fi
    printf 'Move only this CLI binary to a recoverable backup? %s [y/N]: ' "$destination_path"
    read -r answer
    case "$answer" in
        y|Y|yes|YES)
            ;;
        *)
            echo "Uninstall cancelled"
            exit 0
            ;;
    esac
fi

destination_parent="${destination_path%/*}"
if [[ -z "$destination_parent" ]]; then
    destination_parent="/"
fi
if [[ ! -d "$destination_parent" || -L "$destination_parent" ]]; then
    echo "destination parent is not a directory: $destination_parent" >&2
    exit 1
fi

lock_directory="$destination_parent/.codex-switch.lock"
if [[ -L "$lock_directory" || -e "$lock_directory" ]]; then
    echo "an install or uninstall is already in progress or left a lock: $lock_directory" >&2
    exit 1
fi
if ! mkdir "$lock_directory"; then
    echo "could not acquire install/uninstall lock: $lock_directory" >&2
    exit 1
fi

cleanup() {
    if [[ -d "$lock_directory" ]]; then
        rmdir "$lock_directory"
    fi
}
trap cleanup EXIT

removed_directory="$(mktemp -d "$destination_parent/.codex-switch-removed.XXXXXX")"
removed_path="$removed_directory/${destination_path##*/}"
if ! mv -- "$destination_path" "$removed_path"; then
    echo "could not move the CLI to a recoverable backup: $destination_path" >&2
    rmdir "$removed_directory"
    exit 1
fi

echo "Moved only the CLI binary to: $removed_path"
echo "Authentication, state, settings, and Keychain items were not changed."
