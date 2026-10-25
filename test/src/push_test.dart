import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart';

void main() {
  Future<String> register(ChatPushTargets push, {bool permission = true}) =>
      push.register(
        provider: ChatPushProvider.fcm,
        target: 'private-token',
        installationId: 'f4ae0df8-1f75-4977-b64f-2f1a986efb71',
        permissionGranted: permission,
        idempotencyKey: 'operation-1',
      );
  Matcher code(String value) =>
      isA<ProtodeskChatException>().having((e) => e.code, 'code', value);
  test(
    'register, rotate, unregister use provider-neutral wire contract',
    () async {
      final transport = FakeTransport();
      transport.handler = (call) async => call.uri.path.contains('push-targets')
          ? const ChatResponse(200, {'id': 'push_target', 'status': 'active'})
          : transport.respond(call);
      final client = await makeClient(transport);
      addTearDown(client.dispose);
      final push = client.createPushTargets();
      await expectLater(
        register(push, permission: false),
        throwsA(code('chat.push_permission_required')),
      );
      expect(
        transport.calls.where((c) => c.uri.path.contains('push-targets')),
        isEmpty,
      );
      expect(await register(push), 'push_target');
      await register(push);
      await push.unregister();
      expect(push.targetId, isNull);
      final calls = transport.calls
          .where((c) => c.uri.path.contains('push-targets'))
          .toList();
      expect(calls.map((c) => c.method), ['POST', 'PUT', 'DELETE']);
      expect(calls.first.body!['targetKind'], 'native_device_token');
      expect(calls.first.body!['target'], 'private-token');
      expect(calls.first.headers['Idempotency-Key'], 'operation-1');
    },
  );
  test(
    'late registration and old callbacks cannot bind a new account',
    () async {
      final transport = FakeTransport();
      final pending = Completer<ChatResponse>();
      transport.handler = (call) async => call.uri.path.contains('push-targets')
          ? pending.future
          : transport.respond(call);
      final client = await makeClient(transport);
      addTearDown(client.dispose);
      final push = client.createPushTargets();
      final flight = register(push);
      final assertion = expectLater(
        flight,
        throwsA(code('chat.operation_cancelled')),
      );
      await until(
        () => transport.calls.any((c) => c.uri.path.contains('push-targets')),
      );
      await expectLater(register(push), throwsA(code('chat.push_busy')));
      await client.identify(
        () async => 'new-identity',
        identityKey: 'account-b',
      );
      pending.complete(
        const ChatResponse(200, {'id': 'push_old', 'status': 'active'}),
      );
      await assertion;
      await expectLater(
        register(push),
        throwsA(code('chat.operation_cancelled')),
      );
      expect(
        transport.calls
            .where((c) => c.uri.path.contains('push-targets'))
            .length,
        1,
      );
      expect(
        transport.calls.any(
          (c) =>
              c.method == 'DELETE' && c.uri.path.endsWith('/sessions/current'),
        ),
        isTrue,
      );
      expect(client.createPushTargets().targetId, isNull);
    },
  );
  test('uncertain registration preserves explicit retry key', () async {
    final transport = FakeTransport();
    var attempt = 0;
    transport.handler = (call) async {
      if (!call.uri.path.contains('push-targets')) {
        return transport.respond(call);
      }
      attempt++;
      if (attempt == 1) {
        return const ChatResponse(503, {'code': 'chat.unavailable'});
      }
      return const ChatResponse(201, {'id': 'push_target', 'status': 'active'});
    };
    final client = await makeClient(transport);
    addTearDown(client.dispose);
    final push = client.createPushTargets();
    expect(identical(push, client.createPushTargets()), isTrue);
    await expectLater(register(push), throwsA(isA<ProtodeskChatException>()));
    expect(push.targetId, isNull);
    await register(push);
    final calls = transport.calls
        .where((c) => c.uri.path.contains('push-targets'))
        .toList();
    expect(calls.map((c) => c.method), ['POST', 'POST']);
    expect(calls.first.body, calls.last.body);
    expect(
      calls.first.headers['Idempotency-Key'],
      calls.last.headers['Idempotency-Key'],
    );
  });
  test(
    'failed unregister keeps target for retry; logout invalidates handle',
    () async {
      final transport = FakeTransport();
      var fail = true;
      transport.handler = (call) async {
        if (!call.uri.path.contains('push-targets')) {
          return transport.respond(call);
        }
        if (call.method == 'DELETE' && fail) {
          return const ChatResponse(503, {'code': 'chat.unavailable'});
        }
        return const ChatResponse(200, {
          'id': 'push_target',
          'status': 'active',
        });
      };
      final client = await makeClient(transport);
      addTearDown(client.dispose);
      final push = client.createPushTargets();
      await register(push);
      await expectLater(
        push.unregister(),
        throwsA(isA<ProtodeskChatException>()),
      );
      expect(push.targetId, 'push_target');
      fail = false;
      await push.unregister();
      await client.logout();
      await expectLater(
        register(push),
        throwsA(code('chat.operation_cancelled')),
      );
    },
  );
}
