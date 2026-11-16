#!/usr/bin/env bash
# Publish the exact files of the deployed Pages artifact as the assets of one GitHub release,
# so a host that cannot reach github.io can still download the same signed databases from
# github.com. Nothing is rebuilt here: the files come from the artifact that was already verified
# and deployed, and the host still verifies every database signature with FreshClam.
set -Eeuo pipefail
umask 077

readonly artifact_tar="${1:-}"
readonly tag="${EXPECTED_TAG:-}"
readonly repository="${GITHUB_REPOSITORY:-}"
readonly keep_releases=3

if [[ "$repository" != "zahraArefzadeh/journey-clamav-mirror" ]] ||
  [[ ! "$tag" =~ ^definitions-m[0-9]+-d[0-9]+-b[0-9]+-[0-9a-f]{12}$ ]] ||
  [[ ! -f "$artifact_tar" ]] || [[ -L "$artifact_tar" ]]; then
  printf 'The release publisher needs the expected repository, a valid tag and the Pages artifact.\n' >&2
  exit 78
fi

readonly work_directory="$(mktemp -d)"
cleanup() {
  find "$work_directory" -depth -delete
}
trap cleanup EXIT

tar --extract --file "$artifact_tar" --directory "$work_directory"
readonly source_directory="$work_directory/$tag"
for asset in main.cvd daily.cvd bytecode.cvd SHA256SUMS; do
  [[ -f "$source_directory/$asset" ]] && [[ ! -L "$source_directory/$asset" ]] || {
    printf 'A release asset is missing from the artifact: %s\n' "$asset" >&2
    exit 65
  }
done
[[ -f "$work_directory/current.txt" ]] && [[ ! -L "$work_directory/current.txt" ]] || {
  printf 'The manifest is missing from the artifact.\n' >&2
  exit 65
}
# The assets must match the hashes the manifest and SHA256SUMS state.
(cd "$source_directory" && sha256sum --check --strict --quiet SHA256SUMS)
awk -F '\t' -v expected="$tag" '$1 == "tag" && $2 == expected {found = 1} END {exit found ? 0 : 1}' \
  "$work_directory/current.txt"

if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
  printf 'Release %s already exists; nothing to publish.\n' "$tag"
else
  gh release create "$tag" --repo "$repository" --latest \
    --title "$tag" \
    --notes "ClamAV public signed databases. The host verifies every database signature with FreshClam." \
    "$source_directory/main.cvd" "$source_directory/daily.cvd" "$source_directory/bytecode.cvd" \
    "$source_directory/SHA256SUMS" "$work_directory/current.txt"
fi

# Keep only the newest releases; the manifest on the latest release names the files to fetch.
gh release list --repo "$repository" --limit 100 --json tagName --jq ".[$keep_releases:][].tagName" |
  while IFS= read -r old_tag; do
    gh release delete "$old_tag" --repo "$repository" --cleanup-tag --yes
  done
printf 'Published release assets for %s\n' "$tag"
