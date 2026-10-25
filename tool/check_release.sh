#!/usr/bin/env bash
# Run from any directory. Uses Flutter/Dart on PATH; no credentials or uploads.
set -euo pipefail
sdk_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$sdk_root"
flutter --version
flutter pub get
flutter analyze
flutter test
(cd example && flutter pub get && flutter analyze && flutter test)
(cd examples/push_adapters && flutter pub get && flutter analyze && flutter test)
if [[ "$(uname)" == Darwin ]] && command -v xcodebuild >/dev/null; then
  bash tool/check_ios_packaging.sh
else
  echo 'Skipping iOS packaging checks: macOS with Xcode required.'
fi
python3 -m unittest discover -s tool -p '*_test.py'
dart doc --validate-links --output doc/api
candidate_parent="$(mktemp -d)"
trap 'rm -rf "$candidate_parent"' EXIT
python3 tool/stage_release.py "$candidate_parent/package"
(cd "$candidate_parent/package" && flutter pub get && flutter pub publish --dry-run)
# Pub warnings/errors already fail the script. Missing approval must fail even if pub relaxes its validation.
test -s LICENSE || { echo 'Release blocked: approved LICENSE required.' >&2; exit 1; }
echo 'Local candidate checks passed. Publication/device acceptance remains a separate explicit step.'
