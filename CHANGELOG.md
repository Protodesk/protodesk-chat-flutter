## 0.1.2

- Signed-in users are greeted by name on Home, with their avatar when the
  host's backend supplied one.
- A pre-chat form whose fields the server already filled (name and email for
  verified sessions) is no longer shown. Needs a Protodesk backend that omits
  identity fields for verified sessions; older servers still show the form.

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
