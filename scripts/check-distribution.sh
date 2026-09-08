#!/usr/bin/env bash
set -euo pipefail

script_directory="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(CDPATH= cd -- "$script_directory/.." && pwd)"

for required_command in git rg file cmp find mktemp install stat; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "required command is not available: $required_command" >&2
        exit 1
    fi
done
if ! printf 'pcre2-check\n' | rg --pcre2 -q 'pcre2-check'; then
    echo "ripgrep with PCRE2 support is required for the publication scan" >&2
    exit 1
fi

if [[ -x /usr/bin/codesign ]]; then
    codesign_path="/usr/bin/codesign"
elif codesign_path="$(command -v codesign 2>/dev/null)" && [[ -n "$codesign_path" ]]; then
    :
else
    echo "codesign is required for the signed-binary lifecycle checks" >&2
    exit 1
fi

check_temp_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-switch-check.XXXXXX")"
cleanup() {
    local owner_id
    if [[ -n "${check_temp_root:-}" && -d "$check_temp_root" ]]; then
        if owner_id="$(stat -f '%u' "$check_temp_root" 2>/dev/null)" && [[ "$owner_id" == "$(id -u)" ]]; then
            rm -rf -- "$check_temp_root"
        else
            echo "refusing to remove an unowned check directory: $check_temp_root" >&2
        fi
    fi
}
trap cleanup EXIT

private_marker="$(printf 'PRIVATE')"
users_component="$(printf 'Users')"
home_component="$(printf 'home')"
private_key_pattern="-----BEGIN[[:space:]]+(RSA |EC |OPENSSH |DSA |ENCRYPTED |)?${private_marker} KEY-----"
jwt_pattern='\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b'
provider_token_pattern='\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'
secret_assignment_pattern="(?i)(?:api[_-]?key|access[_-]?token|secret(?:[_-]?key)?|refresh[_-]?token|password)\\b[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9+/_-]{32,}"
email_pattern='\b[A-Za-z0-9._%+-]+@(?!(?:example|test|invalid|localhost)\.)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'
personal_path_pattern="(/${users_component}/|/${home_component}/)[A-Za-z0-9._-]+(/|$)|[A-Za-z]:\\\\Users\\\\[^[:space:]\"']+"

display_source_path() {
    local file_path="$1"
    case "$file_path" in
        "$repository_root"/*)
            printf '%s' "${file_path#"$repository_root"/}"
            ;;
        *)
            printf '%s' "$(basename "$file_path")"
            ;;
    esac
}

scan_one_pattern() {
    local file_path="$1"
    local description="$2"
    local pattern="$3"
    local scan_status

    set +e
    rg --pcre2 -l -- "$pattern" "$file_path" >/dev/null 2>&1
    scan_status=$?
    set -e

    if [[ "$scan_status" -eq 0 ]]; then
        echo "publication scan found $description in: $(display_source_path "$file_path")" >&2
        return 1
    fi
    if [[ "$scan_status" -ne 1 ]]; then
        echo "publication scan failed for: $(display_source_path "$file_path")" >&2
        return 2
    fi
    return 0
}

scan_source_paths() {
    local file_path
    local mime_type
    local pattern_status
    local scan_result=0

    for file_path in "$@"; do
        if [[ -L "$file_path" ]]; then
            echo "publication scan refuses a symlink source file: $(display_source_path "$file_path")" >&2
            scan_result=2
            continue
        fi
        if [[ ! -f "$file_path" ]]; then
            echo "publication scan cannot read a regular source file: $(display_source_path "$file_path")" >&2
            scan_result=2
            continue
        fi

        if ! mime_type="$(file -b --mime-type "$file_path")"; then
            echo "publication scan could not classify: $(display_source_path "$file_path")" >&2
            scan_result=2
            continue
        fi
        case "$mime_type" in
            text/*|application/json|application/xml|application/x-sh|application/x-shellscript|inode/x-empty)
                ;;
            *)
                echo "publication source contains a binary or non-text file: $(display_source_path "$file_path") ($mime_type)" >&2
                scan_result=1
                continue
                ;;
        esac

        if scan_one_pattern "$file_path" "private-key material" "$private_key_pattern"; then
            :
        else
            pattern_status=$?
            if [[ "$pattern_status" -eq 1 ]]; then
                scan_result=1
            else
                scan_result=2
            fi
        fi
        if scan_one_pattern "$file_path" "a JWT-like token" "$jwt_pattern"; then
            :
        else
            pattern_status=$?
            if [[ "$pattern_status" -eq 1 ]]; then
                scan_result=1
            else
                scan_result=2
            fi
        fi
        if scan_one_pattern "$file_path" "a provider API token" "$provider_token_pattern"; then
            :
        else
            pattern_status=$?
            if [[ "$pattern_status" -eq 1 ]]; then
                scan_result=1
            else
                scan_result=2
            fi
        fi
        if scan_one_pattern "$file_path" "a secret-like assignment" "$secret_assignment_pattern"; then
            :
        else
            pattern_status=$?
            if [[ "$pattern_status" -eq 1 ]]; then
                scan_result=1
            else
                scan_result=2
            fi
        fi
        if scan_one_pattern "$file_path" "a personal email address" "$email_pattern"; then
            :
        else
            pattern_status=$?
            if [[ "$pattern_status" -eq 1 ]]; then
                scan_result=1
            else
                scan_result=2
            fi
        fi
        if scan_one_pattern "$file_path" "a personal absolute path" "$personal_path_pattern"; then
            :
        else
            pattern_status=$?
            if [[ "$pattern_status" -eq 1 ]]; then
                scan_result=1
            else
                scan_result=2
            fi
        fi
    done

    return "$scan_result"
}

is_tracked_path() {
    local relative_path="$1"
    local tracked_status

    set +e
    git -C "$repository_root" ls-files --cached --error-unmatch -- "$relative_path" >/dev/null 2>&1
    tracked_status=$?
    set -e

    if [[ "$tracked_status" -eq 0 ]]; then
        return 0
    fi
    if [[ "$tracked_status" -eq 1 ]]; then
        return 1
    fi
    echo "could not determine whether the publication path is tracked: $relative_path" >&2
    return 2
}

collect_public_source_files() {
    local source_list_file="$check_temp_root/source-files"
    local relative_path
    local absolute_path
    local tracked_status
    public_files=()

    if ! git -C "$repository_root" ls-files \
        -z \
        --cached \
        --others \
        --exclude-standard > "$source_list_file"; then
        echo "could not enumerate tracked and untracked publication files" >&2
        return 1
    fi

    while IFS= read -r -d '' relative_path; do
        case "$relative_path" in
            .git/*)
                continue
                ;;
            .build/*|dist/*)
                if is_tracked_path "$relative_path"; then
                    :
                else
                    tracked_status=$?
                    if [[ "$tracked_status" -eq 2 ]]; then
                        return 2
                    fi
                    continue
                fi
                ;;
        esac
        absolute_path="$repository_root/$relative_path"
        if [[ -e "$absolute_path" || -L "$absolute_path" ]]; then
            public_files+=("$absolute_path")
        fi
    done < "$source_list_file"

    if [[ "${#public_files[@]}" -eq 0 ]]; then
        echo "publication source file list is empty" >&2
        return 1
    fi
}

repeat_char() {
    local character="$1"
    local count="$2"
    local result=""
    while [[ "$count" -gt 0 ]]; do
        result="${result}${character}"
        count=$((count - 1))
    done
    printf '%s' "$result"
}

expect_scan_status() {
    local fixture_path="$1"
    local expected_status="$2"
    local description="$3"
    local fixture_status

    if scan_source_paths "$fixture_path"; then
        fixture_status=0
    else
        fixture_status=$?
    fi
    if [[ "$fixture_status" -ne "$expected_status" ]]; then
        echo "$description scan returned status $fixture_status, expected $expected_status" >&2
        return 1
    fi
}

run_source_scan_behavior_tests() {
    local fixture_directory="$check_temp_root/scan-fixtures"
    local private_fixture="$fixture_directory/private-key.txt"
    local jwt_fixture="$fixture_directory/jwt.txt"
    local provider_fixture="$fixture_directory/provider-token.txt"
    local secret_fixture="$fixture_directory/secret-assignment.txt"
    local email_fixture="$fixture_directory/personal-email.txt"
    local path_fixture="$fixture_directory/personal-path.txt"
    local binary_fixture="$fixture_directory/binary"
    local negative_fixture="$fixture_directory/negative.txt"
    local marked_fixture="$fixture_directory/testfixtures/marked-private-key.txt"
    local private_header
    local jwt_value
    local provider_token
    local personal_email
    local personal_path
    local secret_value

    mkdir -m 700 "$fixture_directory" "$fixture_directory/testfixtures"

    private_header="-----BEGIN $(printf 'PRIVATE') KEY-----"
    jwt_value="eyJ$(repeat_char a 16).$(repeat_char b 16).$(repeat_char c 16)"
    provider_token="sk-$(repeat_char a 20)"
    personal_email="fixture@$(printf 'personal.dev')"
    personal_path="/$(printf 'Users')/example-user/private"
    secret_value="$(repeat_char z 40)"

    printf '%s\n' "$private_header" > "$private_fixture"
    expect_scan_status "$private_fixture" 1 "private-key"
    printf '%s\n' "$jwt_value" > "$jwt_fixture"
    expect_scan_status "$jwt_fixture" 1 "JWT"
    printf '%s\n' "$provider_token" > "$provider_fixture"
    expect_scan_status "$provider_fixture" 1 "provider-token"
    printf 'refresh_token = "%s"\n' "$secret_value" > "$secret_fixture"
    expect_scan_status "$secret_fixture" 1 "secret-assignment"
    printf 'contact = %s\n' "$personal_email" > "$email_fixture"
    expect_scan_status "$email_fixture" 1 "personal-email"
    printf 'path = %s\n' "$personal_path" > "$path_fixture"
    expect_scan_status "$path_fixture" 1 "personal-path"
    printf '\000\001\002\003' > "$binary_fixture"
    expect_scan_status "$binary_fixture" 1 "binary"

    printf '%s\n' \
        'team_id = "team-0123456789abcdef"' \
        'cli_auth_credentials_store = "file"' \
        'account_id = "account-fixture"' > "$negative_fixture"
    expect_scan_status "$negative_fixture" 0 "official-team-id/file-store"

    printf '%s\n%s\n' '# codex-switch synthetic test fixture' "$private_header" > "$marked_fixture"
    expect_scan_status "$marked_fixture" 1 "marked-private-key"
}

make_signed_fixture() {
    local target_path="$1"
    local system_executable="$2"
    local expected_path="$3"

    if ! install -m 0755 "$system_executable" "$target_path"; then
        echo "could not create signed lifecycle fixture from: $system_executable" >&2
        return 1
    fi
    if ! "$codesign_path" --force --sign - "$target_path" >/dev/null 2>&1; then
        echo "could not ad-hoc sign lifecycle fixture: $target_path" >&2
        return 1
    fi
    if ! "$codesign_path" --verify --strict "$target_path" >/dev/null 2>&1; then
        echo "could not verify lifecycle fixture: $target_path" >&2
        return 1
    fi
    cp "$target_path" "$expected_path"
}

run_install_lifecycle_tests() {
    local lifecycle_root="$check_temp_root/install-fixtures"
    local source_directory="$lifecycle_root/source"
    local binary_directory="$lifecycle_root/bin"
    local source_binary="$source_directory/codex-switch"
    local destination="$binary_directory/codex-switch"
    local invalid_source="$source_directory/not-executable"
    local symlink_destination="$binary_directory/symlink-target"
    local expected_v1="$lifecycle_root/expected-v1"
    local expected_v2="$lifecycle_root/expected-v2"
    local expected_v3="$lifecycle_root/expected-v3"
    local move_failure_directory="$lifecycle_root/move-failure-bin"
    local move_failure_counter="$lifecycle_root/mv-counter"
    local move_failure_wrapper="$move_failure_directory/mv"
    local post_backup_term_directory="$lifecycle_root/post-backup-term-bin"
    local post_backup_term_counter="$lifecycle_root/post-backup-term-counter"
    local post_backup_term_wrapper="$post_backup_term_directory/mv"
    local post_backup_term_output="$lifecycle_root/post-backup-term-output"
    local term_failure_directory="$lifecycle_root/term-failure-bin"
    local term_failure_counter="$lifecycle_root/term-counter"
    local term_failure_wrapper="$term_failure_directory/mv"
    local term_output="$lifecycle_root/term-output"
    local lock_directory="$binary_directory/.codex-switch.lock"
    local system_v1="/usr/bin/true"
    local system_v2="/usr/bin/false"
    local system_v3="/bin/echo"
    local system_v4="/usr/bin/printf"
    local backup_count
    local removed_count
    local lifecycle_status
    local backup_file
    local removed_file

    for system_executable in "$system_v1" "$system_v2" "$system_v3" "$system_v4"; do
        if [[ ! -f "$system_executable" || ! -x "$system_executable" ]]; then
            echo "signed lifecycle fixture executable is unavailable: $system_executable" >&2
            return 1
        fi
    done

    mkdir -m 700 "$lifecycle_root" "$source_directory" "$binary_directory"
    make_signed_fixture "$source_binary" "$system_v1" "$expected_v1"

    if ! "$script_directory/install.sh" \
        --source "$source_binary" \
        --destination "$destination" >/dev/null; then
        echo "fresh install lifecycle test failed" >&2
        return 1
    fi
    if ! cmp -s "$destination" "$expected_v1"; then
        echo "fresh install did not place the requested binary" >&2
        return 1
    fi

    make_signed_fixture "$source_binary" "$system_v2" "$expected_v2"
    if ! "$script_directory/install.sh" \
        --source "$source_binary" \
        --destination "$destination" >/dev/null; then
        echo "update lifecycle test failed" >&2
        return 1
    fi
    if ! cmp -s "$destination" "$expected_v2"; then
        echo "update lifecycle test left the wrong binary" >&2
        return 1
    fi
    backup_count="$(find "$binary_directory" -mindepth 1 -maxdepth 1 -type d -name '.codex-switch-backup.*' | wc -l | tr -d ' ')"
    if [[ "$backup_count" -ne 1 ]]; then
        echo "expected one non-overwritten install backup, found $backup_count" >&2
        return 1
    fi
    backup_file="$(find "$binary_directory" -mindepth 2 -maxdepth 2 -type f -name 'codex-switch' | sort | sed -n '1p')"
    if [[ -z "$backup_file" ]] || ! cmp -s "$backup_file" "$expected_v1"; then
        echo "the first install backup does not preserve the previous binary" >&2
        return 1
    fi

    make_signed_fixture "$source_binary" "$system_v3" "$expected_v3"
    if ! "$script_directory/install.sh" \
        "$source_binary" \
        "$destination" >/dev/null; then
        echo "second update lifecycle test failed" >&2
        return 1
    fi
    backup_count="$(find "$binary_directory" -mindepth 1 -maxdepth 1 -type d -name '.codex-switch-backup.*' | wc -l | tr -d ' ')"
    if [[ "$backup_count" -ne 2 ]]; then
        echo "expected two non-overwritten install backups, found $backup_count" >&2
        return 1
    fi
    if ! cmp -s "$destination" "$expected_v3"; then
        echo "second update lifecycle test left the wrong binary" >&2
        return 1
    fi

    mkdir -m 700 "$move_failure_directory"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'counter_file="${MV_FAILURE_COUNTER:?}"' \
        'if [[ -f "$counter_file" ]]; then' \
        '    count="$(cat "$counter_file")"' \
        'else' \
        '    count=0' \
        'fi' \
        'count=$((count + 1))' \
        'printf "%s\\n" "$count" > "$counter_file"' \
        'if [[ "$count" -eq 2 ]]; then' \
        '    exit 1' \
        'fi' \
        'exec /bin/mv "$@"' > "$move_failure_wrapper"
    chmod 755 "$move_failure_wrapper"
    make_signed_fixture "$source_binary" "$system_v4" "$lifecycle_root/expected-v4"
    if PATH="$move_failure_directory:$PATH" \
        MV_FAILURE_COUNTER="$move_failure_counter" \
        "$script_directory/install.sh" \
        --source "$source_binary" \
        --destination "$destination" >/dev/null 2>&1; then
        echo "post-backup move failure unexpectedly succeeded" >&2
        return 1
    else
        lifecycle_status=$?
        if [[ "$lifecycle_status" -ne 1 ]]; then
            echo "post-backup move failure returned status $lifecycle_status" >&2
            return 1
        fi
    fi
    if ! cmp -s "$destination" "$expected_v3"; then
        echo "post-backup move failure did not restore the previous binary" >&2
        return 1
    fi
    backup_count="$(find "$binary_directory" -mindepth 1 -maxdepth 1 -type d -name '.codex-switch-backup.*' | wc -l | tr -d ' ')"
    if [[ "$backup_count" -ne 2 ]]; then
        echo "post-backup move failure left a backup directory" >&2
        return 1
    fi
    if [[ "$(find "$binary_directory" -mindepth 1 -maxdepth 1 -type d -name '.codex-switch-install.*' | wc -l | tr -d ' ')" -ne 0 ]]; then
        echo "post-backup move failure left a staging directory" >&2
        return 1
    fi

    mkdir -m 700 "$post_backup_term_directory"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'counter_file="${MV_POST_BACKUP_TERM_COUNTER:?}"' \
        'if [[ -f "$counter_file" ]]; then' \
        '    count="$(cat "$counter_file")"' \
        'else' \
        '    count=0' \
        'fi' \
        'count=$((count + 1))' \
        'printf "%s\\n" "$count" > "$counter_file"' \
        'if [[ "$count" -eq 1 ]]; then' \
        '    /bin/mv "$@"' \
        '    kill -TERM "$PPID"' \
        '    exit 143' \
        'fi' \
        'exec /bin/mv "$@"' > "$post_backup_term_wrapper"
    chmod 755 "$post_backup_term_wrapper"
    make_signed_fixture "$source_binary" "$system_v4" "$lifecycle_root/expected-post-backup-term"
    if PATH="$post_backup_term_directory:$PATH" \
        MV_POST_BACKUP_TERM_COUNTER="$post_backup_term_counter" \
        "$script_directory/install.sh" \
        --source "$source_binary" \
        --destination "$destination" > "$post_backup_term_output" 2>&1; then
        echo "SIGTERM after backup move unexpectedly succeeded" >&2
        return 1
    else
        lifecycle_status=$?
        if [[ "$lifecycle_status" -ne 143 ]]; then
            echo "SIGTERM after backup move returned status $lifecycle_status" >&2
            return 1
        fi
    fi
    if rg --pcre2 -q -- 'Installed:' "$post_backup_term_output"; then
        echo "SIGTERM after backup move reported success" >&2
        return 1
    fi
    if ! cmp -s "$destination" "$expected_v3"; then
        echo "SIGTERM after backup move did not restore the previous binary" >&2
        return 1
    fi
    backup_count="$(find "$binary_directory" -mindepth 1 -maxdepth 1 -type d -name '.codex-switch-backup.*' | wc -l | tr -d ' ')"
    if [[ "$backup_count" -ne 2 ]]; then
        echo "SIGTERM after backup move changed the backup set" >&2
        return 1
    fi
    if [[ "$(find "$binary_directory" -mindepth 1 -maxdepth 1 -type d -name '.codex-switch-install.*' | wc -l | tr -d ' ')" -ne 0 || -d "$lock_directory" ]]; then
        echo "SIGTERM after backup move left transaction state behind" >&2
        return 1
    fi

    mkdir -m 700 "$term_failure_directory"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'counter_file="${MV_TERM_COUNTER:?}"' \
        'if [[ -f "$counter_file" ]]; then' \
        '    count="$(cat "$counter_file")"' \
        'else' \
        '    count=0' \
        'fi' \
        'count=$((count + 1))' \
        'printf "%s\\n" "$count" > "$counter_file"' \
        'if [[ "$count" -eq 2 ]]; then' \
        '    kill -TERM "$PPID"' \
        '    exit 143' \
        'fi' \
        'exec /bin/mv "$@"' > "$term_failure_wrapper"
    chmod 755 "$term_failure_wrapper"
    make_signed_fixture "$source_binary" "$system_v4" "$lifecycle_root/expected-term"
    if PATH="$term_failure_directory:$PATH" \
        MV_TERM_COUNTER="$term_failure_counter" \
        "$script_directory/install.sh" \
        --source "$source_binary" \
        --destination "$destination" > "$term_output" 2>&1; then
        echo "SIGTERM during install unexpectedly succeeded" >&2
        return 1
    else
        lifecycle_status=$?
        if [[ "$lifecycle_status" -ne 143 ]]; then
            echo "SIGTERM during install returned status $lifecycle_status" >&2
            return 1
        fi
    fi
    if rg --pcre2 -q -- 'Installed:' "$term_output"; then
        echo "SIGTERM during install reported success" >&2
        return 1
    fi
    if ! cmp -s "$destination" "$expected_v3"; then
        echo "SIGTERM during install did not restore the previous binary" >&2
        return 1
    fi
    backup_count="$(find "$binary_directory" -mindepth 1 -maxdepth 1 -type d -name '.codex-switch-backup.*' | wc -l | tr -d ' ')"
    if [[ "$backup_count" -ne 2 ]]; then
        echo "SIGTERM during install changed the backup set" >&2
        return 1
    fi
    if [[ "$(find "$binary_directory" -mindepth 1 -maxdepth 1 -type d -name '.codex-switch-install.*' | wc -l | tr -d ' ')" -ne 0 || -d "$lock_directory" ]]; then
        echo "SIGTERM during install left transaction state behind" >&2
        return 1
    fi

    printf '%s\n' 'not-executable' > "$invalid_source"
    chmod 644 "$invalid_source"
    if "$script_directory/install.sh" \
        --source "$invalid_source" \
        --destination "$destination" >/dev/null 2>&1; then
        echo "invalid source lifecycle test unexpectedly succeeded" >&2
        return 1
    else
        lifecycle_status=$?
        if [[ "$lifecycle_status" -ne 1 ]]; then
            echo "invalid source lifecycle test returned status $lifecycle_status" >&2
            return 1
        fi
    fi
    if ! cmp -s "$destination" "$expected_v3"; then
        echo "failed install changed the previous binary" >&2
        return 1
    fi

    ln -s "$destination" "$symlink_destination"
    if "$script_directory/install.sh" \
        --source "$source_binary" \
        --destination "$symlink_destination" >/dev/null 2>&1; then
        echo "symlink destination lifecycle test unexpectedly succeeded" >&2
        return 1
    else
        lifecycle_status=$?
        if [[ "$lifecycle_status" -ne 1 ]]; then
            echo "symlink destination lifecycle test returned status $lifecycle_status" >&2
            return 1
        fi
    fi
    if [[ ! -L "$symlink_destination" ]]; then
        echo "symlink destination lifecycle test removed the user symlink" >&2
        return 1
    fi

    mkdir "$lock_directory"
    if "$script_directory/install.sh" \
        --source "$source_binary" \
        --destination "$destination" >/dev/null 2>&1; then
        echo "install did not honor the shared target lock" >&2
        return 1
    else
        lifecycle_status=$?
        if [[ "$lifecycle_status" -ne 1 ]]; then
            echo "locked install returned status $lifecycle_status" >&2
            return 1
        fi
    fi
    if "$script_directory/uninstall.sh" \
        --yes \
        --destination "$destination" >/dev/null 2>&1; then
        echo "uninstall did not honor the shared target lock" >&2
        return 1
    else
        lifecycle_status=$?
        if [[ "$lifecycle_status" -ne 1 ]]; then
            echo "locked uninstall returned status $lifecycle_status" >&2
            return 1
        fi
    fi
    rmdir "$lock_directory"

    printf '%s\n' 'auth-fixture' > "$lifecycle_root/auth.json"
    printf '%s\n' 'state-fixture' > "$lifecycle_root/state-v2.json"
    if ! "$script_directory/uninstall.sh" \
        --yes \
        --destination "$destination" >/dev/null; then
        echo "uninstall lifecycle test failed" >&2
        return 1
    fi
    if [[ -e "$destination" || -L "$destination" ]]; then
        echo "uninstall lifecycle test left the CLI at the destination" >&2
        return 1
    fi
    removed_count="$(find "$binary_directory" -mindepth 1 -maxdepth 1 -type d -name '.codex-switch-removed.*' | wc -l | tr -d ' ')"
    if [[ "$removed_count" -ne 1 ]]; then
        echo "uninstall did not leave one recoverable binary backup" >&2
        return 1
    fi
    removed_file="$(find "$binary_directory" -mindepth 2 -maxdepth 2 -type f -name 'codex-switch' | sort | tail -n 1)"
    if [[ -z "$removed_file" ]] || ! cmp -s "$removed_file" "$expected_v3"; then
        echo "uninstall backup does not preserve the removed binary" >&2
        return 1
    fi
    if [[ ! -f "$lifecycle_root/auth.json" || ! -f "$lifecycle_root/state-v2.json" ]]; then
        echo "uninstall lifecycle test changed unrelated state" >&2
        return 1
    fi
}

if collect_public_source_files; then
    :
else
    collect_status=$?
    echo "publication source enumeration failed with status $collect_status" >&2
    exit "$collect_status"
fi
if scan_source_paths "${public_files[@]}"; then
    :
else
    scan_status=$?
    if [[ "$scan_status" -eq 1 ]]; then
        echo "publication source scan found a prohibited value or artifact" >&2
    else
        echo "publication source scan failed with status $scan_status" >&2
    fi
    exit "$scan_status"
fi

run_source_scan_behavior_tests
run_install_lifecycle_tests

echo "Distribution checks passed"
exit 0
