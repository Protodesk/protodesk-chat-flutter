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

`test/goldens/chat_screen_golden_test.dart` compares four reviewed PNG baselines:

- English light phone with customer/support history and read action.
- Indonesian dark phone with 2x text and wrapping controls.
- English light tablet with empty history.
- Indonesian dark phone with a disconnected, queued message and discard control.

Golden generation environment: Flutter **3.47.5**, Dart **3.13.4**, macOS arm64.
Use this toolchain/host for pixel comparisons. Renderer/font changes on another
OS or Flutter version may require a separately reviewed baseline migration.
Tests load Roboto and MaterialIcons from the resolved Flutter SDK using
`.dart_tool/package_config.json`; there are no absolute workstation paths or
network fonts. Sizes, theme platform, locale, text scale and fixture content are
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

## Native integration harness

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

## Local results (2026-10-25)

- SDK suite: 305 tests passed after the local messenger, Help, contact, and context updates; analysis is clean. Golden comparisons are included in this suite.
- Example suite: 11 tests passed; SDK/example analysis clean.
- iPhone 17 Pro / iOS 26.5 simulator: the Keychain-backed outbox/account-isolation/UI
  integration test passed after separating the unsupported file-protection dependency.
- Protected-file hardware suite: added, but not passed on physical Android/iOS.
  The simulator rejection above is recorded as a limitation, not a successful test.

The iOS test build currently uses CocoaPods fallback for the SDK's native plugin;
Flutter warns that native Swift Package Manager support will be needed in a future
release. That packaging migration is separate from this test increment.
