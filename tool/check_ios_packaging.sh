#!/usr/bin/env bash
# Builds the iOS plugin the way host apps consume it: a throwaway app with
# Swift Package Manager, the same app with CocoaPods, and the example app with
# Swift Package Manager. macOS with Xcode only; no signing, devices or uploads.
set -euo pipefail
sdk_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "iOS packaging check failed: $*" >&2; exit 1; }

# Asserts the plugin's privacy manifest shipped inside the built app.
expect_privacy_manifest() {
  local app="$1/build/ios/iphonesimulator/Runner.app"
  find "$app" -path '*protodesk_chat*' -name PrivacyInfo.xcprivacy | grep -q . ||
    fail "$2: protodesk_chat privacy manifest missing from Runner.app"
}

# Host apps: one throwaway app built with each package manager.
flutter create --platforms=ios --project-name packaging_probe "$work/probe" >/dev/null
python3 - "$work/probe/pubspec.yaml" "$sdk_root" <<'PY'
import pathlib, sys
pubspec, sdk = pathlib.Path(sys.argv[1]), sys.argv[2]
text = pubspec.read_text()
for old, new in [
    ('dependencies:\n  flutter:\n    sdk: flutter\n',
     f'dependencies:\n  flutter:\n    sdk: flutter\n  protodesk_chat:\n    path: {sdk}\n'),
    ('\nflutter:\n', '\nflutter:\n  config:\n    enable-swift-package-manager: SPM_MODE\n'),
]:
    assert old in text, f'unexpected flutter create pubspec: {old!r}'
    text = text.replace(old, new, 1)
pubspec.write_text(text)
PY
for mode in true false; do
  sed -i '' "s/enable-swift-package-manager: .*/enable-swift-package-manager: $mode/" "$work/probe/pubspec.yaml"
  (cd "$work/probe" && flutter clean >/dev/null && flutter pub get >/dev/null &&
    flutter build ios --simulator --debug --no-codesign) || fail "host app build (SwiftPM=$mode)"
  expect_privacy_manifest "$work/probe" "host app (SwiftPM=$mode)"
  if [[ $mode == true ]]; then
    ! grep -q '^  - protodesk_chat' "$work/probe/ios/Podfile.lock" 2>/dev/null ||
      fail 'SwiftPM host app resolved protodesk_chat through CocoaPods'
  else
    grep -q '^  - protodesk_chat' "$work/probe/ios/Podfile.lock" ||
      fail 'CocoaPods host app did not install the protodesk_chat pod'
  fi
done

# Example app (SwiftPM). Flutter's migration may add the plugin under
# development as a local package override; that override breaks resolution
# whenever the checkout folder is not named protodesk_chat (see
# docs/ios-swift-package-manager.md), so its return must fail loudly.
(cd "$sdk_root/example" && flutter pub get >/dev/null &&
  flutter build ios --simulator --debug --no-codesign) || fail 'example app build (SwiftPM)'
! grep -q 'path = ../../ios/protodesk_chat;' "$sdk_root/example/ios/Runner.xcodeproj/project.pbxproj" ||
  fail 'Flutter re-added the example local package override; remove it from Runner.xcodeproj'
expect_privacy_manifest "$sdk_root/example" 'example app'
echo 'iOS packaging checks passed (SwiftPM and CocoaPods host apps, SwiftPM example).'
