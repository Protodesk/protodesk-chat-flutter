# Host-owned push adapters

Copy only the adapter for the provider your app already uses. This optional
package type-checks against Firebase Messaging 16.7.0 and OneSignal 5.6.1; neither
is a core SDK dependency. APNs uses the host's existing AppDelegate and a private
MethodChannel. Do not initialize a second provider SDK or replace app-global
notification handlers. There are no new environment variables.

## Startup and navigation

`startChat(options)` returns immediately; attach tap handlers before awaiting
`client.ready`. Handle readiness errors and dispose the client on failure.
`initializeChat(options)` remains the await-ready convenience API. For verified
users, obtain the identity token through the host's authenticated backend; no
server secret belongs in the app. For anonymous users use the established secure
session/resume-proof storage options. The adapters work with either identity.

```dart
final client = startChat(options);
final host = ChatPushNavigationHost(client, existingNavigatorKey);
final errorSubscription = host.navigation.errors.listen(showSafeChatError);
final taps = FcmChatTaps(host.navigation);
try {
  await Future.wait([client.ready, taps.start(FirebaseMessaging.instance)]);
  final binding = ChatPushRegistrationBinding(
    targets: client.createPushTargets(),
    provider: ChatPushProvider.fcm,
    installationId: stableInstallationUuid,
  );
  final registration = FcmChatAdapter(
    FirebaseMessaging.instance, binding, onError: showSafeChatError,
  );
  await registration.start(optedIn: userEnabledChatNotifications);
  // Retain these objects; call registration.refresh() on resume and
  // registration.setOptedIn(...) when the host preference changes.
} catch (_) {
  await taps.dispose();
  await host.dispose();
  await errorSubscription.cancel();
  await client.dispose();
  rethrow;
}
```

In concurrent startup code, attach an error handler to `client.ready` immediately
(e.g. include it in `Future.wait` with `taps.start`) so a failed sign-in is observed
while the provider initializes. `ChatPushNavigationHost` is a copyable imperative
Navigator example. Adapt its synchronous `onNavigate` callback to your router;
return true only when the route is accepted. It passes the API-resolved
conversation ID to `ChatScreen(initialConversationId: ...)`. Do not await the
Navigator route's pop future in this callback. For an existing chat screen, the
host can focus that route instead of pushing another one.

For OneSignal, use `OneSignalChatTaps`, `OneSignalChatAdapter`, and provider
`ChatPushProvider.onesignal`. Attach the click listener early. Registration uses
`OneSignal.User.pushSubscription.id`, **not** its native token, external user ID,
or OneSignal user ID. Permission and provider opt-in must both allow delivery;
the separate host preference must also be true. Custom action-button clicks
remain host-owned; the copyable tap adapter handles default opens only. No host
OneSignal login/logout or global opt-in state is changed by this adapter.

The parser accepts only the `protodesk` envelope in FCM `message.data`, APNs
`userInfo`, or OneSignal `additionalData`. FCM encodes the envelope as a JSON
string; APNs and OneSignal provide an object. It requires schema 1,
`message.created`, the configured public Chat App ID, and bounded canonical IDs.
Test pushes, arbitrary URLs, unsupported versions, other apps, and malformed
payloads are ignored. Call `handlePushPayload` only on a user tap, never on a
background message or foreground receipt. Other app handlers continue normally. If your host already consumes Firebase
`getInitialMessage`, call it only once and fan out its result to this controller
and your other handlers; use `FcmChatTaps.start(..., readInitialMessage: false)`.
Alternatively forward from the host's existing tap listener directly instead of
installing the copyable tap helper. Do not route the same Chat tap through two
separate navigation controllers.

The controller keeps one newest tap in memory for two minutes (configurable up to
five), with a bounded 128-intent/five-minute deduplication window. Duplicate taps
do not extend expiry. It waits for active scene, navigator readiness, session
readiness/refresh, and an authenticated conversation lookup. Newer taps supersede
older lookups. Identity changes/disposal fence responses and clear navigation.
Failed/inaccessible lookups are dropped and surfaced on `errors`; there is no
retry loop or persisted navigation across process restarts. Navigation acceptance
triggers best-effort notification-open reporting. Reporting failures do not
reopen the route. Push taps **never** mark history as read; viewport read reporting
retains that responsibility. Call `refreshReadiness()` when your host mounts or
replaces its navigator; scene readiness remains host-owned in multi-window apps.

## Direct APNs forwarding

Add `ios/ChatAPNsBridge.swift` to the host app target, create it with the host
Flutter engine's binary messenger before registering for remote notifications,
and retain it. Use provider `apns` and SDK platform `ios`. Forward the existing
callbacks on the main thread:

```swift
// In the existing didRegisterForRemoteNotificationsWithDeviceToken callback:
chatAPNsBridge.didRegister(deviceToken: deviceToken)
// Preserve existing provider/super callback forwarding in your host.

// In the existing UNUserNotificationCenter didReceive response callback:
if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
    DispatchQueue.main.async {
        self.chatAPNsBridge.didOpen(userInfo: response.notification.request.content.userInfo)
    }
}
// The HOST still calls its completionHandler exactly once, as before.
```

Use `ApnsChatChannel` with the navigation controller; set its `registration` to
an `ApnsChatAdapter` once the session is ready, set `optedIn`, then call `refresh`.
Call `start` early to consume a native cold-start tap; call `refresh` on resume,
permission/preference changes, and after attaching registration. The Swift helper
buffers one cold tap for 120 seconds and keeps the token only in process memory.
It does not install or swizzle delegates. The host requests authorization and
calls `registerForRemoteNotifications()` on each launch. Preserve Push
Notifications capability, `aps-environment`, signing, and existing provider
forwarding. Do not register an APNs token to an FCM route or vice versa.

FCM on iOS waits for APNs registration before requesting an FCM token. If APNs is
not ready, call `refresh()` after its registration callback (or on resume). For
FCM, preserve the host's Firebase configuration, iOS forwarding/swizzling policy,
Android notification permission flow, and existing background handler. OneSignal
likewise retains its existing platform setup and any service extension.

## Permission, errors, and account changes

The binding serializes mutations and keeps only the newest pending update. A
failed registration retains its token and operation key in memory so the next
explicit update can recover an uncertain response before rotation/unregister.
There is no timer retry or disk token cache. With secure session storage,
only routing target ID/owner metadata survives restart, enabling unregister even
if permission was revoked while the app was closed. Logout/reset clear it;
confirmed merge migrates it to the verified partition. Without secure storage,
or after a lost initial response before the target ID was saved, session logout
is the safe fallback for revoking an unknown target. A stale target's 404 clears
its ID; explicitly retry registration to create a new target. Surface failures; retry explicitly
on connectivity recovery/resume. A persistent registration error may require
session logout to revoke an unknown target. `dispose` drops queued work and can
surface an in-flight failure; it is not remote revocation.

On opt-out use `setOptedIn(false)` (or APNs `permissionRevoked`) and await it. On
logout/account switch, cancel provider/tap listeners, invalidate navigation, and
call `client.logout()`/`identify()` even if adapter disposal fails. Do not let a
failed cleanup skip session revocation: use `try/finally`. Recreate all identity-
scoped objects and explicitly register the current token after successful login
or merge. Never reconnect an old listener to a new handle. Initialization and
adapter errors must not be logged with raw payloads/tokens.

## Validation and remaining acceptance

Run `flutter pub get`, `flutter analyze`, and `flutter test` in this directory.
Core tests cover malformed payloads, auth/refresh, cold-start readiness, bounded
pending work, deduplication, expiry, lifecycle races, and routing. Adapter tests
use mocked provider/channel events; the Swift helper is type-checked separately.
Physical iOS/Android delivery, killed-app launches, provider configuration,
permission settings changes, OEM behavior, and beta acceptance remain open.

References checked for this implementation:
- [Firebase token lifecycle](https://firebase.google.com/docs/cloud-messaging/flutter/get-started)
- [Firebase notification interactions](https://firebase.google.com/docs/cloud-messaging/flutter/receive-messages)
- [OneSignal Flutter source](https://github.com/OneSignal/OneSignal-Flutter-SDK)
- [Apple device-token callback](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:didregisterforremotenotificationswithdevicetoken:))
