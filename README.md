# Protodesk Chat for Flutter

Local, unpublished native integration preview (`0.1.0-dev.1`). This repository is
separate from the staff-facing `protodesk-mobile` app. The backend owns the
canonical protocol in `protodesk-backend/api/contracts/chat/` and
`protodesk-backend/api/openapi/chat-openapi.yaml`; the Phase 0 Dart sketch describes
the larger target API, not the implemented surface of this preview.

## What works

- Anonymous session creation or verified sign-in with a host-provided identity token.
- Optional device-secure sessions and anonymous resume proofs, with single-flight refresh,
  write-ahead token fencing, generation acknowledgement, and explicit recovery/reset.
  Omitting storage keeps credentials in memory only.
- Conversation creation/listing and text/attachment message send/history, including cursor pagination in the headless API.
- Foreground attachment uploads with progress, validation, cancellation/retry, image previews,
  file metadata cards, and a host picker/viewer adapter. Opt-in protected file copies and
  an encrypted journal recover pending uploads and uncertain attachment sends after restart.
- Explicit UUID operation IDs for retrying the same mutation without changing its payload.
- Foreground WebSockets with fresh one-time tickets, cursor replay, bounded event deduplication,
  heartbeat timeout, jittered reconnect and server-drain handling. No polling fallback.
- A livechat-style `ChatMessenger` (`ChatScreen` remains as an alias): Messages list, thread with brand header, bubbles, greeting and composer; choose/create a conversation, send/retry text, consume reconciled history on events/reconnect,
  suspend on background, and clear its data on logout/account change.
- Local logout isolation followed by remote session revocation. A revocation error is surfaced;
  it does not restore local session access. `dispose()` only releases local resources.

## Use locally

In a native Flutter host's `pubspec.yaml`:

```yaml
dependencies:
  protodesk_chat:
    path: ../protodesk-chat-flutter
```

```dart
import 'package:protodesk_chat/protodesk_chat_ui.dart';

final client = await initializeChat(ChatClientOptions(
  publicChatAppId: publicChatAppId,
  baseUrl: Uri.parse(apiOrigin), // HTTPS origin, without /v1.
  platform: 'ios', // Or 'android'.
  storage: const PlatformChatStorage(),
  identityKey: authenticatedHostAccountId, // Opaque stable ID, never a token/email.
  identityTokenProvider: () => hostBackend.fetchFreshChatIdentityToken(),
));

// Mount in a MaterialApp / Navigator. The host owns the client lifetime.
final screen = ChatScreen(client: client);
// When the host signs out:
await client.logout();
await client.dispose();
```

The token provider must call your authenticated host backend, which mints a fresh,
single-use Chat identity token for the same Chat App and current user. Never put
Chat server secrets, platform API keys or provider credentials in the Flutter app.
Omit `identityTokenProvider` for anonymous mode. With storage enabled,
`identify(newProvider, identityKey: newAccountId)` changes accounts after revoking
and clearing the old session. The host must derive that key from its authenticated
user, not UI input. It does not merge anonymous history.

For a custom UI, import `package:protodesk_chat/protodesk_chat.dart`. Use
`listConversations`, `createConversation`, `listMessages`, and `sendMessage`.
Generate IDs with `ProtodeskChatClient.newOperationId()`. Keep an operation's ID
**and payload unchanged** after a timeout; reuse them for the explicit retry.
429/503 errors expose `retryable` and `retryAfter`; direct `sendMessage()` calls do
not automatically retry mutations. The opt-in `sendQueue` handles bounded retries. Refresh retries are particularly unsafe after an uncertain response.

Call `connect()` in the foreground and `disconnect()` in the background.
`connectionStates` reports actual readiness; `connect()` starts the loop and does
not wait for a ready frame. Subscribe to `errors` for terminal/transient transport
errors and `changes` for committed recent-cache updates on connection, replay
and resync. Use `ChatHistoryController` to retain paginated history. Headless consumers must clear their own caches on non-ready `states`.
All streams are broadcast and do not replay prior values; read the current state
when subscribing. API operations from an old identity reject after account changes.

The screen uses `ChatHistoryController` for conversation/message pagination and
incremental realtime updates. It provides older-page, retry, and end-of-history
controls with lazy lists and optimistic text sends backed by the bounded offline queue.
Low-level single-page access remains available through `ChatPage.nextCursor` / `hasMore`.
When the Chat App has an enabled pre-chat form or routing choices, every "start
a conversation" action first shows that form (text, email, select and checkbox
fields with the web widget's validation, plus "What can we help with?"). The
server revalidates; if it reports `chat.configuration_stale`,
`chat.pre_chat_invalid` or `chat.routing_choice_invalid`, the messenger reloads
the configuration and asks again. Passing `ChatScreen.preChat` and
`routingChoiceId` skips the form. When the server allows anonymous reset, a
conversation's "Chat options" menu offers "Start over": after confirmation it
revokes the anonymous identity and signs in as a new visitor; a failed reset
keeps the current identity.

## App configuration and Help Center (headless)

`client.getConfiguration()` returns the public Chat App configuration from
`/v1/chat/bootstrap`: name, header title, greeting, appearance (validated brand
colour, HTTPS logo, preferred colour scheme), pre-chat form, routing choices,
configured HTTPS links, Help settings and capabilities. It is cached until the
identity changes (`cachedConfiguration`; unread reads refresh it). Unsafe links
and logos, invalid colours and unknown pre-chat field types are dropped.

Help Center reads use the Chat session: `getHelpCenter(locale:)`,
`listHelpArticles(query:, collectionId:, locale:, cursor:, limit:)` and
`getHelpArticle(id, locale:)`. Invalid input fails locally with
`chat.help_request_invalid`; `chat.help_center_unavailable` means Help is off or
has no published content. `ChatHelpController` adds a single-flight manifest
load, article and listing caches per locale, de-duplicated cursor pagination and
an explicit locale choice that is remembered per Chat App in the configured
storage adapter (a failing or locked store never blocks Help). Caches are dropped
on logout and account changes, and late responses are ignored.

`ChatHelpDocument.parse(markdown)` parses the Compact Help Markdown profile used
by the web widget (headings, paragraphs, emphasis, HTTPS links, HTTPS raster
images with size presets, quotes, ordered/unordered/task lists, tables and
escaped fenced code; raw HTML lines are dropped) and builds an "On this page"
outline with stable heading IDs. The prebuilt UI for these arrives with the
livechat-style messenger described in [`docs/livechat-ui-plan.md`](docs/livechat-ui-plan.md).

## Conversation context and optional contact email

Pass `ChatClientOptions.initialContext` (or `context:` on `createConversation`) to
record where a conversation started:

```dart
initialContext: ChatCreateConversationContext(
  screen: 'order_details',
  metadata: {'entryPoint': 'help_button', 'step': 2},
),
```

Context is display-only and always stored as `client_unverified`: it never grants
access or controls routing. The SDK checks the server's limits before sending
(screen ≤128 characters; ≤24 flat string/number/bool/null values; keys
`[A-Za-z0-9_.-]{1,64}`; strings ≤1024; 4 KiB encoded) and rejects credential-like
keys (`token`, `secret`, `password`, `api_key`, `cookie`, …) with
`chat.context_invalid`. `ChatConversation.context` exposes the returned
`provenance`, `screen` and `metadata`; unrecognized provenance values parse as
`unknown` and are never treated as verified. `ChatExternalObjectReference` is
sent as given, but servers without an ownership resolver reject it with
`chat.external_object_unverified`. `getConversation(id)` loads one conversation.

Business context and provenance are for the support team: `ChatScreen` does
not show them to the customer. Hosts can still read `conversation.context`.
Conversations opened by ID or push are loaded for their closed status.

Anonymous visitors may share an optional follow-up email after their first saved
message. `getContact`, `shareContactEmail` and `dismissContactRequest` return
`ChatContact(email, dismissed, canRequest)`. This is self-reported contact
information: it never signs in, verifies, merges, or replaces a profile email,
and a stale dismissal never erases a saved email. Reuse the same `operationId`
and email after an uncertain (network, 408, 429, 5xx) result; start a new one after
a definitive rejection. `ChatScreen` requests contact state only for an anonymous
session with a saved customer message in a non-closed conversation. It shows the
inline form only while `canRequest` is true, hides it on 403/404, and offers a retry
when loading fails.

## Secure persistence and recovery

Pass `storage: const PlatformChatStorage()` to opt in. It uses
`flutter_secure_storage` 10.3.1: Android Keystore-backed encryption with
`resetOnError: false`, and iOS `unlocked_this_device` Keychain accessibility with
cloud synchronization disabled. Nothing falls back to plaintext. Platform errors
become `chat.storage_unavailable` without exposing storage errors or credentials.
Writes are read back before an acknowledgement is sent.

The encrypted record is partitioned by API origin + public Chat App ID + identity
kind and, for verified users, the opaque host account `identityKey`. Tokens, expiry,
anonymous installation ID, resume proof, generation, and pending acknowledgement
are stored together in one atomic key replacement. Identity-minting tokens are never
persisted. Realtime uses a separate encrypted history checkpoint in the same identity
partition, so history writes cannot overwrite rotating credentials.

For an **ordinary anonymous restart**, provide storage and neither creation nor
recovery flag. The client resumes the saved installation with its saved proof. If
a replacement arrives, it saves the higher generation before acknowledging it.
Lost rotation responses retain the predecessor proof; lost acknowledgement responses
retain the replacement, which can be resumed without the server echoing it again.
A lower generation or conflicting same-generation secret is rejected.

For **first use**, opt in explicitly with `allowNewAnonymousIdentity: true`.
Without that consent, empty storage returns `chat.anonymous_identity_missing`.
Use the default `false` for ordinary restarts: a completely wiped secure store is
indistinguishable from a first install, so this guard prevents silent identity forks.
An interrupted first creation with a saved ID but no proof returns
`chat.anonymous_recovery_required`; it never resends that ID without proof.

For **lost/corrupt proof**, present the consequence to the user and initialize with
`recoverLostAnonymousIdentity: true`. If a still-valid stored access token remains,
the client first resets the old binding on the server. Otherwise, unusable local
credentials are replaced with a new random installation; inaccessible old history
is not restored or reassigned, and the abandoned binding follows server retention.
An inaccessible/locked Keychain is an error, not evidence of lost credentials.
If stored access is rejected, recovery checks the remaining proof through the
normal durable resume path. A proof rejected with `chat.anonymous_resume_invalid`
can be explicitly replaced; a usable proof returns `chat.anonymous_reset_required`:
resume normally and use the authenticated reset API instead of abandoning it.

For **intentional reset while signed in**, call:

```dart
await client.resetAnonymousIdentity(); // Server confirmation before proof removal.
await client.continueAnonymously();    // Explicitly start the replacement identity.
```

An unsuccessful server reset retains the proof for retry. If the server reset
succeeds but local persistence fails, visible access still closes and an error is
returned; an old revoked proof cannot silently recreate the old identity.
Anonymous `logout()` revokes its current session and clears tokens, while retaining
its installation proof until explicit reset. Verified logout clears that account's
tokens. `dispose()` retains saved credentials for a later app restart.

Every restored verified session is refreshed before readiness. Before sending a
refresh token, the SDK durably removes it and marks refresh pending. A crash or
ambiguous response therefore cannot replay that token on restart: verified sessions
require a fresh host identity token; anonymous sessions can use their saved proof.
Logout clears local state immediately, waits for queued durable clearing, and
revokes late-issued sessions. Storage/revocation failures are surfaced rather than
claiming successful durable logout. New account operations reject stale responses.

Use **one owning client per origin/app in one foreground isolate**. A second client
in that isolate is rejected with `chat.storage_in_use` until disposal finishes.
Background isolates/engines must delegate to that owner; the lease is not a
cross-process lock. Custom storage adapters must guarantee atomic durable writes
and report errors, and must actually provide platform-secure storage. Do not share
one persisted identity between multiple independently running engines.

### Native host configuration

- **Android:** exclude encrypted preferences and their wrapping-key/configuration
  preferences from cloud backup and device transfer. The example disables app
  backup and excludes all shared preferences in both legacy backup and Android 12+
  extraction rules. Production hosts should merge appropriate exclusions into
  their existing backup policy, rather than replacing unrelated backup settings.
- **iOS:** configure Keychain access entitlements for every build configuration.
  The example wires `Runner/Runner.entitlements` for Debug, Profile, and Release.
  The adapter uses device-only, unlocked accessibility; locked-device reads fail
  rather than reset credentials. Keychain items can survive app reinstall on the
  same device; reinstall is not an identity reset. Use the explicit reset flow.
- Persistence opt-out is `storage: null` (the default). Switching it off does not
  erase prior stored credentials: reset/logout the persisted client first if the
  intended action is deletion. No message cache is stored by this version.

The local tests use a secure-storage test double; actual platform encryption,
backup exclusion, app signing, and crash atomicity still need device verification.

## Run the example and checks

Requires Flutter with Dart >=3.12. Local verification on 2026-10-25 used
Flutter 3.47.5 and Dart 3.13.4: analysis is clean and all 32 SDK tests pass.
Persistence tests include replacement/ack loss,
refresh fencing, reset, account partitions, and logout during delayed writes/exchanges. This is evidence for this toolchain, not a broader compatibility claim.

```sh
flutter pub get
flutter analyze
flutter test
cd example
flutter pub get
flutter test
flutter run
```

The example contains Android/iOS host scaffolding and asks for API origin and
public Chat App ID; anonymous mode must be enabled on that app. Its default origin
is editable and makes no requests until you choose to connect. For a local API,
use an HTTPS tunnel or loopback on the simulator. Only loopback permits HTTP at
the client level; native cleartext/ATS policies still apply. Never disable those
policies for a production host just to use this example.

`test/src/native_protocol_test.dart` exercises real local HTTP and WebSocket
sockets against a protocol fixture. It is not a live backend, provider, or physical
device test. Unit tests cover refresh races, late responses after logout, account
switching, retry identifiers, replay/deduplication, and intentional disconnect.
Widget tests cover retry and clearing visible messages after logout.

### iOS package managers

The iOS plugin builds with Swift Package Manager or CocoaPods; Flutter picks
Swift Package Manager when it is enabled for the host app. It ships a privacy
manifest. On macOS, `tool/check_release.sh` also runs
`tool/check_ios_packaging.sh`, which builds host apps with both package
managers. See `docs/ios-swift-package-manager.md`.

## Explicitly unfinished

This is **not ready for production or package publication**. `publish_to: none`
prevents accidental release. No registry ownership or supported-device matrix is claimed.

- Physical-device Keychain/Keystore, backup/restore, uninstall/reinstall, and process-kill acceptance.
- Sustained-stream/device qualification, full offline history, and the full strategy's lifecycle/diagnostics API.
- Physical-device push/attachment-storage acceptance and managed-push beta verification.
- Full UI kit, physical-device accessibility acceptance, and release/device acceptance.
- Flutter web transport/origin bootstrap (the current transport uses `dart:io`).
- Real backend and device acceptance, package ownership, release signing and publishing.

Existing backend API support does not imply these SDK features are implemented.
No new backend environment variables are needed for this preview.

## Durable realtime and recent history

With `storage` configured, `connect()` restores an encrypted checkpoint containing
the cursor, up to 256 deduplication IDs, the latest conversation page, and the latest
message page for the most recently requested conversation (`listMessages(id)` without
a pagination cursor). This is a recent-history window, not an offline archive.
`cachedConversations`, `cachedConversationId`, and `cachedMessages(id)` expose the
last committed window. Pagination metadata is retained; older pages still use the
REST pagination API. Without storage, the same reconciliation runs in memory.

Every socket's `realtime.ready` establishes a boundary before authoritative REST
reconciliation. Frames arriving during that work queue in order. The SDK persists
history and cursor atomically and reads the write back before publishing readiness,
`changes`, or an event. Message creation/delivery/failure and conversation creation/update/resolution
reduce a detached copy of the cached window locally, with no per-event HTTP call.
Full projections use `updatedAt` and status transitions use `occurredAt`; older or
equal versions cannot overwrite newer REST data. Stable server IDs deduplicate rows
across distinct event envelopes. Missing status rows are not fabricated. Events for
unwatched message windows still commit their cursor and publish notifications.
It is event-driven, with no polling fallback.

`conversation.read` retains a **targeted GET of the affected cached conversation**:
its `readAt` does not version the computed unread count against a REST snapshot.
No fetch is needed if that conversation is outside the cached page. Incoming agent,
AI, and system messages mark `ChatConversation.unreadCountIsStale` instead of
incrementing an unknowable total (replay may already be included in the snapshot).
Hosts should refresh `listConversations()` before presenting that count as an
exact badge. Reconnect reconciliation and targeted read refresh restore authoritative
cached totals; a newer full conversation projection also replaces them.

Selecting a different message window seeds it through REST on the next unique message
or conversation-projection event.
Reconnect/resync still reconcile after the ready boundary. Incremental insertions
preserve the original pagination cursor and do not evict rows behind that boundary;
old projections below an incomplete window are ignored. The 1 MiB checkpoint limit
continues to bound growth. Unsupported schemas/types and malformed projections stop
the connection without committing their cursor or issuing speculative HTTP requests.
Duplicate event IDs are suppressed within the persisted 256-event window; event
subscriptions are notifications, not an exactly-once durable consumer API.

A rejected/expired cursor is durably cleared before reconnecting with an empty
cursor; the replacement boundary is committed only after reconciliation succeeds.
Retryable REST failures keep the previous checkpoint. Storage failures stop the
connection and surface a safe error; fix storage and call `connect()` to retry.
A 404 for the watched conversation removes its cached messages. Logout/reset clear
the checkpoint, account changes isolate partitions, and anonymous checkpoints also
match the installation ID. `dispose()` retains the checkpoint for restart.

The queue is bounded to 128 frames of at most 256 KiB each; overflow closes and
replays from the last committed cursor. Checkpoints are limited to 1 MiB; exceeding
that limit reports `chat.history_checkpoint_too_large` without advancing the cursor.
Do not use this Keychain-backed preview as a bulk message database. Native process
kill, device storage behavior, sustained stream throughput, and deployed-backend
acceptance remain release gates. Local tests cover blocked reconciliation, restart,
duplicate replay, resync, REST/storage failures, overflow, and logout during a load.

`test/src/history_reducer_test.dart` covers timestamp ordering, duplicate projections,
pagination boundaries, unknown schemas, unread freshness, targeted read refresh,
and a 20-message burst with zero additional HTTP requests.

## Full history pagination

```dart
final history = ChatHistoryController(client, conversationId: conversationId);
final subscription = history.changes.listen((_) {
  // Read history.messages (newest first), isLoading, hasMore, and error.
});
await history.loadNext(); // First page; subsequent calls fetch the next cursor.
await history.loadNext(); // Older messages, merged by ID and resource version.
await history.retry();    // Retries a failed page; invalid cursors restart the chain.
// On leaving this screen:
await subscription.cancel();
await history.dispose();
```

Omit `conversationId` for the conversation list and read `history.conversations`.
Each controller owns one immutable scope. Concurrent `loadNext()` calls share one
request; failures retain both loaded rows and the cursor. Empty terminal pages end
pagination; missing/repeated continuation cursors surface a safe error. The screen
exposes “Load more conversations”, “Load older messages”, retry, and explicit end
states. Its reversed, lazy message list appends older rows without moving existing
rows; server-confirmed sends enter the controller without discarding older pages.

Page responses merge with realtime by stable server ID and resource timestamp.
Events received during a page request are replayed over its result, including status
updates for messages that were not loaded yet. That race buffer is capped at 256
events; overflow requests an explicit refresh instead of silently losing updates.
Logout, account changes, disposal, and a newer refresh fence late page responses.

**Refresh/reconnect starts a new page chain.** Previously loaded older pages are
cleared because stitching a new first page to an old tail could conceal a gap after
many new messages. The user can load older pages again. Browsing another conversation
creates a separate controller; it never reuses the previous conversation's cursor.

Pages are loaded on demand into memory, without an arbitrary history-page limit or
background prefetch. Dispose controllers when leaving history. Older pages are not
written to Keychain/Keystore and do not expand the 1 MiB recent-history checkpoint.
This is full online history browsing, not an offline archive or a device memory
qualification claim. `includeMessage()` accepts only server-confirmed send responses.

## Optimistic text sends and bounded offline queue

`ChatScreen` uses the client-owned `sendQueue`. Headless integrations can opt in:

```dart
final operationId = await client.sendQueue.enqueueDurably(
  conversationId: conversationId,
  text: 'Hello',
);
// Observe sendQueue.changes and read sendQueue.messages for local send state.
// ChatHistoryController.messages overlays these rows automatically.
await client.sendQueue.retry(operationId);   // Transient failures only; same ID/body.
await client.sendQueue.discard(operationId); // Idle local item only; never server deletion.
```

Default bounds are **50 items, 256 KiB total UTF-8 text, 16 KiB per message,
24-hour maximum age, and five automatic attempts**. `ChatClientOptions.sendQueueOptions`
can lower these limits (hard ceilings: 100 items, 1 MiB text, 24 hours, eight attempts).
Failed items count toward capacity until discarded or expired. `chat.send_queue_full`
rejects a new enqueue without clearing its composer draft. Expiry removes local text
and surfaces `chat.send_queue_expired`; already transmitted requests may still have
been accepted remotely.

The queue is memory-only by default. Enable `persistSendQueue: true` with secure
storage for restart recovery (below). The text outbox never retains attachments;
attachment persistence is a separate explicit option. Logout,
identity changes, reset, and session failure clear visible queue state; persisted
queue recovery requires successful authentication of the same partition. Hosts can
keep using direct `sendMessage()` to avoid queuing. No backend environment changes
are required.

One request runs at a time in enqueue order. A transient head item blocks subsequent
queued items until its retry delay completes; permanently failed/exhausted items stay
visible while later items may proceed. Network/transient errors use bounded exponential
jitter, and `Retry-After` remains a minimum even for explicit retry. After the automatic
budget, the user may retry a transient item with a fresh budget but the same original
UUID, frozen text, and expiry. Permanent errors expose their safe code and require
discard/correction; they are never automatically resent.

`disconnect()` (including screen background/close) pauses new attempts; `connect()`
resumes them. An already transmitted request may finish while paused. Headless hosts
must forward foreground/background transitions; no background network worker or
connectivity plugin is installed. HTTP availability is independent of WebSocket
readiness. While foregrounded, retries stop at the configured attempt budget.

Optimistic rows have separate `local_` IDs and queued/sending/failed state; their local
timestamps are display hints only. A canonical REST response, history row, or committed
realtime echo reconciles by **conversation ID + clientMessageId**. Echo-before-response
and lost-response races cannot create a second local row or restart an acknowledged
send. Canonical rows retain server timestamps, IDs, and delivery status. The composer
can accept another draft while an earlier message waits. Retry/discard controls are
per message, and refreshing/paginating history does not discard pending text.

Local tests cover offline FIFO, exact-payload retry, count/byte/age limits, retry budgets,
server retry hints, echo/response races, optimistic reconciliation, lifecycle pause,
logout fencing, and the offline/full-queue/discard screen flow. Native background,
physical-device process-kill recovery, and deployed-backend acceptance remain release checks.

## Secure outbox persistence and restart recovery

```dart
final client = await initializeChat(ChatClientOptions(
  publicChatAppId: publicChatAppId,
  baseUrl: apiOrigin,
  storage: const PlatformChatStorage(),
  persistSendQueue: true,
  // Verified hosts also supply identityTokenProvider + opaque identityKey.
  // Anonymous first-use creation/recovery still follows the explicit consent flow.
));
final id = await client.sendQueue.enqueueDurably(
  conversationId: conversationId, text: 'Keep this pending send across restart',
);
await client.connect(); // Restored queues remain paused until foreground activation.
```

`persistSendQueue` defaults to false and requires a secure storage adapter. The
example opts in. Synchronous `enqueue()` is memory-only; it rejects persistent queues
with `chat.durable_enqueue_required`. `enqueueDurably()` works in either mode, and
`ChatScreen` awaits it before clearing the draft. Await retry/discard as well: success
confirms their changed state was persisted; storage failure can leave the prior disk
record recoverable and is surfaced to the caller.

The outbox is a separate atomic encrypted record, isolated by API origin, Chat App,
identity partition, anonymous installation, and queue epoch. It never overwrites
rotating credentials or history checkpoints. Each record contains frozen text,
conversation/client message IDs, creation/expiry times, attempt count, send state,
safe error classification, and retry deadlines. It uses the existing device-local,
backup-excluded Keychain/Keystore adapter and read-back verification. No plaintext
fallback or additional credentials are introduced.

Enqueue is durably committed before it reports success. Each attempt's marker is
committed **before HTTP transmission**. An interrupted `sending` item restores as
queued with the same operation ID and consumed attempt count, or as failed if its
budget is exhausted. Retry-After and absolute expiry survive restart; recovery never
extends expiry and applies a shorter configured retention limit. Expired entries are
pruned before transmission. When the app is not running, physical deletion waits for
the next authenticated initialization; inaccessible storage cannot be purged until
it becomes available. Invalid/corrupt or over-limit records fail closed without
transmission. A changed partition/queue epoch cannot adopt an old outbox.

Canonical REST/history/realtime acknowledgement removes the item durably. If storing
that removal fails, known server acceptance remains visible, storage failure stops
new attempts, and restart retries use the original idempotent operation. Use
`await client.sendQueue.retryPersistence()` after repairing storage; the screen offers
“Retry secure storage”. Failed initial enqueue keeps the composer draft. There is no
automatic insecure fallback or unbounded storage retry.

`dispose()` drains already queued writes and retains the persisted outbox; logout,
anonymous reset, and account switch delete it. Logout also changes a credential-record
queue epoch, fencing stale records even when outbox deletion fails. A logout storage
error still means local durable deletion is unconfirmed and must be retried. Session
failure hides the queue without sending it; same-identity reauthentication may recover
it. Starting with persistence disabled deletes the current partition's old outbox.

The local suite simulates restart, interrupted accepted requests, attempt-marker
failures, retry budgets/deadlines, expiry/corruption, verified and anonymous recovery,
identity isolation, delayed-write disposal/logout, and failed-delete fencing. Real
Keychain/Keystore process-kill, backup/restore, and uninstall/device acceptance remain
open; these tests are not evidence of a physical-device qualification.


## Foreground attachments

Configure `ChatClientOptions.attachmentStorageOrigins` with the **exact origin**
of the existing backend's signed storage URLs, for example
`{Uri.parse('https://your-account.r2.cloudflarestorage.com')}`. Use the actual
configured endpoint, including a port when applicable; do not copy the placeholder.
This is public SDK host configuration, not a new backend environment variable.
Empty configuration disables transfers. HTTPS is required except on loopback;
subdomains, wildcards, user info, and redirects are not implicitly trusted.
The binary transport receives only the signed capability and exact content type,
never the Chat bearer token or cookies. URLs are never persisted or logged.

Pass a `ChatAttachmentPicker` to `ChatScreen.attachmentPicker`. It returns one
`ChatAttachmentSource(filename: ..., contentType: ..., bytes: ...)`, or null on
picker dismissal. Sources copy and expose immutable bytes; adapters must bound
reads before constructing them. The example provides a native `file_selector`
adapter, declared only in the example's dependencies. The SDK does not require a
picker plugin. Images have local thumbnails and on-demand, authenticated download
previews; other types show filename/size cards. Supply `onOpenAttachment` to hand
bounded, downloaded bytes to your host PDF/audio/video/text viewer. The host owns
that viewer's lifecycle and must close/purge it on account changes.

Headless usage, after `connect()` reaches `ChatConnectionState.connected`:

```dart
final upload = client.attachments.upload(conversationId, pickedSource);
// Listen to client.attachments.changes for state and sentBytes updates.
await upload.settled;
if (upload.state == ChatUploadState.ready) {
  final messageId = ProtodeskChatClient.newOperationId();
  await client.sendMessage(
    conversationId: conversationId,
    clientMessageId: messageId,
    text: 'Here is the file',
    attachmentIds: [upload.attachment!.id],
  );
  await client.attachments.release(upload);
}
```

Keep the same message ID, text, conversation and ordered attachment IDs when
retrying an uncertain send. Never fall back to a text-only send. The screen freezes
that payload after the first send attempt and lets the user retry or explicitly
discard the local draft. Discarding cannot retract a message already accepted by
the server. Attachment messages are sent online, outside the durable text outbox.
The server atomically enforces conversation ownership and claims all attachments.

Limits: 16 MiB per file, ten retained bodies and 64 MiB per client, three concurrent
upload/download operations, and ten attachments per message. New work is rejected
when full; older selections are not silently evicted. Progress means bytes handed
to HTTP, followed by a separate `processing` state while the server validates.
Only `ready` attachments can be submitted by the screen. Supported MIME/extension
pairs match the backend's image/audio/video/PDF/plain-text/CSV allowlist.

Failures remain visible. `retry(upload)` explicitly retries transient errors with
the same initiation/completion IDs, skipping PUT after a successful transfer.
In the default memory-only mode there is no automatic attachment retry loop;
expired or terminally failed uploads require removal and reselection. The managed
mode below adds bounded automatic retries and remote-generation recovery. `cancel(upload)` drops local bytes
immediately and attempts pending-upload cancellation; server cleanup failure is
reported, and ready objects follow backend unclaimed-object retention. `release`
drops local bytes after successful message send.

`disconnect()` and `attachments.suspend()` abort active binary transfers and leave
an explicit retryable interruption. Headless hosts must call one on backgrounding;
`ChatScreen` handles this and waits for reconnect after native picker dismissal.
Logout, reset, session loss and disposal purge owned sources and fence late results.
Image previews close on session/client change and evict their decoded image cache
on removal. No bodies or signed URLs enter the text outbox or history storage; safe server attachment metadata may appear in history checkpoints.

This is the default process-local foreground path. Existing session/text persistence
does not enable offline attachment persistence. Native viewer integrations and
physical-device picker/preview/storage acceptance remain open.


## Secure offline attachments and restart recovery

Opt in separately from text persistence:

```dart
final client = await initializeChat(ChatClientOptions(
  publicChatAppId: publicChatAppId,
  baseUrl: apiOrigin,
  storage: const PlatformChatStorage(),
  identityKey: hostAccountId, // Omit for anonymous sessions.
  identityTokenProvider: hostIdentityTokenProvider,
  attachmentPersistence: ChatAttachmentPersistencePolicy.managedPrivateCopy,
  attachmentStorageOrigins: {storageOrigin},
));
final upload = await client.attachments.uploadDurably(conversationId, pickedSource);
// This succeeds offline once the private copy AND encrypted journal are durable.
// Foreground connect/reconciliation wakes queued operations automatically.
await client.connect();
```

`disabled` remains the default. `managedPrivateCopy` requires secure session
storage and a usable `ChatAttachmentFileStore`; its default implementation is
`PlatformChatAttachmentFileStore`. Unsupported/unavailable storage fails with
`sdk.attachment_persistence_unavailable`, without any plaintext fallback or upload
mutation. Hosts may check `isAvailable()` on the file adapter. Android/iOS native
plugin registration is included; rebuild the host after adding this package.
No new backend environment variables or external storage package are required.

Android stores AES-256-GCM ciphertext in `Context.getNoBackupFilesDir()`, using a
non-exportable Android Keystore key and authenticated scope/partition/handle data.
Writes flush an encrypted temporary file before rename and directory flush. iOS
uses atomic writes with complete file protection, marks the private support
folder/files excluded from backup, verifies those attributes, and flushes the
file. The existing secure session-store backup requirements still apply.
Implementation references: [Android cryptography guidance](https://developer.android.com/privacy-and-security/cryptography),
[Apple complete file protection](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotection),
and [Apple backup exclusion](https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey).

The encrypted `.attachments` journal stores bounded operation metadata, a source
integrity digest, opaque file handles, retry/expiry state, and server upload IDs.
It never stores file bytes, picker paths/URIs, signed capabilities, API tokens,
object keys, or raw HTTP idempotency keys. Retry keys are derived from the stable
local operation and remote generation. A separate draft envelope in that atomic
journal freezes caption, ordered local upload IDs, and a logical draft UUID before
an attachment-message POST. The message UUID is derived from that logical ID.
Captions typed before the first Send attempt are not persisted.

After session authentication, initialization validates the journal and each
pending private source before exposing `pendingUploads(conversationId)`. No upload
runs until foreground realtime reconciliation reaches connected. Body copies no
longer depend on the picker URI. Recovery preserves selection order and original
conversation; `ChatScreen` restores selections and frozen send drafts when that
conversation opens. Navigating away or disposing the screen/client retains managed
work. Explicit Remove/Discard, logout, reset, account switch and session loss purge
it. The example intentionally logs out on normal navigation back, so test process
restart while the chat is open rather than logging out first.

The per-client limits remain ten selected operations, 64 MiB total selected size,
16 MiB per body and three active transfers. Files/operations expire 24 hours after
staging: active-process timers purge them, and startup removes expired records and
orphaned/old-identity copies before network work. Bodies are deleted after ready is
durably recorded; ready metadata remains until message claim, cancellation or expiry.
A successful send removes the corresponding operation/draft journal entries.

Uploads use write-ahead attempt markers, jitter and server Retry-After guidance,
and stop after six consecutive attempts, including across restart. `retry(upload)`
explicitly resets that budget while respecting the saved retry deadline. An
uncertain PUT probes completion before another PUT; an expired upload rotates only
the remote generation, preserving the local ID and ordering. A lost initiation
response retains its generation until the conservative 15-minute capability bound.
Known terminal validation/malware/scope errors do not auto-retry. Native lifecycle
suspension cancels transfers; only foreground activation resumes them. There is no
background upload service or push-triggered upload.

Use the client-owned helper for attachment sends:

```dart
final uploads = client.attachments.pendingUploads(conversationId);
if (uploads.isNotEmpty && uploads.every((u) => u.state == ChatUploadState.ready)) {
  final message = await client.attachments.send(conversationId, caption, uploads);
}
```

The helper commits the complete ordered payload before POST and retains it after
an uncertain response. `pendingDrafts` exposes that frozen payload after restart;
retry it unchanged. Recovery never reuploads a ready attachment or silently sends
only text. Sends are user-triggered; restoring a draft does not automatically send
it. Removing an attachment explicitly discards the frozen draft and permits a new
normalized send. Direct `sendMessage` callers own their retry authority themselves.

Storage-write/deletion failures block subsequent managed work and surface a safe
error; `retryPersistence()` retries the journal/ready-body cleanup. Missing or
changed sources fail closed with `sdk.attachment_source_unavailable`.
`replaceSource(upload, source)` recovers only a replacement with identical filename,
MIME type, size **and digest**; otherwise remove and select a new operation.
Cleanup never uses a new account's credentials. Logout attempts pending remote
cancellation with the captured old token before revocation; late/unknown uploads
remain subject to backend retention.

Local coverage includes restart, lost PUT/send responses, remote expiry, retry
budget restoration, partial storage failure, orphan cleanup, missing/corrupt files,
concurrent staging bounds, source replacement, identity epochs and recovered UI.
Android plugin compilation and iOS SDK type-checking pass. Full Android packaging
was blocked by local disk space; physical-device Keystore/Data Protection, locked
storage, backup/restore, actual process death and deployed-provider acceptance are
still required. Local fake-store tests do not prove those device guarantees.

## Unread counts, read reporting, and typing

`await client.getUnreadCount()` fetches the authoritative customer-wide bootstrap
count and refreshes `client.typingEnabled`. Never sum a paginated conversation list.
For a reactive badge, own a `ChatUnreadController(client)`, subscribe to `changes`,
and display `count` only when `isStale` is false. It batches event/read-report
invalidations over 500 ms, refreshes after reconnect, ignores responses invalidated
while in flight, and clears on identity changes. Errors retain a stale value;
call `refresh()` to retry. Dispose the controller with its badge. Counts are
snapshots, not an offline guarantee; per-conversation `unreadCountIsStale` still
requires refreshing conversation history.

```dart
final read = await client.markRead(
  conversationId: conversation.id,
  throughMessageId: visibleMessage.id,
);
// read.unreadCount is authoritative at the response snapshot.
```

Only report a canonical message actually read by the user. The backend keeps the
cursor monotonic across devices and retries. Read reports are not persisted or
queued offline; retry an uncertain result using the same boundary. Merely fetching history never marks it read. `ChatScreen` automatically reports
canonical incoming messages whose **entire tile stays visible for one second**
while scrolling is idle and the current route/tab and app are active. It uses
actual viewport geometry, excluding offscreen cached tiles and tiles taller than
the viewport. Scrolling, route coverage,
backgrounding, picker/preview activity, and conversation changes reset the dwell.

Visible eligible messages coalesce to the newest read boundary. As with manual
reporting, the backend cursor marks all preceding messages read; it is not a
per-message attention record. Reports are single-flight, successful boundaries
are suppressed for the current conversation view, and failed automatic attempts
wait for visibility to reset (or manual retry) rather than looping. No read queue
is persisted. Late responses after navigation or identity changes cannot update
the new screen. Aggregate unread counts refresh after success.

Set `ChatScreen(automaticReadReporting: false, client: client)` for host-controlled
read semantics; the screen then reports nothing and shows no read control, and the
host calls `client.markRead` itself. Hosts with custom overlays/clipping should disable automatic reads
unless the screen is hidden using route coverage, `Offstage`, `IndexedStack`, or `TickerMode`; arbitrary host
overlays cannot be inferred. One second of full visibility is a UI heuristic,
not proof that a person read the content. Live-device acceptance remains open.

Call `client.setTyping(conversationId, true)` on real composer changes, and `false`
on send, clear, or navigation away. Bootstrap must first advertise typing support;
`ChatScreen` loads it automatically. Sends require a connected socket, throttle
refreshes to three seconds, stop after five seconds idle, and never enter the
outbox. Disconnect/background clears ephemeral state. Custom hosts should stop
on route coverage/focus loss and disconnect when backgrounded.

`typingChanges` includes `ChatTypingActor` (`kind` and optional opaque `id`).
Use `client.typingAgents(conversationId)` for active support actors; `isTyping`
remains an aggregate of customer and agent signals for existing headless hosts.
Each actor has independent ordering, expiry and stop handling, bounded to 128
tracked conversation/actor entries. Customer echoes and legacy actor-less frames
never become agent indicators. Invalid actor frames are ignored without affecting
replay. The preview displays “Support is typing…” or “Support agents are typing…”.
Staff names, emails and internal IDs are intentionally absent; actor IDs are stable
only within a customer conversation and must not be used as profile identifiers.

The backend staff command is `POST /app/conversations/{externalId}/typing` with
`{ "typing": true, "sourceId": "<per-composer UUID>" }`. Authentication supplies
workspace membership and staff identity; current thread reply permission, team
visibility, app/customer availability and writable-conversation checks precede
publication. Source IDs aggregate tabs for each agent so one tab cannot stop
another. Starts refresh at most once per three seconds and expire after eight.
The existing realtime broker carries these signals across instances without
writing them to the durable outbox. Deploy actor-aware backend/broker instances
together before qualifying the feature; older strict broker decoders can drop
agent notifications during mixed-version rollout.

The staff web composer's public Chat draft edits call this endpoint with no body
content or actor claims. Notes, other channels, blur/background/offline, send,
conversation change and cleanup stop or suppress signals. Lost stops expire;
starts are never queued for later retry. This wiring does not change the web
app's existing live-chat send availability policy or enable a disabled channel.

Local engagement tests cover boundary reporting, logout races, authoritative totals,
coalesced invalidation during requests, capability-gated typing, throttle/idle/expiry,
reordered frames, disconnect, and explicit UI reporting. Live multi-device/backend
acceptance remains outstanding. No backend configuration variables were added.

## Explicit anonymous-to-verified merge

After the host authenticates the user and the user explicitly chooses to carry
anonymous Chat history into that account:

```dart
final outcome = await client.mergeAnonymousIdentity(
  () => hostBackend.mintFreshChatIdentityToken(),
  identityKey: hostAccountId,
);
// A successful response returns ChatIdentityMergeOutcome.confirmed.
```

The provider must mint a fresh, single-use identity token for the same Chat App
and authenticated account represented by `identityKey`. The key is a local
partition label, not proof of identity. The SDK checks `identityMerge` capability,
sends the current anonymous bearer once, and adopts the server's verified session.
`identify()` still switches accounts without implicitly merging history.

The operation refuses queued/failed/sending text, outstanding attachment work
(including private-copy staging), and in-flight mutations with
`chat.identity_merge_pending_work`. Finish these or explicitly discard them first;
they are never silently transferred. Hosts also own unsent composer drafts and
should resolve them before starting the identity change. Concurrent merges are
rejected. The SDK freezes traffic, clears anonymous history/cursor/typing, fences
late callbacks, and restores the verified account's own isolated queues. Connected
clients reconnect and reconcile authoritative history. A definitive rejection,
such as `chat.identity_merge_conflict`, restores the original anonymous identity.

With secure storage, a write-ahead marker precedes the merge request. Confirmed
adoption saves verified credentials before retiring anonymous proof and deleting
its history/outbox metadata. No identity JWT is persisted. Storage failure blocks
adoption and known abandoned issued sessions are revoked.

A timeout, lost response, or failed adoption returns `chat.identity_merge_uncertain`
and leaves the client failed. **Do not replay the merge or reuse the identity
JWT.** After checking the host is still signed into the same account, recover with:

```dart
final outcome = await client.recoverIdentityMerge(
  () => hostBackend.mintFreshChatIdentityToken(),
  identityKey: hostAccountId,
);
// recoveredUnconfirmed: verified sign-in succeeded; merge commitment is unknown.
```

Recovery performs a fresh verified exchange, not another merge. The backend may
have committed the original merge; if it did not, signing in cannot manufacture
that history transfer. `identityMergeOutcome` preserves this distinction. Secure
anonymous proof is retained but blocked from automatic reuse when recovery is
unconfirmed; inspect/reconcile missing history before explicitly starting fresh.

After process restart, initialize with the same `identityKey`, secure storage and
fresh `identityTokenProvider`. A matching pending marker forces a fresh verified
exchange, even if older verified credentials exist. Anonymous initialization
(including create/recover flags) refuses a pending or retired merge source with
`chat.identity_merge_recovery_required`. After completed local handoff,
`continueAnonymously()` is an explicit fresh anonymous identity, never resurrection
of the merged source. Memory-only clients cannot retain the recovery marker across
process death; the host must sign into the intended verified account explicitly.

Local regression coverage includes confirmed adoption, capability rejection,
queued/in-flight work, conflicts, token-provider failure, secure marker ordering,
restart recovery, failed credential adoption, late logout/REST callbacks and replay
cursor isolation. Real backend/device identity-merge acceptance remains a release
gate. No backend environment variables or schema changes are required.

### Provider-neutral push targets

The host owns Firebase/APNs/OneSignal initialization, notification permission,
user opt-in, and token listeners. The core package adds no provider dependency.
After `client.ready`, capture one identity-bound handle in the listener:

```dart
final push = client.createPushTargets();
await push.register(
  provider: ChatPushProvider.fcm, // apns (iOS) or onesignal also supported
  target: providerToken, // OneSignal subscription ID, never an external user ID
  installationId: installationId, // host-owned stable installation UUID
  permissionGranted: notificationsAllowed && userOptedIn,
);
// Call register again with the replacement token on provider token refresh.
// It uses PUT once this handle has registered successfully.
await push.unregister();
```

Keep the installation UUID in host storage appropriate to the installation; it
is not authentication. Do not reuse it across devices. Provider/platform routing,
provider validation, quotas, and anonymous policy are enforced by the backend;
registration errors are surfaced without enabling a disabled route.

On permission denial or opt-out, stop the token listener, await any outstanding
registration, and call `unregister()`. `permissionGranted: false` rejects new
registration; it does not revoke an existing registration. Concurrent operations
fail with `chat.push_busy`; serialize provider callbacks and retain only the
latest pending token in the host. There is no background registration queue.

On logout/account switch, stop the listener and await `client.logout()` or
`client.identify(...)`. Backend session revocation transactionally revokes its
push targets, including registrations whose responses are still in flight.
Old handles reject later callbacks with `chat.operation_cancelled`. Create a new
handle after successful login, merge, or reset/reinitialization and explicitly
register the current token if permission and opt-in still allow it. A failed
remote logout is surfaced; local credentials are cleared, but do not claim remote
revocation succeeded. `dispose()` alone does not revoke the backend session.

After process restart, obtain the current provider token and register again.
The backend reconciles the installation. With secure session storage configured,
the SDK stores only the target ID in an identity-scoped routing journal so opt-out
after restart can unregister it. Raw provider tokens are never persisted. For an
uncertain registration response, retry with the same
explicit `idempotencyKey` and identical arguments. Never reuse a key for a changed
token. If the initial response was lost, unregister has no target ID: recover it
with that retry, or log out to revoke all targets for the session. Tokens are
passed only to the authenticated registration endpoint and are not logged by the
SDK. Copyable native adapters and notification navigation are available below;
physical-device/provider acceptance remains open.


### Native adapters and notification navigation

See the copyable provider adapters (`examples/push_adapters/README.md`) for FCM,
direct APNs, OneSignal, cold-start setup, permission changes, and account cleanup.
They live in a separate example package; the core has no provider dependency.
`ChatPushRegistrationBinding` serializes callbacks, coalesces pending tokens, and
retains failed operation keys only in memory for explicit recovery.

Use `startChat(options)` when tap listeners must attach before sign-in finishes;
observe `client.ready` immediately and dispose on failure. Create an identity-
scoped `client.createPushNavigation(onNavigate: ...)`, forward **tap** data via
`handlePushPayload`, and call `setReadiness(active: ..., navigatorReady: ...)`
on host lifecycle/navigation changes. `isProtodeskPush(data, publicChatAppId: ...)`
recognizes the versioned, app-specific envelope without claiming authorization.

One newest tap waits in memory for at most two minutes; duplicates are bounded
and do not extend expiry. Navigation waits for authenticated conversation lookup
and session refresh, and is fenced by identity changes. The synchronous host
callback receives the resolved `ChatConversation` and returns whether its router
accepted the route. `ChatScreen(initialConversationId: conversation.id)` opens
that history directly. Successful routing reports notification-open best-effort;
read status still requires actual message visibility. Observe `navigation.errors`
for lookup/reporting failures. Dispose and recreate navigation after identity
changes; the controller never follows accounts automatically.

## Themes, language, and accessibility

Import `protodesk_chat_ui.dart` and configure the host app:

```dart
MaterialApp(
  theme: ChatTheme.light(), // Protodesk primary #00A5D1 by default
  darkTheme: ChatTheme.dark(),
  localizationsDelegates: ChatLocalizations.localizationsDelegates,
  supportedLocales: ChatLocalizations.supportedLocales,
  home: ChatScreen(client: client),
);
```

The messenger opens on Home (`initialSection`): the Chat App's header title and
a "Continue conversation" or "Send us a message" card, the most recent other
conversation, and configured HTTPS links. A bottom navigation switches between
Home and Messages, with the unread total on Messages; it is hidden inside a
conversation. Pass `onOpenLink` (for example `url_launcher`'s `launchUrl`) to
show and open those links; without it they are hidden. `openChat` accepts
`initialSection` and `onOpenLink` too.

When the Chat App has published Help content, a Help tab and Home's "Find an
answer" panel appear (search plus up to three featured articles, or topics).
Help mirrors the web widget: search (2+ characters, debounced), topics with
article counts, collection and all-article listings with "Load more", and
articles with "On this page", Compact Help Markdown (headings, lists, tasks,
quotes, tables, copyable code, HTTPS images), related articles, a "Contact
support" hand-off that starts a conversation, a language menu when the Help
Center has several locales, and "Open in Help Center" via `onOpenLink`. Back
(button or system gesture) walks the Help stack first. The tab is hidden when
Help is disabled or the server reports `chat.help_center_unavailable`.

Phones get a bottom navigation bar; layouts 840 px or wider get a navigation
rail with the content in a centred 720 px column. At very large text sizes a
conversation scrolls as a whole so the composer stays reachable.
`test/src/messenger_quality_test.dart` checks tap targets, labels and contrast in
every view and theme, plus 2×/3× text, landscape and right-to-left layout; see
`docs/livechat-quality-audit.md`.

Without a `theme`, the messenger uses the Chat App's brand colour and preferred
colour scheme from `getConfiguration()` once loaded (falling back to the host
Theme), plus its name, logo and greeting. Pass `theme` to override colours and
fonts. Pass `onClose` to show a close button; `openChat` does this and pops its
route.

English and Indonesian follow the host locale, with English fallback. To scope
branding or wording to chat, pass `ChatScreen(theme: ..., localizations:
ChatLocalizations(const Locale('id'), overrides: {ChatText.support: 'Bantuan'}),
client: client)`. `ChatTheme.light/dark` accept `brandColor`, `fontFamily` and
`textTheme`. The theme mirrors the Protodesk mobile app's design system: zinc
neutrals, hairline borders, filled fields, 8 px buttons, flat 12–16 px cards and
neutral navigation, with the brand colour in place of the app's blue accent. The
brand fills buttons and badges exactly; the customer's bubbles use a light brand
tint. Text, links, icons and focus rings use `ChatBrandColors.foreground`, the
brand shifted just enough for 4.5:1 contrast on the surface. The SDK downloads
no fonts; pass Inter through `fontFamily` to match the app.
provide fonts through your app assets. Locale/theme changes preserve the draft
and current conversation. Customer messages, filenames, and server subjects are
not translated. Machine-readable SDK errors remain available to the host while
the prebuilt screen displays localized recovery text.

The screen targets WCAG 2.2 AA on Android/iOS: protected 48-pixel control targets,
named previews, status announcements, keyboard focus, wrapping actions, enlarged
text, and reduced-motion previews. Host themes retain their colors/type; validate
custom contrast and typography. Physical VoiceOver/TalkBack and complete host
navigation acceptance remain required. See review and acceptance boundaries (`docs/ui-accessibility.md`).

## Runnable host examples

The native example project has separate anonymous and verified entry points:
`flutter run -t lib/main_anonymous.dart` and
`flutter run -t lib/main_verified.dart` (run from `example/`). The verified example
uses an authenticated host endpoint for account identity and fresh tokens; no
server secret or new environment variable is needed in Flutter. See the
example setup and host endpoint contract (`example/README.md`).

## Setup diagnostics and runtime capabilities

Use `validateChatSetup(...)` for offline public-configuration checks and
`await client.inspectCapabilities(...)` for an authenticated server/local snapshot.
Reports distinguish unavailable, missing adapters, missing configuration, denied
permission and unknown evidence. `toJson()` and `toString()` contain fixed enum
names only. See setup diagnostics (`docs/setup-diagnostics.md`) for integration,
remediation and the native checks the host must supply. Both example entry points
include a **Check setup (offline)** action. No new environment variables are needed.

## Golden and integration tests

`flutter test` includes reviewed UI golden baselines and anonymous/verified real
HTTP/WebSocket fixture tests. The example's `integration_test/chat_native_test.dart`
exercises actual native secure storage, queued-send recovery and account
isolation. Protected-file acceptance has a separate physical-device harness. See test commands and acceptance boundaries (`docs/testing.md`).

## Release preparation

Run `bash tool/check_release.sh` with Flutter 3.47.5 / Dart 3.13.4 to validate
the SDK, examples, API docs, and an isolated pub.dev candidate. The source remains
unpublished. See `docs/releasing.md` for artifacts, supported toolchain, and
remaining publisher and physical-device release gates.

## License

Copyright 2026 Protodesk. This Flutter SDK is licensed under Apache-2.0; see
`LICENSE` and `NOTICE`. This grant covers this SDK repository, not the separate
Protodesk backend or other repositories. Third-party dependencies retain their
own licenses.

## Convenience presentation and lifecycle

With `protodesk_chat_ui.dart`, call `await client.openChat(context)` to wait for
initial readiness and present a client-bound Material route with a close button.
Dismissal preserves the session. `client.openHelpCenter(context)` opens on the
Help tab and `client.openHelpCenterArticle(context, articleId)` on one published
article (its public Help API ID; Back returns to the Help home). Both fall back to
Home when the Chat App has no published Help. `ChatMessenger(initialSection:,
initialHelpArticleId:)` does the same for hosts that build their own route. Observe `client.sdkLifecycleEvents` for typed session-ready, mounted
chat open/close, and accepted push-open events. The stream is lazy, broadcast,
and has no replay. See `docs/presentation-lifecycle.md` for custom UI tracking,
Navigator selection, options, and ownership semantics.
