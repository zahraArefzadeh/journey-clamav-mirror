#!/usr/bin/env bash
# Fetch ClamAV databases through FreshClam, verify their vendor signatures,
# and build one bounded GitHub Pages artifact for atomic publication.
set -Eeuo pipefail
umask 077

readonly expected_repository="zahraArefzadeh/journey-clamav-mirror"
readonly release_prefix="definitions-"
readonly runner_directory="${RUNNER_TEMP:-}"
readonly repository="${GITHUB_REPOSITORY:-}"
readonly pages_directory="${PAGES_SITE_DIRECTORY:-}"

if [[ "$repository" != "$expected_repository" ]] ||
  [[ -z "$runner_directory" ]] || [[ ! -d "$runner_directory" ]] ||
  [[ -z "$pages_directory" ]] || [[ "$pages_directory" != "$runner_directory/"* ]] ||
  [[ -e "$pages_directory" ]] || [[ -L "$pages_directory" ]] ||
  [[ "$(git rev-parse --show-toplevel)" != "$PWD" ]] ||
  [[ -n "$(git status --porcelain)" ]]; then
  printf 'The ClamAV publisher requires its clean, expected GitHub repository and runner output path.\n' >&2
  exit 78
fi

for required_command in freshclam git install sha256sum sigtool stat sudo; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Required publisher command is unavailable: %s\n' "$required_command" >&2
    exit 69
  fi
done
unset required_command

readonly work_directory="$(mktemp -d "$runner_directory/clamav-mirror.XXXXXXXX")"
readonly database_directory="$work_directory/database"

cleanup() {
  find "$work_directory" -depth -delete
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

install -d -m 0700 "$database_directory"
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

readonly published_database_directory="$pages_directory/$release_tag"
install -d -m 0755 "$pages_directory" "$published_database_directory"
for asset in main.cvd daily.cvd bytecode.cvd SHA256SUMS; do
  install -m 0644 "$database_directory/$asset" "$published_database_directory/$asset"
done
{
  printf 'clamav-mirror/v1\n'
  printf 'tag\t%s\n' "$release_tag"
  manifest_line main.cvd "$main_version"
  manifest_line daily.cvd "$daily_version"
  manifest_line bytecode.cvd "$bytecode_version"
} >"$pages_directory/current.txt"
chmod 0644 "$pages_directory/current.txt"

if [[ "$(find "$pages_directory" -type f -printf '%s\n' | awk '{total += $1} END {print total + 0}')" -gt 250000000 ]] ||
  find "$pages_directory" -type l -print -quit | grep --quiet .; then
  printf 'The ClamAV Pages artifact is too large or contains a symbolic link.\n' >&2
  exit 65
fi

printf 'Built verified ClamAV Pages artifact: %s\n' "$release_tag"
