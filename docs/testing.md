# Flutter SDK test layers

## Local regression and golden tests

From the SDK root:

```sh
flutter pub get
flutter analyze
flutter test
```

The default suite includes real loopback HTTP/WebSocket protocol tests for both
anonymous and verified sessions: exchange, authenticated messages, realtime events,
server-drain reconnect with a fresh ticket, history and logout. Other tests inject
transports for failure/race coverage; none need production credentials.

`test/goldens/chat_screen_golden_test.dart` checks the messenger in light and dark themes,
English and Indonesian, large text, and phone and tablet layouts. The
`web_home_phone`, `web_messages_empty`, and `web_new_chat` fixtures exercise
the fresh-visitor screens at the 451 × 663 viewport used to inspect the
live website widget. These are Flutter renders with local fixture data.

Golden generation environment: Flutter **3.47.5**, Dart **3.13.4**, macOS arm64.
Golden tests are tagged `golden` and run only on macOS; Linux CI excludes them.
`test/goldens/flutter_test_config.dart` accepts up to 1% differing pixels, because
glyph anti-aliasing differs between macOS releases (the macOS 15 CI runner differs
from macOS 27 baselines by at most 0.5%). Real layout or color regressions exceed
that. A Flutter version change may still need a separately reviewed baseline
migration.
Tests load Inter from the bundled website font files and fallback fonts and MaterialIcons from the resolved Flutter SDK using
`.dart_tool/package_config.json`; there are no account-specific paths or
network fonts. macOS goldens use the system emoji font for language flags. Sizes, theme platform, locale, text scale and fixture content are
fixed; focus/caret and automatic read timers are excluded from screenshots.

After an intentional UI change:

```sh
flutter test test/goldens --update-goldens
flutter test test/goldens
```

Review the actual PNG changes before accepting them. Do not update baselines merely
to silence a failure. Ordinary runs must not use `--update-goldens`. Mismatch images
appear in a `failures/` directory beside the golden test and are ignored by Git.
Goldens check pixels; semantic/contrast/keyboard tests remain separate and necessary.

## Minimum Flutter version

CI analyzes the SDK and both examples and runs their non-golden tests on Flutter
3.38.1 (Dart 3.10.0). It also builds the Android debug APK and iOS simulator app
from `example/`. Flutter 3.38.0 bundles a Dart prerelease that cannot resolve
the SDK’s secure-storage dependency.

On an Apple silicon Mac with Xcode 27, Flutter 3.38.1’s universal simulator
build can fail while verifying architectures with `lipo`. To test the native
arm64 simulator build from `example/`, run:

```sh
mkdir -p build
printf '%s\n' 'ARCHS[sdk=iphonesimulator*] = arm64' \
  'IPHONEOS_DEPLOYMENT_TARGET[sdk=iphonesimulator*] = 15.0' > build/arm-simulator.xcconfig
XCODE_XCCONFIG_FILE="$PWD/build/arm-simulator.xcconfig" flutter build ios --simulator --debug
```

## Native integration harness

See the [Pixel 7a side-by-side comparison](android-website-comparison.md) for the website and native captures and the Android replay command.

From `example/`:

```sh
flutter pub get
flutter analyze
flutter test
flutter test integration_test/chat_native_test.dart -d <android-or-ios-device-id>
flutter test integration_test/protected_files_test.dart -d <physical-device-id>
```

The chat harness uses the actual `PlatformChatStorage` Keychain/Keystore adapter
and prebuilt chat UI. Managed attachments are disabled, and a test-only adapter
accepts their cleanup calls while rejecting unexpected file operations; this
isolates the outbox test from iOS Simulator's missing data-protection metadata.
The separate protected-files harness uses the actual
`PlatformChatAttachmentFileStore` plugin on hardware. Together they check:

1. Enqueue text while explicitly disconnected, dispose the client, open account B
   without A's queued text, then recreate account A and send the restored text once.
2. Logout clears the presented message state.
3. Write protected attachment bytes, read them through a newly created adapter,
   remove them with retain, and verify they cannot be read again.

The backend is a deterministic injected fixture (and the chat-only test isolates
attachment cleanup as described above), so these tests require no
Chat server secrets, provider credentials or extra environment variables. Each run
uses isolated test identifiers and removes the storage keys/files it created in
`finally` blocks. Run against a test app installation on an unlocked device.
The test does not delete other app storage. A crash can leave this run's isolated
test records behind; uninstalling the test app may not clear iOS Keychain records.

Client/adapter recreation is **not** operating-system process death. This harness
does not certify locked-device behavior, backup/restore, signed entitlements,
real provider delivery/taps, real host authentication, or production backend
compatibility. Those require the physical-device acceptance checklist. Simulator
results must be recorded separately from Android and physical iOS results.

## Recorded native limitation

On 2026-10-25, the iPhone 17 Pro simulator with iOS 26.5 accepted the protection
setting but omitted the file-protection attribute when read back. The native
adapter correctly rejected the protected-file operation with
`sdk.attachment_persistence_unavailable`; backup exclusion alone is insufficient.
No plaintext/simulator bypass was added, and temporary native diagnostic logging
was removed. `protected_files_test.dart` remains a required hardware acceptance
test, not a passing simulator result. [Apple's protection type documentation](https://developer.apple.com/documentation/foundation/fileprotectiontype)
defines the protection level this adapter requires.

## iOS simulator coverage

The Keychain-backed outbox, account isolation, and UI integration checks passed
on the iPhone 17 Pro simulator with iOS 26.5. Protected-file recovery still
requires a physical device.

The iOS plugin supports Swift Package Manager and CocoaPods. The example app
builds with Swift Package Manager; the integration test above also passed with
it and with CocoaPods on the same simulator. `tool/check_ios_packaging.sh`
builds host apps with both package managers and the example with Swift Package
Manager; see `ios-swift-package-manager.md`.
