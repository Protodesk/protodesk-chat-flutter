## 0.1.1

- Upgrade `flutter_secure_storage` to 11. Android now needs API 24, same as
  Flutter itself. Sessions saved by 0.1.0 are still read correctly.
- Shorter README with screenshots and sequence diagrams; the full reference
  moved to `docs/guide.md`.
- Enable the Flutter recommended lints (no behaviour change).

## 0.1.0

Initial release.

- `ChatMessenger` with Home, Messages and Help tabs
- Signed-in and anonymous sessions, optionally kept in Keychain/Keystore
- Realtime messaging with reconnect and replay
- Offline send queue, attachments, unread counts and typing
- Push notifications through FCM, APNs or OneSignal
- English and Indonesian, light and dark themes
- iOS via Swift Package Manager or CocoaPods
