import 'dart:convert';
import 'dart:io';

import 'push.dart';

/// Unknown is deliberately distinct from disabled or missing installation.
enum ChatCapabilityStatus {
  available,
  unavailable,
  notInstalled,
  notConfigured,
  notPermitted,
  unknown,
}

enum ChatCapability {
  attachments,
  typing,
  identityMerge,
  notificationReporting,
  pushRegistration,
  pushDelivery,
  secureStorage,
  attachmentPersistence,
}

enum ChatSetupCheck {
  publicAppId,
  apiOrigin,
  platform,
  secureStorage,
  identityPartition,
  sendQueue,
  attachmentOrigins,
  attachmentPersistence,
  entitlements,
  pushAdapter,
  notificationPermission,
  notificationHandler,
  serverSnapshot,
}

enum ChatCheckStatus { passed, failed, unknown, notApplicable }

/// Evidence supplied by the host, never inferred from credentials or token values.
/// Null means unverified. Do not report true until the host has checked it.
final class ChatHostChecks {
  const ChatHostChecks({
    this.entitlementsValid,
    this.pushProvider,
    this.pushAdapterInstalled,
    this.notificationsPermitted,
    this.notificationHandlerCompatible,
  });
  final ChatPushProvider? pushProvider;
  final bool? entitlementsValid,
      pushAdapterInstalled,
      notificationsPermitted,
      notificationHandlerCompatible;
}

/// Immutable, allowlisted diagnostic output. Contains no input strings, IDs,
/// paths, exception text, credentials, message content or raw bootstrap data.
final class ChatSetupReport {
  ChatSetupReport(
    Map<ChatSetupCheck, ChatCheckStatus> checks, [
    Map<ChatCapability, ChatCapabilityStatus> capabilities = const {},
  ]) : checks = Map.unmodifiable(checks),
       capabilities = Map.unmodifiable(capabilities);
  final Map<ChatSetupCheck, ChatCheckStatus> checks;
  final Map<ChatCapability, ChatCapabilityStatus> capabilities;
  bool get hasFailures => checks.values.contains(ChatCheckStatus.failed);
  bool get hasUnknowns =>
      checks.values.contains(ChatCheckStatus.unknown) ||
      capabilities.values.contains(ChatCapabilityStatus.unknown);
  Map<String, Object> toJson() => {
    'checks': {for (final e in checks.entries) e.key.name: e.value.name},
    'capabilities': {
      for (final e in capabilities.entries) e.key.name: e.value.name,
    },
  };
  @override
  String toString() => jsonEncode(toJson());
}

/// Offline preflight; never contacts servers, invokes token providers, prompts
/// for permission, reads secure storage, or opens credential/configuration files.
/// May be called before ChatClientOptions (which rejects invalid configuration).
ChatSetupReport validateChatSetup({
  required String publicChatAppId,
  required String apiOrigin,
  required String platform,
  String? runtimePlatform,
  bool verified = false,
  bool hasIdentityKey = false,
  bool storageConfigured = false,
  bool storageIsSecure = false,
  bool persistSendQueue = false,
  bool persistAttachments = false,
  Iterable<String> attachmentOrigins = const [],
  ChatHostChecks host = const ChatHostChecks(),
}) {
  bool origin(String value, {bool loopback = false}) {
    try {
      final uri = Uri.parse(value);
      return uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          ['', '/'].contains(uri.path) &&
          (uri.scheme == 'https' ||
              (loopback &&
                  uri.scheme == 'http' &&
                  ['localhost', '127.0.0.1', '::1'].contains(uri.host)));
    } catch (_) {
      return false;
    }
  }

  ChatCheckStatus check(bool value) =>
      value ? ChatCheckStatus.passed : ChatCheckStatus.failed;
  ChatCheckStatus evidence(bool? value) =>
      value == null ? ChatCheckStatus.unknown : check(value);
  final storageOk = storageConfigured && storageIsSecure;
  final origins = attachmentOrigins.toList();
  return ChatSetupReport({
    ChatSetupCheck.publicAppId: check(
      RegExp(r'^chat_(test|live)_[a-z0-9]+$').hasMatch(publicChatAppId),
    ),
    ChatSetupCheck.apiOrigin: check(origin(apiOrigin, loopback: true)),
    ChatSetupCheck.platform: check(
      ['android', 'ios'].contains(platform) &&
          platform == (runtimePlatform ?? Platform.operatingSystem),
    ),
    ChatSetupCheck.secureStorage: storageConfigured
        ? check(storageIsSecure)
        : ChatCheckStatus.notApplicable,
    ChatSetupCheck.identityPartition: verified && storageConfigured
        ? check(hasIdentityKey)
        : ChatCheckStatus.notApplicable,
    ChatSetupCheck.sendQueue: persistSendQueue
        ? check(storageOk)
        : ChatCheckStatus.notApplicable,
    ChatSetupCheck.attachmentOrigins: origins.isEmpty
        ? ChatCheckStatus.notApplicable
        : check(origins.every((v) => origin(v, loopback: true))),
    ChatSetupCheck.attachmentPersistence: persistAttachments
        ? check(storageOk && origins.isNotEmpty)
        : ChatCheckStatus.notApplicable,
    ChatSetupCheck.entitlements: evidence(host.entitlementsValid),
    ChatSetupCheck.pushAdapter: evidence(host.pushAdapterInstalled),
    ChatSetupCheck.notificationPermission: evidence(
      host.notificationsPermitted,
    ),
    ChatSetupCheck.notificationHandler: evidence(
      host.notificationHandlerCompatible,
    ),
  });
}

/// Combines an allowlisted server snapshot with local configuration and host
/// evidence. Missing/malformed flags stay unknown; a snapshot is not authorization.
ChatSetupReport buildChatCapabilityReport({
  required ChatSetupReport setup,
  Map<Object?, Object?>? server,
  required bool storageConfigured,
  required bool attachmentsConfigured,
  required bool persistAttachments,
  bool? attachmentStoreAvailable,
  bool anonymous = false,
  ChatHostChecks host = const ChatHostChecks(),
}) {
  ChatCapabilityStatus flag(String key) => switch (server?[key]) {
    true => ChatCapabilityStatus.available,
    false => ChatCapabilityStatus.unavailable,
    _ => ChatCapabilityStatus.unknown,
  };
  var push = flag('pushDeliveryAvailable');
  if (push == ChatCapabilityStatus.available && anonymous) {
    push = flag('anonymousPushAvailable');
  }
  if (push == ChatCapabilityStatus.available) {
    final providers = server?['configuredPushProviders'];
    if (host.pushProvider == null || providers is! List) {
      push = ChatCapabilityStatus.unknown;
    } else if (!providers.contains(host.pushProvider!.name)) {
      push = ChatCapabilityStatus.notConfigured;
    }
  }
  if (push == ChatCapabilityStatus.available ||
      push == ChatCapabilityStatus.unknown) {
    final providerReady = push == ChatCapabilityStatus.available;
    push = host.pushAdapterInstalled == false
        ? ChatCapabilityStatus.notInstalled
        : host.notificationsPermitted == false
        ? ChatCapabilityStatus.notPermitted
        : host.notificationHandlerCompatible == false ||
              host.entitlementsValid == false
        ? ChatCapabilityStatus.notConfigured
        : host.pushAdapterInstalled == true &&
              host.notificationsPermitted == true &&
              host.notificationHandlerCompatible == true &&
              host.entitlementsValid == true &&
              providerReady
        ? ChatCapabilityStatus.available
        : ChatCapabilityStatus.unknown;
  }
  final supported =
      setup.checks[ChatSetupCheck.platform] == ChatCheckStatus.passed;
  final values = <ChatCapability, ChatCapabilityStatus>{
    ChatCapability.attachments: !attachmentsConfigured
        ? ChatCapabilityStatus.notConfigured
        : flag('attachments'),
    ChatCapability.typing: flag('typing'),
    ChatCapability.identityMerge: flag('identityMerge'),
    ChatCapability.notificationReporting: flag('notificationReporting'),
    ChatCapability.pushRegistration: flag('pushTargetRegistration'),
    ChatCapability.pushDelivery: push,
    ChatCapability.secureStorage: !storageConfigured
        ? ChatCapabilityStatus.notConfigured
        : setup.checks[ChatSetupCheck.secureStorage] == ChatCheckStatus.failed
        ? ChatCapabilityStatus.unavailable
        : ChatCapabilityStatus.unknown, // Configuration is not proof of Keychain/Keystore access.
    ChatCapability.attachmentPersistence: !persistAttachments
        ? ChatCapabilityStatus.notConfigured
        : attachmentStoreAvailable == true
        ? ChatCapabilityStatus.available
        : attachmentStoreAvailable == false
        ? ChatCapabilityStatus.unavailable
        : ChatCapabilityStatus.unknown,
  };
  return ChatSetupReport(
    {
      ...setup.checks,
      ChatSetupCheck.serverSnapshot: server == null
          ? ChatCheckStatus.unknown
          : ChatCheckStatus.passed,
    },
    supported
        ? values
        : {
            for (final key in values.keys)
              key: ChatCapabilityStatus.unavailable,
          },
  );
}
