import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart';
import 'persistence_test.dart' show SecureMemory, stored;
import 'identity_merge_test.dart' show mergeTransport;

void main() {
  test('coalesces rotations before opt-out unregister', () async {
    final t = FakeTransport();
    final gate = Completer<ChatResponse>();
    var registrations = 0;
    t.handler = (call) async {
      if (call.uri.path.contains('push-targets')) {
        if (call.method != 'DELETE' && ++registrations == 1) return gate.future;
        return const ChatResponse(200, {
          'id': 'ptg_target',
          'status': 'active',
        });
      }
      return t.respond(call);
    };
    final c = await makeClient(t);
    addTearDown(c.dispose);
    final b = ChatPushRegistrationBinding(
      targets: c.createPushTargets(),
      provider: ChatPushProvider.fcm,
      installationId: 'install',
    );
    addTearDown(b.dispose);
    final first = b.update(token: 'first', permissionGranted: true);
    await until(() => registrations == 1);
    final middle = b.update(token: 'middle', permissionGranted: true);
    final last = b.update(token: 'last', permissionGranted: true);
    gate.complete(
      const ChatResponse(201, {'id': 'ptg_target', 'status': 'active'}),
    );
    await Future.wait([first, middle, last]);
    expect(
      t.calls
          .where((c) => c.body?['target'] != null)
          .map((c) => c.body!['target']),
      ['first', 'last'],
    );
    await b.update(permissionGranted: false);
    expect(t.calls.last.method, 'DELETE');
  });
  test(
    'uncertain registration is retried identically before revocation',
    () async {
      final t = FakeTransport();
      var calls = 0;
      t.handler = (call) async {
        if (call.uri.path.contains('push-targets')) {
          if (++calls == 1) {
            return const ChatResponse(503, {'code': 'chat.unavailable'});
          }
          return const ChatResponse(200, {
            'id': 'ptg_target',
            'status': 'active',
          });
        }
        return t.respond(call);
      };
      final c = await makeClient(t);
      addTearDown(c.dispose);
      final b = ChatPushRegistrationBinding(
        targets: c.createPushTargets(),
        provider: ChatPushProvider.fcm,
        installationId: 'install',
      );
      addTearDown(b.dispose);
      await expectLater(
        b.update(token: 'secret', permissionGranted: true),
        throwsA(isA<ProtodeskChatException>()),
      );
      await b.update(permissionGranted: false);
      final requests = t.calls
          .where((c) => c.uri.path.contains('push-targets'))
          .toList();
      expect(requests.map((c) => c.method), ['POST', 'POST', 'DELETE']);
      expect(requests[0].body, requests[1].body);
      expect(
        requests[0].headers['Idempotency-Key'],
        requests[1].headers['Idempotency-Key'],
      );
    },
  );
  test('dispose and logout invalidate provider work', () async {
    final t = FakeTransport();
    final gate = Completer<ChatResponse>();
    t.handler = (call) async =>
        call.uri.path.contains('push-targets') ? gate.future : t.respond(call);
    final c = await makeClient(t);
    addTearDown(c.dispose);
    final b = ChatPushRegistrationBinding(
      targets: c.createPushTargets(),
      provider: ChatPushProvider.fcm,
      installationId: 'install',
    );
    final flight = b.update(token: 'old', permissionGranted: true);
    final failure = expectLater(flight, throwsA(isA<ProtodeskChatException>()));
    await until(() => t.calls.any((c) => c.uri.path.contains('push-targets')));
    final close = b.dispose();
    final closeFailure = expectLater(
      close,
      throwsA(isA<ProtodeskChatException>()),
    );
    await c.logout();
    gate.complete(
      const ChatResponse(201, {'id': 'ptg_target', 'status': 'active'}),
    );
    await failure;
    await closeFailure;
    await expectLater(
      b.update(token: 'late', permissionGranted: true),
      throwsA(isA<ProtodeskChatException>()),
    );
  });
  test('definitive registration rejection permits a corrected token', () async {
    final t = FakeTransport();
    t.handler = (call) async {
      if (!call.uri.path.contains('push-targets')) return t.respond(call);
      if (call.body?['target'] == 'invalid') {
        return const ChatResponse(422, {'code': 'chat.push_target_invalid'});
      }
      return const ChatResponse(201, {'id': 'ptg_target', 'status': 'active'});
    };
    final c = await makeClient(t);
    addTearDown(c.dispose);
    final b = ChatPushRegistrationBinding(
      targets: c.createPushTargets(),
      provider: ChatPushProvider.fcm,
      installationId: 'install',
    );
    addTearDown(b.dispose);
    await expectLater(
      b.update(token: 'invalid', permissionGranted: true),
      throwsA(isA<ProtodeskChatException>()),
    );
    await b.update(token: 'corrected', permissionGranted: true);
    expect(
      t.calls
          .where((c) => c.body?['target'] != null)
          .map((c) => c.body!['target']),
      ['invalid', 'corrected'],
    );
  });
  test('secure target ID survives restart for opt-out without persisting provider token', () async {
    final storage = SecureMemory();
    FakeTransport targetTransport() {
      final t = FakeTransport();
      t.handler = (call) async => call.uri.path.contains('push-targets')
          ? const ChatResponse(200, {'id': 'ptg_restored', 'status': 'active'})
          : t.respond(call);
      return t;
    }

    final first = await stored(
      storage,
      targetTransport(),
      account: 'a',
      provider: () async => 'identity',
    );
    await first.createPushTargets().register(
      provider: ChatPushProvider.fcm,
      target: 'raw-provider-secret',
      installationId: 'install',
      permissionGranted: true,
    );
    expect(
      storage.values.values.any((v) => v.contains('raw-provider-secret')),
      isFalse,
    );
    expect(storage.values.keys.any((k) => k.endsWith('.push')), isTrue);
    await first.dispose();
    final t = targetTransport();
    final restored = await stored(
      storage,
      t,
      account: 'a',
      provider: () async => 'identity',
    );
    addTearDown(restored.dispose);
    final b = ChatPushRegistrationBinding(
      targets: restored.createPushTargets(),
      provider: ChatPushProvider.fcm,
      installationId: 'install',
    );
    addTearDown(b.dispose);
    await b.update(permissionGranted: false);
    expect(
      t.calls.any(
        (c) => c.method == 'DELETE' && c.uri.path.endsWith('/ptg_restored'),
      ),
      isTrue,
    );
    expect(storage.values.keys.any((k) => k.endsWith('.push')), isFalse);
    await b.update(token: 'replacement', permissionGranted: true);
    await restored.logout();
    expect(storage.values.keys.any((k) => k.endsWith('.push')), isFalse);
  });
  test(
    'confirmed merge migrates routing ID; anonymous reset clears it',
    () async {
      final storage = SecureMemory();
      final t = mergeTransport();
      final original = t.handler!;
      t.handler = (call) async => call.uri.path.contains('push-targets')
          ? const ChatResponse(200, {'id': 'ptg_merged', 'status': 'active'})
          : original(call);
      final c = await stored(storage, t, create: true);
      addTearDown(c.dispose);
      await c.createPushTargets().register(
        provider: ChatPushProvider.fcm,
        target: 'secret',
        installationId: 'install',
        permissionGranted: true,
      );
      final oldKey = storage.values.keys.singleWhere(
        (k) => k.endsWith('.push'),
      );
      await c.mergeAnonymousIdentity(
        () async => 'verified',
        identityKey: 'account',
      );
      expect(storage.values.containsKey(oldKey), isFalse);
      await c.createPushTargets().unregister();
      expect(t.calls.last.uri.path, '/v1/chat/push-targets/ptg_merged');
      expect(t.calls.last.headers['Authorization'], 'Bearer merged');
      await c.continueAnonymously();
      await c.createPushTargets().register(
        provider: ChatPushProvider.fcm,
        target: 'new-secret',
        installationId: 'install',
        permissionGranted: true,
      );
      await c.resetAnonymousIdentity();
      expect(storage.values.keys.any((k) => k.endsWith('.push')), isFalse);
    },
  );
  test(
    'retired target 404 clears metadata before explicit fresh registration',
    () async {
      final t = FakeTransport();
      t.handler = (call) async {
        if (!call.uri.path.contains('push-targets')) return t.respond(call);
        if (call.method == 'PUT') {
          return const ChatResponse(404, {
            'code': 'chat.push_target_not_found',
          });
        }
        return const ChatResponse(201, {
          'id': 'ptg_target',
          'status': 'active',
        });
      };
      final c = await makeClient(t);
      addTearDown(c.dispose);
      final p = c.createPushTargets();
      Future<String> register() => p.register(
        provider: ChatPushProvider.fcm,
        target: 'token',
        installationId: 'install',
        permissionGranted: true,
      );
      await register();
      await expectLater(register(), throwsA(isA<ProtodeskChatException>()));
      expect(p.targetId, isNull);
      await register();
      expect(t.calls.last.method, 'POST');
    },
  );
}
