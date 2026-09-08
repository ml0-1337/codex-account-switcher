#!/usr/bin/env bash
set -euo pipefail

script_directory="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(CDPATH= cd -- "$script_directory/.." && pwd)"

usage() {
    echo "usage: $0 [--source binary] [--destination path] [source-binary [destination-path]]" >&2
}

source_path=""
destination_path=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --source)
            if [[ "$#" -lt 2 || -n "$source_path" || -z "$2" ]]; then
                usage
                exit 2
            fi
            source_path="$2"
            shift 2
            ;;
        --source=*)
            if [[ -n "$source_path" || -z "${1#--source=}" ]]; then
                usage
                exit 2
            fi
            source_path="${1#--source=}"
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
                if [[ -z "$source_path" ]]; then
                    [[ -n "$1" ]] || { usage; exit 2; }
                    source_path="$1"
                elif [[ -z "$destination_path" ]]; then
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
            if [[ -z "$source_path" ]]; then
                [[ -n "$1" ]] || { usage; exit 2; }
                source_path="$1"
            elif [[ -z "$destination_path" ]]; then
                [[ -n "$1" ]] || { usage; exit 2; }
                destination_path="$1"
            else
                usage
                exit 2
            fi
            shift
            ;;
    esac
done

if [[ -z "$source_path" ]]; then
    source_path="$repository_root/dist/codex-switch"
fi
if [[ -z "$destination_path" ]]; then
    user_home="${HOME:?HOME is not set}"
    destination_path="$user_home/.local/bin/codex-switch"
fi

absolute_path() {
    local candidate_path="$1"
    if [[ "$candidate_path" == /* ]]; then
        printf '%s\n' "$candidate_path"
    else
        printf '%s/%s\n' "$PWD" "$candidate_path"
    fi
}

source_path="$(absolute_path "$source_path")"
destination_path="$(absolute_path "$destination_path")"

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
        chmod 700 "$directory_path"
    fi

    if [[ -L "$directory_path" || ! -d "$directory_path" ]]; then
        echo "destination parent is not a directory: $directory_path" >&2
        return 1
    fi
}

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

ensure_existing_components_are_safe "$source_path"
if [[ -L "$source_path" || ! -f "$source_path" || ! -x "$source_path" ]]; then
    echo "source binary must be an executable regular file: $source_path" >&2
    exit 1
fi

if [[ -x /usr/bin/codesign ]]; then
    codesign_path="/usr/bin/codesign"
elif codesign_path="$(command -v codesign 2>/dev/null)" && [[ -n "$codesign_path" ]]; then
    :
else
    echo "codesign is required to verify the ad-hoc signed CLI" >&2
    exit 1
fi
if ! "$codesign_path" --verify --strict "$source_path" >/dev/null 2>&1; then
    echo "source binary is not a valid signed CLI: $source_path" >&2
    exit 1
fi

if [[ "$destination_path" == */* ]]; then
    destination_parent="${destination_path%/*}"
else
    destination_parent="$PWD"
fi
if [[ -z "$destination_parent" ]]; then
    destination_parent="/"
fi
destination_name="${destination_path##*/}"
if [[ -z "$destination_name" ]]; then
    echo "destination must name a file: $destination_path" >&2
    exit 2
fi

ensure_directory_tree "$destination_parent"
ensure_existing_components_are_safe "$destination_path"
if [[ -L "$destination_path" ]]; then
    echo "refusing to replace symlink destination: $destination_path" >&2
    exit 1
fi
if [[ -e "$destination_path" && ! -f "$destination_path" ]]; then
    echo "existing destination is not a regular file: $destination_path" >&2
    exit 1
fi
if [[ -e "$destination_path" && ! -x "$destination_path" ]]; then
    echo "existing destination is not executable; refusing to replace a user-owned file: $destination_path" >&2
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

staging_directory=""
staged_path=""
backup_directory=""
backup_path=""
failed_directory=""
transaction_started=0
install_verified=0
rollback_in_progress=0
remove_staging_directory() {
    local remove_status=0

    if [[ -z "$staging_directory" || ! -d "$staging_directory" ]]; then
        return 0
    fi
    if [[ -L "$staging_directory" ]]; then
        echo "refusing to remove a replaced staging symlink: $staging_directory" >&2
        return 1
    fi
    if [[ -n "$staged_path" && ( -e "$staged_path" || -L "$staged_path" ) ]]; then
        if [[ -d "$staged_path" && ! -L "$staged_path" ]]; then
            echo "refusing to remove an unexpected staging directory: $staged_path" >&2
            return 1
        fi
        if ! rm -f -- "$staged_path"; then
            remove_status=1
        fi
    fi
    if ! rmdir "$staging_directory"; then
        remove_status=1
    fi
    return "$remove_status"
}
cleanup() {
    local cleanup_status=0
    local failed_path

    if [[ "$rollback_in_progress" -eq 0 && "$transaction_started" -eq 1 && "$install_verified" -eq 0 && -n "$backup_path" && -e "$backup_path" ]]; then
        rollback_in_progress=1
        if [[ -e "$destination_path" || -L "$destination_path" ]]; then
            if failed_directory="$(mktemp -d "$destination_parent/.codex-switch-failed.XXXXXX")"; then
                failed_path="$failed_directory/$destination_name"
                if ! mv -- "$destination_path" "$failed_path"; then
                    echo "could not preserve the incomplete installed CLI: $destination_path" >&2
                    cleanup_status=1
                else
                    echo "preserved incomplete CLI at: $failed_path" >&2
                fi
            else
                echo "could not preserve the incomplete installed CLI: $destination_path" >&2
                cleanup_status=1
            fi
        fi
        if [[ "$cleanup_status" -eq 0 ]]; then
            if ! mv -- "$backup_path" "$destination_path"; then
                echo "could not restore the previous CLI after an interrupted install: $destination_path" >&2
                echo "restore it manually from: $backup_path" >&2
                cleanup_status=1
            elif ! rmdir "$backup_directory"; then
                echo "could not remove the empty backup directory: $backup_directory" >&2
                cleanup_status=1
            else
                transaction_started=0
            fi
        fi
    fi

    if ! remove_staging_directory; then
        cleanup_status=1
    fi
    if [[ -d "$lock_directory" ]]; then
        if ! rmdir "$lock_directory"; then
            cleanup_status=1
        fi
    fi
    return "$cleanup_status"
}
handle_signal() {
    local signal_status="$1"
    exit "$signal_status"
}
trap 'cleanup_status=$?; if cleanup; then cleanup_result=0; else cleanup_result=$?; fi; if [[ "$cleanup_status" -eq 0 && "$cleanup_result" -ne 0 ]]; then exit 1; fi; exit "$cleanup_status"' EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

staging_directory="$(mktemp -d "$destination_parent/.codex-switch-install.XXXXXX")"
staged_path="$staging_directory/$destination_name"
install -m 0755 "$source_path" "$staged_path"
if ! cmp -s "$source_path" "$staged_path"; then
    echo "staged CLI differs from the source before installation: $source_path" >&2
    exit 1
fi
if ! "$codesign_path" --verify --strict "$staged_path" >/dev/null 2>&1; then
    echo "staged CLI failed code-signature verification: $staged_path" >&2
    exit 1
fi

transaction_started=1
if [[ -e "$destination_path" ]]; then
    backup_directory="$(mktemp -d "$destination_parent/.codex-switch-backup.XXXXXX")"
    backup_path="$backup_directory/$destination_name"
    if ! mv -- "$destination_path" "$backup_path"; then
        echo "could not back up the existing CLI: $destination_path" >&2
        rmdir "$backup_directory"
        exit 1
    fi
fi

rollback_install() {
    local rollback_status=0
    local failed_path

    if [[ -e "$destination_path" || -L "$destination_path" ]]; then
        if failed_directory="$(mktemp -d "$destination_parent/.codex-switch-failed.XXXXXX")"; then
            failed_path="$failed_directory/$destination_name"
            if ! mv -- "$destination_path" "$failed_path"; then
                echo "could not preserve the failed installed CLI: $destination_path" >&2
                rollback_status=1
            else
                echo "preserved failed CLI at: $failed_path" >&2
            fi
        else
            echo "could not create a backup for the failed installed CLI: $destination_path" >&2
            rollback_status=1
        fi
    fi

    if [[ -n "$backup_path" && -e "$backup_path" ]]; then
        if ! mv -- "$backup_path" "$destination_path"; then
            echo "could not restore the previous CLI: $destination_path" >&2
            rollback_status=1
        else
            if ! rmdir "$backup_directory"; then
                echo "could not remove the empty backup directory: $backup_directory" >&2
                rollback_status=1
            fi
        fi
    fi

    if [[ "$rollback_status" -eq 0 ]]; then
        transaction_started=0
    fi

    return "$rollback_status"
}

if ! mv -- "$staged_path" "$destination_path"; then
    echo "could not install the staged CLI: $destination_path" >&2
    if ! rollback_install; then
        echo "the previous CLI may need manual restoration from its backup" >&2
    fi
    exit 1
fi

if [[ -L "$destination_path" || ! -f "$destination_path" || ! -x "$destination_path" ]]; then
    echo "installed CLI failed post-install verification: $destination_path" >&2
    if ! rollback_install; then
        echo "the previous CLI may need manual restoration from its backup" >&2
    fi
    exit 1
fi
if ! cmp -s "$source_path" "$destination_path"; then
    echo "installed CLI differs from the source after placement: $destination_path" >&2
    if ! rollback_install; then
        echo "the previous CLI may need manual restoration from its backup" >&2
    fi
    exit 1
fi
if ! "$codesign_path" --verify --strict "$destination_path" >/dev/null 2>&1; then
    echo "installed CLI failed code-signature verification: $destination_path" >&2
    if ! rollback_install; then
        echo "the previous CLI may need manual restoration from its backup" >&2
    fi
    exit 1
fi

install_verified=1
transaction_started=0

if [[ -n "$backup_path" ]]; then
    echo "Previous CLI backed up at: $backup_path"
fi
echo "Installed: $destination_path"
