#!/usr/bin/env bash
# Fetch ClamAV databases through FreshClam, verify their vendor signatures,
# publish one immutable release, then atomically advance the public manifest.
set -Eeuo pipefail
umask 077

readonly expected_repository="zahraArefzadeh/journey-clamav-mirror"
readonly release_prefix="definitions-"
readonly retained_release_count=8
readonly runner_directory="${RUNNER_TEMP:-}"
readonly repository="${GITHUB_REPOSITORY:-}"

if [[ "$repository" != "$expected_repository" ]] ||
  [[ -z "$runner_directory" ]] || [[ ! -d "$runner_directory" ]] ||
  [[ "$(git rev-parse --show-toplevel)" != "$PWD" ]] ||
  [[ -n "$(git status --porcelain)" ]]; then
  printf 'The ClamAV publisher requires its clean, expected GitHub repository.\n' >&2
  exit 78
fi

for required_command in freshclam gh git install jq sha256sum sigtool stat sudo; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Required publisher command is unavailable: %s\n' "$required_command" >&2
    exit 69
  fi
done
unset required_command

readonly work_directory="$(mktemp -d "$runner_directory/clamav-mirror.XXXXXXXX")"
readonly database_directory="$work_directory/database"
readonly existing_directory="$work_directory/existing"

cleanup() {
  find "$work_directory" -depth -delete
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

install -d -m 0700 "$database_directory" "$existing_directory"
sudo systemctl stop clamav-freshclam.service >/dev/null 2>&1 || true
sudo freshclam --stdout

database_version() {
  local database="$1"
  local version

  version="$(sudo sigtool --info "$database" | awk -F': ' '$1 == "Version" {print $2}')"
  if [[ ! "$version" =~ ^[0-9]+$ ]]; then
    printf 'A ClamAV database version is malformed: %s\n' "$database" >&2
    return 65
  fi
  printf '%s\n' "$version"
}

verify_and_stage_database() {
  local name="$1"
  local minimum_bytes="$2"
  local maximum_bytes="$3"
  local source="/var/lib/clamav/$name"
  local bytes

  if [[ ! -f "$source" ]] || [[ -L "$source" ]]; then
    printf 'FreshClam did not provide the expected database: %s\n' "$name" >&2
    return 65
  fi
  bytes="$(sudo stat --format='%s' "$source")"
  if [[ ! "$bytes" =~ ^[0-9]+$ ]] ||
    ((bytes < minimum_bytes || bytes > maximum_bytes)) ||
    ! sudo sigtool --info "$source" | grep --fixed-strings --line-regexp --quiet 'Verification OK.'; then
    printf 'ClamAV database verification failed: %s\n' "$name" >&2
    return 65
  fi
  sudo install -m 0644 -o "$(id -u)" -g "$(id -g)" "$source" "$database_directory/$name"
}

verify_and_stage_database main.cvd 10000000 300000000
verify_and_stage_database daily.cvd 1000000 300000000
verify_and_stage_database bytecode.cvd 10000 50000000

readonly main_version="$(database_version "$database_directory/main.cvd")"
readonly daily_version="$(database_version "$database_directory/daily.cvd")"
readonly bytecode_version="$(database_version "$database_directory/bytecode.cvd")"

(
  cd "$database_directory"
  sha256sum main.cvd daily.cvd bytecode.cvd >SHA256SUMS
)
readonly release_digest="$(sha256sum "$database_directory/SHA256SUMS" | cut -d' ' -f1)"
readonly release_tag="${release_prefix}m${main_version}-d${daily_version}-b${bytecode_version}-${release_digest:0:12}"
if [[ ! "$release_tag" =~ ^definitions-m[0-9]+-d[0-9]+-b[0-9]+-[0-9a-f]{12}$ ]]; then
  printf 'The derived ClamAV release tag is malformed.\n' >&2
  exit 65
fi

manifest_line() {
  local name="$1"
  local version="$2"
  local checksum bytes

  checksum="$(sha256sum "$database_directory/$name" | cut -d' ' -f1)"
  bytes="$(stat --format='%s' "$database_directory/$name")"
  printf '%s\t%s\t%s\t%s\n' "$name" "$checksum" "$bytes" "$version"
}

readonly candidate_manifest="$work_directory/current.txt"
{
  printf 'clamav-mirror/v1\n'
  printf 'tag\t%s\n' "$release_tag"
  manifest_line main.cvd "$main_version"
  manifest_line daily.cvd "$daily_version"
  manifest_line bytecode.cvd "$bytecode_version"
} >"$candidate_manifest"

verify_existing_release() {
  gh release download "$release_tag" \
    --dir "$existing_directory" \
    --pattern main.cvd \
    --pattern daily.cvd \
    --pattern bytecode.cvd \
    --pattern SHA256SUMS
  (
    cd "$existing_directory"
    sha256sum --check --strict SHA256SUMS
  )
  for asset in main.cvd daily.cvd bytecode.cvd SHA256SUMS; do
    cmp --silent "$database_directory/$asset" "$existing_directory/$asset" || {
      printf 'An immutable ClamAV release asset differs: %s\n' "$asset" >&2
      return 65
    }
  done
}

release_state="$(gh release view "$release_tag" --json isDraft --jq '.isDraft' 2>/dev/null || true)"
case "$release_state" in
  false)
    verify_existing_release
    ;;
  true)
    gh release delete "$release_tag" --cleanup-tag --yes
    ;;
  "")
    ;;
  *)
    printf 'The existing ClamAV release has an unexpected state.\n' >&2
    exit 65
    ;;
esac

if [[ "$release_state" != "false" ]]; then
  gh release create "$release_tag" \
    --draft \
    --latest=false \
    --title "ClamAV definitions ${daily_version}" \
    --notes "Public ClamAV databases fetched with FreshClam and verified with sigtool."
  gh release upload "$release_tag" \
    "$database_directory/main.cvd" \
    "$database_directory/daily.cvd" \
    "$database_directory/bytecode.cvd" \
    "$database_directory/SHA256SUMS"
  gh release edit "$release_tag" --draft=false --latest=false
fi

install -m 0644 "$candidate_manifest" current.txt
if ! git diff --quiet -- current.txt || [[ -n "$(git ls-files --others --exclude-standard -- current.txt)" ]]; then
  git config user.name 'journey-clamav-mirror[bot]'
  git config user.email 'journey-clamav-mirror[bot]@users.noreply.github.com'
  git add -- current.txt
  git commit -m "chore: advance verified ClamAV definitions"
  git push origin HEAD:main
fi

mapfile -t obsolete_releases < <(
  gh release list --limit 100 --json tagName,createdAt,isDraft \
    --jq '.[] | select(.isDraft == false) | [.createdAt, .tagName] | @tsv' |
    sort --reverse |
    awk -v prefix="$release_prefix" -v keep="$retained_release_count" \
      '$2 ~ ("^" prefix) {seen += 1; if (seen > keep) print $2}'
)
for obsolete_release in "${obsolete_releases[@]}"; do
  if [[ ! "$obsolete_release" =~ ^definitions-m[0-9]+-d[0-9]+-b[0-9]+-[0-9a-f]{12}$ ]] ||
    [[ "$obsolete_release" == "$release_tag" ]]; then
    printf 'Refusing to remove an unexpected ClamAV release.\n' >&2
    exit 65
  fi
  gh release delete "$obsolete_release" --cleanup-tag --yes
done

printf 'Published verified ClamAV databases: %s\n' "$release_tag"
