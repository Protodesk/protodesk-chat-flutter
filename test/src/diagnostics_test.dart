import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';
import 'package:protodesk_chat/src/diagnostics.dart'
    show buildChatCapabilityReport;

import '../support/fake_transport.dart';

ChatSetupReport setup({
  ChatHostChecks host = const ChatHostChecks(),
  String runtime = 'android',
}) => validateChatSetup(
  publicChatAppId: appId,
  apiOrigin: 'https://api.test',
  platform: 'android',
  runtimePlatform: runtime,
  host: host,
);
ChatSetupReport report({
  Map<Object?, Object?>? server = const {
    'pushDeliveryAvailable': true,
    'configuredPushProviders': ['fcm'],
    'typing': false,
  },
  ChatHostChecks host = const ChatHostChecks(),
}) => buildChatCapabilityReport(
  setup: setup(host: host),
  server: server,
  storageConfigured: false,
  attachmentsConfigured: false,
  persistAttachments: false,
  host: host,
);

void main() {
  test(
    'push requires server evidence, provider match and anonymous policy',
    () {
      const host = ChatHostChecks(
        pushProvider: ChatPushProvider.fcm,
        pushAdapterInstalled: true,
        notificationsPermitted: true,
        notificationHandlerCompatible: true,
        entitlementsValid: true,
      );
      expect(
        report(
          server: null,
          host: host,
        ).capabilities[ChatCapability.pushDelivery],
        ChatCapabilityStatus.unknown,
      );
      expect(
        report(
          server: {
            'pushDeliveryAvailable': true,
            'configuredPushProviders': ['apns'],
          },
          host: host,
        ).capabilities[ChatCapability.pushDelivery],
        ChatCapabilityStatus.notConfigured,
      );
      final snapshot = buildChatCapabilityReport(
        setup: setup(),
        server: {
          'pushDeliveryAvailable': true,
          'configuredPushProviders': ['fcm'],
          'anonymousPushAvailable': false,
        },
        storageConfigured: false,
        attachmentsConfigured: false,
        persistAttachments: false,
        host: host,
        anonymous: true,
      );
      expect(
        snapshot.capabilities[ChatCapability.pushDelivery],
        ChatCapabilityStatus.unavailable,
      );
    },
  );
  test(
    'configured secure storage is unverified and file availability is explicit',
    () {
      for (final probe in <bool?>[null, false, true]) {
        final result = buildChatCapabilityReport(
          setup: setup(),
          server: {},
          storageConfigured: true,
          attachmentsConfigured: true,
          persistAttachments: true,
          attachmentStoreAvailable: probe,
        );
        expect(
          result.capabilities[ChatCapability.secureStorage],
          ChatCapabilityStatus.unknown,
        );
        expect(
          result.capabilities[ChatCapability.attachmentPersistence],
          probe == null
              ? ChatCapabilityStatus.unknown
              : probe
              ? ChatCapabilityStatus.available
              : ChatCapabilityStatus.unavailable,
        );
      }
    },
  );
  test(
    'invalid configuration is secret-safe and reports independent failures',
    () {
      const secret = 'DO_NOT_EXPORT_SECRET';
      final result = validateChatSetup(
        publicChatAppId: secret,
        apiOrigin: 'https://user:$secret@api.test/path?token=$secret',
        platform: secret,
        runtimePlatform: secret,
        verified: true,
        storageConfigured: true,
        storageIsSecure: false,
        persistSendQueue: true,
        persistAttachments: true,
        attachmentOrigins: ['https://api.test/$secret'],
      );
      expect(result.hasFailures, isTrue);
      for (final check in [
        ChatSetupCheck.publicAppId,
        ChatSetupCheck.apiOrigin,
        ChatSetupCheck.platform,
        ChatSetupCheck.secureStorage,
        ChatSetupCheck.identityPartition,
        ChatSetupCheck.sendQueue,
        ChatSetupCheck.attachmentOrigins,
      ]) {
        expect(result.checks[check], ChatCheckStatus.failed);
      }
      expect(jsonEncode(result.toJson()), isNot(contains(secret)));
      expect(result.toString(), isNot(contains(secret)));
      expect(() => result.checks.clear(), throwsUnsupportedError);
    },
  );
  test('offline validator distinguishes native mismatch and unverified host checks', () {
    expect(setup().hasFailures, isFalse);
    expect(setup().hasUnknowns, isTrue);
    expect(
      setup(runtime: 'ios').checks[ChatSetupCheck.platform],
      ChatCheckStatus.failed,
    );
    expect(
      validateChatSetup(
        publicChatAppId: appId,
        apiOrigin: 'http://127.0.0.1:8000',
        platform: 'ios',
        runtimePlatform: 'ios',
      ).checks[ChatSetupCheck.apiOrigin],
      ChatCheckStatus.passed,
    );
  });
  test('capabilities distinguish disabled, missing, unconfigured, denied and unknown', () {
    expect(
      report().capabilities[ChatCapability.typing],
      ChatCapabilityStatus.unavailable,
    );
    expect(
      report().capabilities[ChatCapability.identityMerge],
      ChatCapabilityStatus.unknown,
    );
    expect(
      report().capabilities[ChatCapability.attachments],
      ChatCapabilityStatus.notConfigured,
    );
    expect(
      report(host: const ChatHostChecks(pushAdapterInstalled: false))
          .capabilities[ChatCapability.pushDelivery],
      ChatCapabilityStatus.notInstalled,
    );
    expect(
      report(
        host: const ChatHostChecks(
          pushAdapterInstalled: true,
          notificationsPermitted: false,
        ),
      ).capabilities[ChatCapability.pushDelivery],
      ChatCapabilityStatus.notPermitted,
    );
    expect(
      report(
        host: const ChatHostChecks(
          pushAdapterInstalled: true,
          notificationsPermitted: true,
          notificationHandlerCompatible: false,
        ),
      ).capabilities[ChatCapability.pushDelivery],
      ChatCapabilityStatus.notConfigured,
    );
    expect(
      report(
        host: const ChatHostChecks(
          pushAdapterInstalled: true,
          notificationsPermitted: true,
          notificationHandlerCompatible: true,
          entitlementsValid: true,
          pushProvider: ChatPushProvider.fcm,
        ),
      ).capabilities[ChatCapability.pushDelivery],
      ChatCapabilityStatus.available,
    );
    expect(
      report(server: null).checks[ChatSetupCheck.serverSnapshot],
      ChatCheckStatus.unknown,
    );
    expect(
      report(server: {'typing': 'secret', 'token': 'secret'}).toString(),
      isNot(contains('secret')),
    );
  });
  test('inspection uses authenticated bootstrap and never exports server/error values', () async {
    final t = FakeTransport();
    final c = await makeClient(t);
    t.handler = (call) async {
      if (call.uri.path.endsWith('/bootstrap')) {
        return ChatResponse(200, {
          'capabilities': {'typing': true, 'token': 'SECRET'},
          'email': 'PRIVATE',
        });
      }
      return t.respond(call);
    };
    final result = await c.inspectCapabilities();
    expect(
      result.checks[ChatSetupCheck.serverSnapshot],
      ChatCheckStatus.passed,
    );
    expect(result.toString(), isNot(contains('SECRET')));
    expect(result.toString(), isNot(contains('PRIVATE')));
    t.handler = (_) async => throw StateError('SECRET');
    final failure = await c.inspectCapabilities();
    expect(
      failure.checks[ChatSetupCheck.serverSnapshot],
      ChatCheckStatus.unknown,
    );
    expect(failure.toString(), isNot(contains('SECRET')));
    await c.dispose();
  });
  test('logout fences an in-flight capability snapshot', () async {
    final t = FakeTransport();
    final c = await makeClient(t);
    final pending = Completer<ChatResponse>();
    t.handler = (call) => call.uri.path.endsWith('/bootstrap')
        ? pending.future
        : Future.value(t.respond(call));
    final snapshot = c.inspectCapabilities();
    final assertion = expectLater(
      snapshot,
      throwsA(
        isA<ProtodeskChatException>().having(
          (e) => e.code,
          'code',
          'chat.operation_cancelled',
        ),
      ),
    );
    await until(
      () => t.calls.any((call) => call.uri.path.endsWith('/bootstrap')),
    );
    await c.logout();
    pending.complete(
      ChatResponse(200, {
        'capabilities': {'typing': true},
      }),
    );
    await assertion;
    await c.dispose();
  });
}
