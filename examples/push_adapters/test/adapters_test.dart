import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:protodesk_chat/protodesk_chat.dart';
import '../lib/fcm_adapter.dart';
import '../lib/onesignal_adapter.dart';
import '../lib/apns_adapter.dart';
import '../lib/apns_channel.dart';
import '../../../test/support/fake_transport.dart';

class Settings implements NotificationSettings {
  Settings(this.authorizationStatus);
  @override
  final AuthorizationStatus authorizationStatus;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Messaging implements FirebaseMessaging {
  final tokens = StreamController<String>.broadcast();
  AuthorizationStatus permission = AuthorizationStatus.authorized;
  @override
  Stream<String> get onTokenRefresh => tokens.stream;
  @override
  Future<NotificationSettings> getNotificationSettings() async =>
      Settings(permission);
  @override
  Future<String?> getToken({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) async => 'initial';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FakeTransport transport() {
  final t = FakeTransport();
  t.handler = (c) async => c.uri.path.contains('push-targets')
      ? const ChatResponse(200, {'id': 'ptg_target', 'status': 'active'})
      : t.respond(c);
  return t;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'FCM rotates tokens, revokes on settings loss and cancels listener',
    () async {
      final t = transport();
      final c = await makeClient(t);
      addTearDown(c.dispose);
      final m = Messaging();
      addTearDown(m.tokens.close);
      final errors = <Object>[];
      final a = FcmChatAdapter(
        m,
        ChatPushRegistrationBinding(
          targets: c.createPushTargets(),
          provider: ChatPushProvider.fcm,
          installationId: 'install',
        ),
        onError: errors.add,
      );
      await a.start(optedIn: true);
      m.tokens.add('rotated');
      await until(() => t.calls.any((c) => c.body?['target'] == 'rotated'));
      m.permission = AuthorizationStatus.denied;
      await a.refresh();
      expect(t.calls.last.method, 'DELETE');
      await a.dispose();
      final count = t.calls.length;
      m.tokens.add('late');
      await Future<void>.delayed(Duration.zero);
      expect(t.calls.length, count);
      expect(errors, isEmpty);
    },
  );
  test(
    'OneSignal registers subscription ID and revokes on host opt-out',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const subscription = MethodChannel('OneSignal#pushsubscription');
      const notifications = MethodChannel('OneSignal#notifications');
      messenger.setMockMethodCallHandler(
        subscription,
        (call) async => switch (call.method) {
          'OneSignal#pushSubscriptionId' => 'subscription-id',
          'OneSignal#pushSubscriptionToken' => 'must-not-register-this-token',
          'OneSignal#pushSubscriptionOptedIn' => true,
          _ => null,
        },
      );
      messenger.setMockMethodCallHandler(
        notifications,
        (call) async => call.method == 'OneSignal#permission' ? true : null,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(subscription, null);
        messenger.setMockMethodCallHandler(notifications, null);
      });
      await OneSignal.User.pushSubscription.lifecycleInit();
      await OneSignal.Notifications.lifecycleInit();
      final t = transport();
      final c = await makeClient(t);
      addTearDown(c.dispose);
      final a = OneSignalChatAdapter(
        ChatPushRegistrationBinding(
          targets: c.createPushTargets(),
          provider: ChatPushProvider.onesignal,
          installationId: 'install',
        ),
        onError: (e) => fail('$e'),
      );
      await a.start(optedIn: true);
      expect(t.calls.last.body!['target'], 'subscription-id');
      expect(t.calls.last.body!['targetKind'], 'onesignal_subscription_id');
      await a.setOptedIn(false);
      expect(t.calls.last.method, 'DELETE');
      await a.dispose();
    },
  );
  test(
    'APNs channel passes native hex token and respects permission snapshot',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('host.protodesk/apns');
      var allowed = true;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'snapshot'
            ? {'token': 'abcd', 'allowed': allowed}
            : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final t = transport();
      final c = await initializeChat(
        ChatClientOptions(
          publicChatAppId: appId,
          baseUrl: Uri.parse('https://api.example.test'),
          platform: 'ios',
          transport: t,
        ),
      );
      addTearDown(c.dispose);
      final n = c.createPushNavigation(onNavigate: (_) => true);
      addTearDown(n.dispose);
      final registration = ApnsChatAdapter(
        ChatPushRegistrationBinding(
          targets: c.createPushTargets(),
          provider: ChatPushProvider.apns,
          installationId: 'install',
        ),
      );
      final a = ApnsChatChannel(navigation: n, onError: (e) => fail('$e'))
        ..registration = registration
        ..optedIn = true;
      await a.start();
      expect(t.calls.last.body!['provider'], 'apns');
      expect(t.calls.last.body!['target'], 'abcd');
      allowed = false;
      await a.refresh();
      expect(t.calls.last.method, 'DELETE');
      a.dispose();
      await registration.dispose();
    },
  );
}
