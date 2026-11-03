# Presentation and local lifecycle

Import `package:protodesk_chat/protodesk_chat_ui.dart`, retain an explicit client,
and call `await client.openChat(context)`. The future completes on route dismissal.
The helper awaits initial session readiness and rejects a disposed client, a
signed-out session, an identity change during readiness, or an unmounted context.
No delay is used. The nearest Navigator owns the Material route; pass
`useRootNavigator: true` to select the root navigator. Back navigation leaves the
client signed in. The host remains responsible for logout and client disposal.
Closing or backing out hides the current presentation. Reopen on the same client
and navigator to continue editing the same draft or reading the same Help page,
including its language, search and scroll position. Opening Help separately
does not discard a chat draft. An explicit conversation or article link opens
its destination. Account changes, client disposal and navigator disposal clear
the retained UI; it is not written to disk. Repeated launches of the same
visible presentation share its dismissal future.

All ChatScreen options are forwarded, including initialConversationId, theme,
localizations, preChat/routingChoiceId, attachment picker/viewer, and automatic
read reporting. Supply routeSettings for host route observation. Direct ChatScreen
embedding remains supported.

## Activity stream

```dart
final subscription = client.sdkLifecycleEvents.listen((event) {
  switch (event) {
    case ChatLifecycleEvent.sessionReady:
    case ChatLifecycleEvent.chatOpened:
    case ChatLifecycleEvent.chatClosed:
    case ChatLifecycleEvent.pushOpened:
      // Update host UI or content-free analytics.
      break;
  }
});
// Cancel when the host stops observing.
await subscription.cancel();
```

The stream is broadcast, lazy, and has no replay. Its underlying state listener
exists only while there are subscribers. Subscribe before an operation to observe
it; use `client.ready`, `client.waitUntilReady()` and `client.state` for readiness
instead of relying on a past event. The stream closes on client disposal. Events
contain no identity keys, message content, credentials, or push payloads and remain
separate from canonical server `client.events`.

ChatScreen emits opened when presented and closed when hidden, removed or rebound to a
different client. These mean presentation lifetime, not foreground visibility,
animation completion, or read evidence. A custom UI can call
`final close = client.trackChatPresentation()` when mounted, then `close()` when
removed. The returned callback is idempotent; do not also track a ChatScreen.

Push opened means an authenticated lookup succeeded and the host accepted the
navigation while the bound identity remained current. It does not mean the screen
has rendered or the backend open-report request succeeded. Rejected, duplicate,
expired, and stale-account taps do not produce it. Push callbacks remain host owned
and never invoke openChat automatically.
