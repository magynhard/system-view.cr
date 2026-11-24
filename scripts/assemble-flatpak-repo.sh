#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 5 ]]; then
    echo "Usage: $0 X86_REPO ARM_REPO OUTPUT_DIR GPG_HOME KEY_FINGERPRINT" >&2
    exit 2
fi

x86_repo="$1"
arm_repo="$2"
output="$3"
gpg_home="$4"
key="$5"
app_id=de.magynhard.SystemView
branch=master

if [[ ! "$key" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "Expected a full OpenPGP fingerprint" >&2
    exit 2
fi
if [[ -e "$output" ]]; then
    echo "Output must not already exist: $output" >&2
    exit 2
fi

for entry in "x86_64:$x86_repo" "aarch64:$arm_repo"; do
    arch="${entry%%:*}"
    source_repo="${entry#*:}"
    ref="app/$app_id/$arch/$branch"
    test -f "$source_repo/config"
    ostree --repo="$source_repo" rev-parse "$ref" > /dev/null
done

mkdir -p "$output"
repo="$output/repo"
ostree --repo="$repo" init --mode=archive
ostree --repo="$repo" config set core.min-free-space-percent 0

for entry in "x86_64:$x86_repo" "aarch64:$arm_repo"; do
    arch="${entry%%:*}"
    source_repo="${entry#*:}"
    ref="app/$app_id/$arch/$branch"
    expected="$(ostree --repo="$source_repo" rev-parse "$ref")"
    ostree --repo="$repo" pull-local --untrusted "$source_repo" "$ref"
    actual="$(ostree --repo="$repo" rev-parse "$ref")"
    test "$actual" = "$expected"
    ostree --repo="$repo" gpg-sign --gpg-homedir="$gpg_home" "$actual" "$key"
done

flatpak build-update-repo --gpg-homedir="$gpg_home" --gpg-sign="$key" \
    --title="System View" --default-branch="$branch" "$repo"

gpg --batch --homedir "$gpg_home" --export "$key" > "$output/public-key.gpg"
test -s "$output/public-key.gpg"
ostree --repo="$repo" remote add --gpg-import="$output/public-key.gpg" \
    verification "file://$(realpath "$repo")"
for arch in x86_64 aarch64; do
    ostree --repo="$repo" show --gpg-verify-remote=verification \
        "app/$app_id/$arch/$branch" > /dev/null
    ostree --repo="$repo" show --gpg-verify-remote=verification \
        "appstream2/$arch" > /dev/null
done
ostree --repo="$repo" remote delete verification

encoded_key="$(base64 -w 0 "$output/public-key.gpg")"
cat > "$output/$app_id.flatpakref" <<EOF
[Flatpak Ref]
Name=$app_id
Branch=$branch
Title=System View
Url=https://flatpak.magynhard.de/repo/
SuggestRemoteName=system-view
RuntimeRepo=https://flathub.org/repo/flathub.flatpakrepo
IsRuntime=false
GPGKey=$encoded_key
EOF
