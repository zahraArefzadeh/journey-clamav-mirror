#!/usr/bin/env bash
# Keep the public mirror bounded, credential-free, and dependent on ClamAV's
# supported downloader and signature verifier rather than direct CDN requests.
set -Eeuo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly workflow="$repository_root/.github/workflows/update-definitions.yml"
readonly publisher="$repository_root/scripts/publish-definitions.sh"
readonly readme="$repository_root/README.md"

for required_file in "$workflow" "$publisher" "$readme"; do
  [[ -f "$required_file" ]] && [[ ! -L "$required_file" ]] || exit 1
done

bash -n "$publisher"
grep --fixed-strings --line-regexp --quiet '    runs-on: ubuntu-24.04' "$workflow"
grep --fixed-strings --line-regexp --quiet '    timeout-minutes: 10' "$workflow"
grep --fixed-strings --line-regexp --quiet '  contents: write' "$workflow"
grep --fixed-strings --line-regexp --quiet '  workflow_dispatch:' "$workflow"
grep --fixed-strings --line-regexp --quiet '    - cron: "17 */12 * * *"' "$workflow"
grep --fixed-strings --quiet 'freshclam' "$publisher"
grep --fixed-strings --quiet 'sigtool' "$publisher"
grep --fixed-strings --quiet -- '--draft' "$publisher"
grep --fixed-strings --quiet 'sha256sum --check --strict' "$publisher"
grep --fixed-strings --quiet 'retained_release_count=8' "$publisher"
grep --fixed-strings --quiet 'No application source, production data, credentials' "$readme"

if grep --quiet --extended-regexp \
  '(secrets\.|BEGIN (RSA|OPENSSH|EC|AGE) PRIVATE KEY|AGE-SECRET-KEY-|postgresql://|ssh-ed25519 )' \
  "$workflow" "$publisher" "$readme"; then
  printf 'The public mirror contains a forbidden private value or secret reference.\n' >&2
  exit 1
fi

printf 'Public ClamAV mirror contract passed.\n'
