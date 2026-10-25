# Protodesk Chat SDK for Flutter

[![pub package](https://img.shields.io/pub/v/protodesk_chat.svg)](https://pub.dev/packages/protodesk_chat)
[![SDK checks](https://github.com/Protodesk/protodesk-chat-flutter/actions/workflows/checks.yml/badge.svg)](https://github.com/Protodesk/protodesk-chat-flutter/actions/workflows/checks.yml)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/Protodesk/protodesk-chat-flutter/blob/main/LICENSE)

Add Protodesk customer support chat to your Flutter app. Your customers get a
Home screen, conversations and your Help Center; your team answers from
Protodesk.

<p>
  <img src="https://raw.githubusercontent.com/Protodesk/protodesk-chat-flutter/main/screenshots/home.png" width="200" alt="Home tab">
  <img src="https://raw.githubusercontent.com/Protodesk/protodesk-chat-flutter/main/screenshots/conversation.png" width="200" alt="Conversation">
  <img src="https://raw.githubusercontent.com/Protodesk/protodesk-chat-flutter/main/screenshots/help.png" width="200" alt="Help Center">
  <img src="https://raw.githubusercontent.com/Protodesk/protodesk-chat-flutter/main/screenshots/dark-offline.png" width="200" alt="Dark theme, message queued offline">
</p>

## Features

- Ready-made messenger with Home, Messages and Help tabs, in your brand color
- Signed-in users or anonymous visitors
- Realtime messages that catch up after reconnecting
- Messages sent offline go out when the connection is back
- Image and file attachments
- Push notifications through FCM, APNs or OneSignal
- English and Indonesian, light and dark, screen reader support

Android (API 24+) and iOS (13+), Swift Package Manager or CocoaPods.

## Install

```sh
flutter pub add protodesk_chat
```

## Quick start

```dart
import 'package:protodesk_chat/protodesk_chat_ui.dart';

final client = await initializeChat(ChatClientOptions(
  publicChatAppId: 'your-chat-app-id',
  baseUrl: Uri.parse('https://api.protodesk.io'),
  platform: 'ios', // or 'android'
  storage: const PlatformChatStorage(), // keeps the session in Keychain/Keystore
  identityKey: currentUser.id,
  identityTokenProvider: () => yourBackend.fetchChatIdentityToken(),
));

Navigator.of(context).push(MaterialPageRoute(
  builder: (_) => ChatMessenger(client: client),
));

// When the user signs out:
await client.logout();
await client.dispose();
```

`identityTokenProvider` calls **your** backend, which issues a short-lived
Protodesk identity token for the signed-in user. Never ship Protodesk secrets in
the app. For anonymous visitors, leave out `identityTokenProvider` and
`identityKey` and set `allowNewAnonymousIdentity: true` on first launch.

Building your own UI? Import `package:protodesk_chat/protodesk_chat.dart` for
the client without widgets.

## How it works

<img src="https://raw.githubusercontent.com/Protodesk/protodesk-chat-flutter/main/docs/diagrams/start-chat.svg" alt="Sequence diagram: starting a chat">

The SDK reuses a saved session when it can, connects one realtime socket, and
replays anything missed while the app was closed.

<img src="https://raw.githubusercontent.com/Protodesk/protodesk-chat-flutter/main/docs/diagrams/send-message.svg" alt="Sequence diagram: sending a message">

Every message carries an ID from the moment it's typed, so retries after a
timeout or going offline never send it twice.

<img src="https://raw.githubusercontent.com/Protodesk/protodesk-chat-flutter/main/docs/diagrams/push-open.svg" alt="Sequence diagram: opening a push notification">

Your app owns the push provider. The SDK registers the token and opens the
right conversation when a notification is tapped.

## Learn more

- [Integration guide](https://github.com/Protodesk/protodesk-chat-flutter/blob/main/docs/guide.md): sessions, offline sending, attachments, push, theming
- [Push adapters](https://github.com/Protodesk/protodesk-chat-flutter/blob/main/examples/push_adapters/README.md): copyable FCM, APNs and OneSignal setup
- [iOS package managers](https://github.com/Protodesk/protodesk-chat-flutter/blob/main/docs/ios-swift-package-manager.md)
- [Example app](https://github.com/Protodesk/protodesk-chat-flutter/tree/main/example)

## Status

Early release. Tested on the iOS simulator and with widget, golden and
integration tests; not yet qualified on physical devices.

## License

Apache 2.0. See [LICENSE](https://github.com/Protodesk/protodesk-chat-flutter/blob/main/LICENSE).
