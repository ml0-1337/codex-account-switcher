#!/usr/bin/env bash
set -euo pipefail

script_directory="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(CDPATH= cd -- "$script_directory/.." && pwd)"
release_script="$script_directory/release.sh"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/codex-switch-release-check.XXXXXX")"
trap 'rm -rf -- "$check_directory"' EXIT

fail() {
    echo "Release check failed: $*" >&2
    exit 1
}

expect_failure() {
    local expected_message="$1"
    shift
    if "$@" > "$check_directory/failure.log" 2>&1; then
        fail "command unexpectedly succeeded"
    fi
    if ! rg -q -- "$expected_message" "$check_directory/failure.log"; then
        cat "$check_directory/failure.log" >&2
        fail "command failed for an unexpected reason"
    fi
}

# These executables contain no application or account code, and are never run.
printf 'int main(void) { return 0; }\n' > "$check_directory/fixture.c"
for architecture in arm64 x86_64; do
    binary="$check_directory/fixture-$architecture"
    xcrun clang -arch "$architecture" -mmacosx-version-min=14.0 \
        "$check_directory/fixture.c" -o "$binary"
    codesign --force --sign - "$binary" > "$check_directory/signing.log" 2>&1
    "$release_script" package 1.2.3 "$binary" "$check_directory/assets"

    archive="$check_directory/assets/codex-switch-1.2.3-macos-$architecture.tar.gz"
    mkdir "$check_directory/unpacked-$architecture"
    tar -xzf "$archive" -C "$check_directory/unpacked-$architecture"
    cmp "$binary" "$check_directory/unpacked-$architecture/codex-switch"
    cmp "$repository_root/LICENSE" "$check_directory/unpacked-$architecture/LICENSE"
    test -x "$check_directory/unpacked-$architecture/codex-switch"
    codesign --verify --strict "$check_directory/unpacked-$architecture/codex-switch"
    printf 'LICENSE\ncodex-switch\n' > "$check_directory/expected-members"
    tar -tzf "$archive" | LC_ALL=C sort > "$check_directory/actual-members"
    cmp "$check_directory/expected-members" "$check_directory/actual-members"

    original_digest="$(shasum -a 256 "$archive")"
    expect_failure 'already exists' \
        "$release_script" package 1.2.3 "$binary" "$check_directory/assets"
    test "$(shasum -a 256 "$archive")" = "$original_digest"
done

for invalid_version in 01.2.3 1.2 v1.2.3 '../1.2.3' '1.2.3;exit'; do
    expect_failure 'version must be' \
        "$release_script" package "$invalid_version" "$binary" "$check_directory/rejected"
done
test ! -e "$check_directory/rejected"

ln -s "$binary" "$check_directory/symlink"
expect_failure 'regular executable' \
    "$release_script" package 1.2.3 "$check_directory/symlink" "$check_directory/rejected"
expect_failure 'regular executable' \
    "$release_script" package 1.2.3 "$check_directory/missing" "$check_directory/rejected"
printf '#!/bin/sh\nexit 0\n' > "$check_directory/script"
chmod +x "$check_directory/script"
expect_failure 'Mach-O' \
    "$release_script" package 1.2.3 "$check_directory/script" "$check_directory/rejected"
xcrun lipo -create "$check_directory/fixture-arm64" "$check_directory/fixture-x86_64" \
    -output "$check_directory/universal"
expect_failure 'single arm64 or x86_64' \
    "$release_script" package 1.2.3 "$check_directory/universal" "$check_directory/rejected"
cp "$binary" "$check_directory/unsigned"
codesign --remove-signature "$check_directory/unsigned"
expect_failure 'not signed|not signed at all|signature' \
    "$release_script" package 1.2.3 "$check_directory/unsigned" "$check_directory/rejected"

"$release_script" formula 1.2.3 example/codex-account-switcher "$check_directory/assets" \
    > "$check_directory/codex-switch.rb"
ruby -c "$check_directory/codex-switch.rb"
for architecture in arm64 x86_64; do
    archive_name="codex-switch-1.2.3-macos-$architecture.tar.gz"
    digest="$(shasum -a 256 "$check_directory/assets/$archive_name" | awk '{print $1}')"
    rg -Fq "https://github.com/example/codex-account-switcher/releases/download/v1.2.3/$archive_name" \
        "$check_directory/codex-switch.rb"
    rg -Fq "$digest" "$check_directory/codex-switch.rb"
done
expect_failure 'repository must be' \
    "$release_script" formula 1.2.3 'example/repo"' "$check_directory/assets"
expect_failure 'missing release archive' \
    "$release_script" formula 2.0.0 example/codex-account-switcher "$check_directory/assets"

echo "Release checks passed"
