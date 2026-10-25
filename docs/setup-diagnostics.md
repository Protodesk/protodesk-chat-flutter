# Runtime capabilities and secret-safe setup checks

Use the offline validator before constructing `ChatClientOptions`. It accepts
public configuration and boolean evidence, but never calls a token provider,
reads secure storage/configuration files, requests permission, writes data, or
contacts a server:

```dart
final preflight = validateChatSetup(
  publicChatAppId: publicChatAppId,
  apiOrigin: apiOrigin,
  platform: 'ios', // Actual host platform; Android hosts use 'android'.
  verified: true,
  hasIdentityKey: authenticatedAccountKey.isNotEmpty,
  storageConfigured: true,
  storageIsSecure: true,
  persistSendQueue: true,
  attachmentOrigins: ['https://your-public-storage-origin.example'],
);
print(preflight); // Only fixed check names/statuses, never the input values.
```

The default runtime platform comes from `Platform.operatingSystem`, not the UI
Theme. `runtimePlatform` is an explicit test/cross-build override; overriding it
does not make another platform supported. This native preview requires Dart
>=3.12 and Flutter with the dependencies in pubspec.yaml; package resolution and
`flutter analyze` validate that build-time framework boundary. The doctor does
not inspect SDK installations or certify unsupported web/desktop builds.

After `await client.ready`, request an explicit authenticated capability snapshot:

```dart
final report = await client.inspectCapabilities(
  host: ChatHostChecks(
    pushProvider: ChatPushProvider.fcm,
    pushAdapterInstalled: hostAdapterInstalled,
    notificationsPermitted: hostNotificationsPermitted,
    notificationHandlerCompatible: hostHandlersCoexist,
    entitlementsValid: hostNativeConfigurationVerified,
  ),
  probeAttachmentStore: true, // Optional native availability query only.
);
final safeJson = report.toJson();
```

Leave host values null when they have not been checked. The core SDK does not
link optional provider SDKs and cannot inspect their notification delegates,
permission settings or signed app entitlements. Host evidence must come from the
actual integration; the SDK never guesses or prompts for permission. In
particular, verify iOS push/Keychain entitlements, Android backup exclusions and
notification permission, provider initialization, and coexistence with existing
notification handlers. A host false value reports a failed setup check; unknown
is not a pass. Optional push failures do not mean text chat is unusable.

`inspectCapabilities` requests `/v1/chat/bootstrap` (10-second deadline). Its
normal authenticated request may refresh the session using the host provider and
persist renewed credentials. It does not send diagnostics elsewhere. The optional
attachment-store availability query has a 3-second deadline and performs no file
read/write. Secure storage itself remains `unknown` when configured: a configuration
flag cannot prove that a locked device's Keychain/Keystore is accessible.

## Interpreting the report

| Status | Meaning |
| --- | --- |
| `available` | The reported feature prerequisites are satisfied in this snapshot. |
| `unavailable` | Server disabled the feature, platform is unsupported, or the explicit native probe failed. |
| `notInstalled` | Host reports the push adapter is absent. |
| `notConfigured` | Required local configuration or the chosen server push provider is missing. |
| `notPermitted` | Host reports notification permission/opt-in is denied. |
| `unknown` | Missing/malformed server evidence, failed request, unchecked host setup, or unprobed native access. |

Push delivery also checks the selected provider against the server's configured
providers and anonymous push availability for an anonymous session. Missing data
never enables a feature. An available push capability does not prove target
registration, delivery, background execution, or a successful physical-device tap.
Reports are immutable point-in-time snapshots, not authorization or subscriptions;
refresh them after account, permission, provider or backend configuration changes.
An account switch/logout during inspection cancels the result with
`chat.operation_cancelled`, preventing an old account's snapshot from being used.

| Failed/unknown setup check | Next action |
| --- | --- |
| `publicAppId` | Use the public `chat_test_…` or `chat_live_…` ID, never a secret. |
| `apiOrigin` | Use an HTTPS origin without userinfo, path, query or fragment; HTTP is allowed only on loopback. |
| `platform` | Match the actual Android/iOS runtime; the UI theme does not select the runtime. |
| `secureStorage`, `sendQueue` | Configure a platform-secure adapter before enabling durable sends. |
| `identityPartition` | Resolve a stable opaque account key from authenticated host state. |
| `attachmentOrigins`, `attachmentPersistence` | Allowlist exact storage origins and configure secure storage for managed copies. |
| `entitlements` | Verify signed native entitlement and backup configuration in the host build. |
| `pushAdapter` | Install/initialize the host's selected provider adapter. |
| `notificationPermission` | Inspect permission and host opt-in; request permission through the host's own UX. |
| `notificationHandler` | Verify existing handlers coexist rather than overwrite one another. |
| `serverSnapshot` | Check authenticated connectivity and retry explicitly. |

Serialization includes only enum names: no API URL, public app ID, identity key,
tokens, filenames, account data, message content, exception strings or arbitrary
server fields. This includes malformed inputs and failed server responses. Do not
append original options or exception objects to support logs. The example apps'
**Check setup (offline)** action displays this same safe preflight; verified
partition readiness is checked after host authentication, not by reading its token.
