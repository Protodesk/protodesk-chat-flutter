# Anonymous and verified native Chat examples

From this directory, run `flutter pub get`, then choose an entry point on an Android/iOS
simulator or device:

```sh
flutter run -t lib/main_anonymous.dart
flutter run -t lib/main_verified.dart
```

Both apps share one Android/iOS shell; `main.dart` remains the anonymous default.
Enter your API origin and public Chat App ID. The anonymous example
uses anonymous mode with platform secure storage, opens `ChatScreen`, and revokes
the session when you return while retaining the anonymous installation proof.
Check the first-use option only when creating an identity is intended. The separate
recovery option explicitly starts fresh after credential loss; it cannot restore
lost history. Android backup exclusions and iOS Keychain entitlements are included.
No secrets belong in its configuration. See the repository README for verified
identity integration and preview limitations.


To exercise attachments, enter the exact public storage origin used by the
backend's presigned URLs in the optional storage-origin field. The paperclip opens
Flutter's native file selector through `lib/attachment_picker.dart`; files are read
with a 16 MiB bound. Images have thumbnails and an on-demand preview. Other types
show metadata cards; connect `onOpenAttachment` to a host viewer for playback/PDF
rendering. The example does not install a media/PDF viewer. Attachment bodies remain in
memory unless the separate secure-recovery checkbox is enabled. Picker/device/provider acceptance must still run on Android/iOS.
The picker follows the official [file_selector API](https://pub.dev/documentation/file_selector/latest/).


Enable **Keep attachments securely for restart recovery** to use the package's
native protected-file adapter. Selected files may then queue offline after session
initialization and resume only in the foreground. The SDK restores the original
conversation selection and any frozen attachment-send payload after process restart.
Normal Back navigation logs out and deliberately deletes pending managed work;
for restart testing, terminate/relaunch while the chat is open. Native private-file
protection, lock behavior, backup exclusion and real process-death testing remain
part of device acceptance, not the widget-test result.

For a host-authenticated upgrade, call `client.mergeAnonymousIdentity` with a
fresh-token callback and the authenticated account's stable `identityKey` after
explicit user intent. Resolve queued sends, attachments and unsent UI drafts first.
See the SDK README for `recoverIdentityMerge` and process-restart recovery. The anonymous example uses public configuration only; the verified entry point below demonstrates the authenticated host boundary.


Push integration is demonstrated in `../examples/push_adapters/README.md` with
copyable FCM, APNs, and OneSignal host adapters. The basic example intentionally
requires no provider project credentials. Use the same adapters with either the
verified token-provider setup or secure anonymous sessions, and recreate them
when identity changes. Live-device delivery and cold-start acceptance are pending.

## Verified host integration

Run `lib/main_verified.dart`. Along with the public Chat App ID and API origin,
enter your host backend's HTTPS identity endpoint and a short-lived **host login
access token** from your test account. This is not a Protodesk server secret or a
Chat identity token. The field is obscured and cleared when connecting; the token
is held in memory until exit/failure. No new environment variables are used.

The host-owned endpoint is an example contract, not an existing Protodesk route:

| Request | Response (HTTP 200 JSON) |
| --- | --- |
| `GET /your/chat-identity` | `{"identityKey":"opaque-stable-host-account-id"}` |
| `POST /your/chat-identity` | `{"identityKey":"opaque-stable-host-account-id","token":"fresh-single-use-chat-identity-token"}` |

Both requests carry `Authorization: Bearer <host-login-access-token>`. The server
must authenticate that session and derive the account identity itself. Never accept
an account ID supplied by this app. On POST, the host server calls Protodesk's
`POST /v1/chat/identity-tokens` using its server-side Chat App secret and the
logged-in customer's identity; return the minted token with the same opaque
partition key. Keep the Chat App binding server-owned and send `Cache-Control:
no-store`. Do not cache tokens or log response bodies. No server secret ships in
this example. Provision this endpoint in your own authenticated host backend;
there is no bundled login service or test credential.

`HttpHostIdentity` resolves the account before opening chat, then requests a new
token for every SDK provider invocation. It rejects changed accounts, redirects,
non-200 responses, oversized/malformed bodies, and non-HTTPS endpoints. Requests
have a 15-second deadline and are not automatically retried. In production, replace
this adapter with your existing host API/auth client, including its login/session
refresh flow; the manual token field is for local integration testing only.

The backend-provided account key partitions the SDK's secure session and queued
work. Back navigation revokes the current Chat session and deletes pending managed
work before returning to setup; it does not log out your host account. To switch
accounts, leave chat, sign into the other host account, and reconnect with its
host session. Process restart requires host authentication again before opening
verified chat, then the SDK may restore that account's secure state. It never
falls back to anonymous mode after a verified authentication failure.

## Local acceptance and remaining device checks

Example tests cover public-only anonymous setup, invalid configuration, explicit
anonymous creation, logout, verified account partitioning, fresh providers,
credential clearing, and host HTTP failure/account-change handling. They use
injected transports and do not require live credentials.

On a configured Android/iOS device, verify anonymous restart/recovery, verified
restart and token expiry, exit/revocation, and switching between two real host
accounts without shared history or queued work. Use separate test installations
if you need both variants simultaneously; these entry points share an application
ID. Real backend, Keychain/Keystore, picker and physical-device acceptance remain
open until run with your own configuration.

Native adapter/UI integration tests are in `integration_test/chat_native_test.dart`.
Run them with `flutter test integration_test/chat_native_test.dart -d <device-id>`;
run `integration_test/protected_files_test.dart` separately on physical hardware;
see [testing guide](../docs/testing.md) for coverage and device acceptance limits.
