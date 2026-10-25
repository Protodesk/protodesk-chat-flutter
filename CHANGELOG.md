## 0.1.0-dev.1

Unpublished native integration preview: memory-only sessions, conversations,
text messages, realtime reconnect, explicit logout, basic screen and local tests.

Secure persistence increment: optional Keychain/Keystore adapter, account-partitioned
session restore, refresh write-ahead fencing, anonymous proof generations and
acknowledgement, explicit storage-loss recovery/reset, and logout/write race tests.

Durable realtime increment: atomic encrypted recent-history/cursor checkpoints,
ready-boundary REST reconciliation, persisted replay deduplication, bounded frame
queue, rejected-cursor recovery, committed UI snapshots, and recovery/race tests.

Incremental realtime: local message/conversation reducers with resource-version
checks, pagination-boundary preservation, explicit unread-count freshness, and
request-count regression tests. Read events retain a targeted conversation refresh;
reconnect/resync still use authoritative REST reconciliation.

History pagination: headless ChatHistoryController, single-flight page loads,
version-aware page/realtime merging, cursor retry and invalidation handling,
lazy conversation/message lists with older-page and end controls, and race/widget
coverage. Full history is on-demand in memory; secure checkpoints remain recent-only.

Optimistic text sends: client-owned bounded memory queue, frozen operation IDs,
FIFO retries with Retry-After and attempt limits, age/size/count bounds, canonical
REST/realtime reconciliation, foreground pause/resume, and identity purge. The
screen now exposes per-message queued/sending/failed, retry, and discard states.

Secure outbox recovery: opt-in encrypted identity-scoped records, awaited enqueue
and mutation durability, pre-request attempt markers, restored retry/expiry bounds,
foreground-only restart activation, disposal write draining, and logout epoch fencing.
Storage errors stop transmission; the example enables persistence.


Foreground attachments: immutable bounded sources, host picker adapter and native
example picker, conversation-bound initiation/PUT/completion, cancellable binary
transport with exact-origin checks, progress/validation states, explicit stable-ID
retry, scoped downloads, image previews/file cards, and atomic attachment-message
send retries. Lifecycle/account cleanup and local HTTP/unit/widget regressions are
covered. Attachment bytes and capabilities remain memory-only; managed-private-copy
restart recovery and device acceptance remain pending. No backend env vars added.


Managed offline attachment recovery: explicit `managedPrivateCopy` policy, native
Android Keystore/AES-GCM no-backup files and iOS complete-protection/excluded files,
verified copies before journal commit, scoped metadata/digest validation, orphan
cleanup, 24-hour retention, foreground bounded retries and remote-generation
rotation. Pending selections and frozen attachment-message retries survive restart;
ready bodies are removed, account/logout/reset purges are fenced, storage failures
block progress, and exact-source replacement is supported. The example exposes a
separate opt-in checkbox. Device security/process-death acceptance remains open.

Unread/read/typing increment: authoritative aggregate badge controller with batched
invalidation and stale-response fencing, explicit canonical read boundaries and
preview controls, capability-gated throttled/idle-stopped customer typing, bounded
expiry/order tracking and lifecycle cleanup. Actor-aware agent typing follows in the increment below.

Automatic viewport reads: whole-tile one-second dwell at rest, active route/tab/app
checks, scroll/lifecycle/preview resets, newest-boundary coalescing, single-flight
reporting and stale-response fencing. Oversized tiles retain manual reporting;
hosts may disable automatic reads. Widget coverage includes offscreen content,
route coverage, backgrounding, scrolling, opt-out, failures and logout races.

Actor-aware agent typing: additive typed actor metadata, independent per-agent
ordering/expiry/stops, customer-echo suppression, support indicators and headless
`typingAgents`. Companion backend staff command derives scoped opaque actors and
uses existing cross-instance fanout; the web public Chat composer publishes
content-free activity. Existing channel availability policies are unchanged.

Explicit anonymous identity merge: capability-checked one-shot merge with pending
work guards, authoritative verified adoption, anonymous cursor/cache isolation,
secure write-ahead markers, confirmed versus unconfirmed recovery outcomes, fresh
verified exchange on recovery/restart, and late-issued-session revocation. Normal
identify remains account switching. No JWT or anonymous drafts cross partitions.
- Add identity-bound provider-neutral push handles for FCM, APNs, and OneSignal
  registration/token refresh/unregister, explicit permission gating, idempotent
  retries, and logout/account-switch fencing. Raw tokens are not persisted.

- Add copyable FCM, APNs, and OneSignal adapters in an optional example package,
  bounded registration callback serialization, strict notification payload parsing,
  identity-scoped deferred navigation and open reporting, cold-start `startChat`,
  and `ChatScreen.initialConversationId`. Physical-device/provider beta remains open.
- Persist only routing target IDs in identity-scoped secure storage for opt-out
  after restart; clear on logout/reset and migrate after confirmed identity merge.

UI customization: host-inherited or scoped themes, Material light/dark brand helpers,
English/Indonesian UI catalogs and overrides, localized recovery text, accessible
preview names/status announcements, protected targets, keyboard focus, reduced
motion, and layouts for enlarged text and short keyboard viewports. Local widget
checks pass; physical-device accessibility acceptance remains open.

Host examples: separate anonymous and verified runnable entry points sharing the
native shell, secure persistence and attachments. The verified example resolves
its storage partition from an authenticated host endpoint, fetches fresh identity
tokens, rejects account changes/redirects and clears its in-memory host credential
on exit. Added setup/host-contract/device acceptance guidance and regression tests.

Diagnostics: offline secret-safe setup validation and explicit authenticated runtime
capability snapshots, with immutable allowlisted output, host-reported native/push
evidence, provider/anonymous policy checks, bounded optional attachment availability
probes and account-change fencing. Example preflight action and setup guide added.

Test coverage: four reviewed light/dark, English/Indonesian, enlarged-text,
empty-history and offline-queue golden baselines; anonymous and verified native
HTTP/WebSocket protocol flows; device integration harness for actual secure storage,
account-isolated outbox restoration and UI logout, plus a separate hardware
acceptance harness for protected attachment files. iOS Simulator lacks the required
protection metadata; the native adapter continues to fail closed.

Release preparation: isolated allowlisted pub.dev staging, API documentation,
local validation gate, and CI candidate artifacts with version/tag checks and
checksums. Publication remains disabled pending release acceptance.

License: apply Apache-2.0 to the Flutter SDK, include LICENSE/NOTICE in release
candidates, and align iOS podspec metadata.

Presentation/lifecycle: instance-bound openChat with explicit readiness and
Navigator ownership, lazy broadcast content-free activity events, automatic
ChatScreen mount/unmount tracking, custom surface tracking, and identity-fenced
push-open events independent of backend reporting success.

Conversation context and contact: typed `ChatConversationContext` with
fail-safe provenance parsing, validated `ChatCreateConversationContext` and
`initialContext` defaults, external-object references, `getConversation`, and
`identityKind`. Optional anonymous contact read/share/dismiss with idempotent
retry keys. `ChatScreen` adds a provenance-labelled origin line (loaded by ID for
push/initial navigation) and an inline English/Indonesian contact prompt.
Goldens updated; the Dart/TypeScript contract sketches now include contact
operations and conversation lookup.

Livechat UI phase 1 (headless): typed `ChatAppConfiguration` from bootstrap with
identity-scoped caching, Help Center manifest/article/search APIs with local
validation, `ChatHelpController` (locale memory, per-locale caches, pagination,
identity fencing), and a pure-Dart Compact Help Markdown parser ported from the
web widget with heading outline IDs.

Livechat UI phase 2: `ChatMessenger` (with `ChatScreen` alias) restyled after the
web widget — Messages section with conversation cards, unread counts and empty
state; thread header with brand mark, app name, live connection status, back and
optional close (`onClose`, wired by `openChat`); start/end message bubbles,
labelled automated notices, configured greeting with brief typing, empty-thread
guidance, awaiting-reply note, closed-conversation notice with a disabled
composer, rounded composer with icon send, "Powered by Protodesk", and a 720 px
centred column on wide screens. Chat App branding (colour, scheme, name, logo)
applies unless the host passes a theme. The manual "Mark read" action now shows
only when automatic read reporting is off. Goldens re-baselined with pinned local
times plus a new Messages golden.

Livechat UI phase 3: Home section (default `initialSection`) with a branded intro
(logo or initial, app name, live status, header title, welcome copy), an
overlapping "Continue conversation" / "Send us a message" card, the recent other
conversation and configured links via the new `onOpenLink` adapter; Material 3
bottom navigation for Home and Messages with the unread total, hidden in a
thread. `openChat` forwards `initialSection` and `onOpenLink`; the example app
opens links with `url_launcher`. New Home goldens (light English; dark
Indonesian at 2× text) and navigation tests.

Livechat UI phase 4: Help tab and Home "Find an answer" panel, shown only when
Help is configured and published. Search with minimum length and debounce,
topics and listings with pagination, article view with outline navigation, a
native Compact Help Markdown renderer (links via `onOpenLink`, copyable code,
tables, task lists, HTTPS images with size presets), related articles, contact
hand-off, language menu, open-in-Help-Center, back/system-back handling, and
article text direction from the Help locale. English/Indonesian Help copy ported
from the web widget. New Help screen tests and Help root/article goldens.

Livechat UI phase 5: dynamic conversation setup (pre-chat text/email/select/
checkbox fields with required markers and web-equivalent validation, routing
choices, greeting/intro heading) before any new conversation when the Chat App
requires it; stale-form recovery that reloads configuration; host-supplied
values still skip the form. "Start over" in a thread's options menu with a
confirmation dialog, failure message, and fresh anonymous sign-in. Fixed Home's
overlapping card not receiving taps on its upper edge. The setup rule now
matches the web (an enabled form without fields still shows its intro step).
New setup tests and golden.

Livechat UI phase 6: `openHelpCenter` and `openHelpCenterArticle` entry points
plus `ChatMessenger.initialHelpArticleId`; a directly opened article sits above
the Help home and learns its slug for "Open in Help Center"; Help shows at once
while configuration loads and falls back to Home when unavailable. Fixed Help
resetting to its home on first load (which discarded directly opened articles).
The example app presents through `openChat` and adds "Open Help Center"; its
widget tests now exit through the messenger's Close button (they had relied on
an AppBar back button removed in phase 2). Contract README and strategy note the
entry points.

Livechat UI phase 7 (quality pass): executable accessibility and stress sweep
over all six messenger views (tap targets, labels, contrast in light/dark;
2×/3× text, landscape, right-to-left). Fixed Help touch targets, Help and code
block overflow at large text, conversation overflow at 3× text, Help confined
to the conversation pane in compact mode, and wasted compact space; capped
header titles at two lines; added a navigation rail for wide layouts based on
the messenger's own width. Tablet goldens for Home and Help. Audit report in
`docs/livechat-quality-audit.md`; device acceptance remains open.

Design system: `ChatTheme` now mirrors the Protodesk mobile app (`AppTheme`):
zinc neutrals, hairline borders, filled inputs, 8 px buttons, flat cards,
neutral navigation without an indicator, the mobile type scale and rounded
icons. The default brand is the web widget's cyan `#00A5D1`; brand colours (default
or Chat App) are used exactly for fills instead of Material's derived tone.
Customer bubbles are brand-tinted with a brand border, agent bubbles raised
neutral, and the composer is one bordered surface with a brand send arrow.
On-surface text, links and icons use `ChatBrandColors.foreground`, a
contrast-safe shade of the brand; control outlines stay at 3:1.

Simplified conversation view: removed the "Mark read through here" control
(hosts that disable automatic reads call `client.markRead`), the business
context/provenance line (support-facing, still on `conversation.context`), the
"Beginning of conversation" note and the "Connected" status while connected
(connecting/offline still show). Shorter contact-prompt copy.
