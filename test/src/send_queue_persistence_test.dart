import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart';
import 'persistence_test.dart' show SecureMemory, anonymous;

Future<ProtodeskChatClient> durable(
  SecureMemory storage,
  FakeTransport transport, {
  String account = 'account-a',
  bool persist = true,
  int attempts = 5,
}) => initializeChat(
  ChatClientOptions(
    publicChatAppId: appId,
    baseUrl: Uri.parse('https://api.example.test'),
    storage: storage,
    transport: transport,
    identityKey: account,
    identityTokenProvider: () async => 'host-token',
    persistSendQueue: persist,
    sendQueueOptions: ChatSendQueueOptions(maxAttempts: attempts),
  ),
);
String outboxKey(SecureMemory storage) =>
    storage.values.keys.singleWhere((k) => k.endsWith('.outbox'));
Map<String, dynamic> outbox(SecureMemory storage) =>
    jsonDecode(storage.values[outboxKey(storage)]!) as Map<String, dynamic>;
List<Call> sends(FakeTransport transport) => transport.calls
    .where((c) => c.method == 'POST' && c.uri.path.endsWith('/messages'))
    .toList();
void main() {
  test(
    'dispose drains an already queued durable write before releasing the vault',
    () async {
      final storage = GatedStorage();
      final client = await durable(storage, FakeTransport());
      storage.block = true;
      final pending = client.sendQueue.enqueueDurably(
        conversationId: 'conv_test',
        text: 'Survive close',
      );
      final cancelled = expectLater(
        pending,
        throwsA(isA<ProtodeskChatException>()),
      );
      await until(() => storage.started);
      final closing = client.dispose();
      storage.gate.complete();
      await closing;
      await cancelled;
      expect(outbox(storage)['items'][0]['text'], 'Survive close');
      final restored = await durable(storage, FakeTransport());
      expect(restored.sendQueue.messages.single.text, 'Survive close');
      await restored.dispose();
    },
  );
  test(
    'anonymous proof recovery restores its queue and reset removes it',
    () async {
      final storage = SecureMemory();
      Future<ProtodeskChatClient> start(bool create) {
        final transport = FakeTransport();
        transport.handler = (call) async =>
            call.uri.path.endsWith('/sessions/anonymous')
            ? ChatResponse(201, anonymous())
            : transport.respond(call);
        return initializeChat(
          ChatClientOptions(
            publicChatAppId: appId,
            baseUrl: Uri.parse('https://api.example.test'),
            storage: storage,
            transport: transport,
            persistSendQueue: true,
            allowNewAnonymousIdentity: create,
          ),
        );
      }

      var client = await start(true);
      final id = await client.sendQueue.enqueueDurably(
        conversationId: 'conv_test',
        text: 'Anonymous draft',
      );
      await client.dispose();
      client = await start(false);
      expect(client.sendQueue.messages.single.clientMessageId, id);
      await client.resetAnonymousIdentity();
      expect(storage.values.keys.where((k) => k.endsWith('.outbox')), isEmpty);
      await client.dispose();
    },
  );
  test('failed removal preserves known canonical acceptance and blocks further sends', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    final client = await durable(storage, transport);
    final accepted = <ChatMessage>[];
    final sub = client.sendQueue.accepted.listen(accepted.add);
    await client.sendQueue.enqueueDurably(
      conversationId: 'conv_test',
      text: 'Accepted',
    );
    transport.handler = (call) async {
      if (call.method == 'POST' && call.uri.path.endsWith('/messages')) {
        final result = transport.respond(call);
        storage.failWrite = true;
        return result;
      }
      return transport.respond(call);
    };
    await client.connect();
    await until(() => client.sendQueue.storageBlocked && accepted.length == 1);
    expect(sends(transport), hasLength(1));
    storage.failWrite = false;
    await client.sendQueue.retryPersistence();
    expect(outbox(storage)['items'], isEmpty);
    await sub.cancel();
    await client.dispose();
  });

  test('durable enqueue restores frozen text and ID but waits for foreground connect', () async {
    final storage = SecureMemory(), first = FakeTransport();
    var client = await durable(storage, first);
    final id = await client.sendQueue.enqueueDurably(
      conversationId: 'conv_test',
      text: 'Private draft',
    );
    expect(outbox(storage)['items'][0]['id'], id);
    expect(sends(first), isEmpty);
    await client.dispose();
    final second = FakeTransport();
    client = await durable(storage, second);
    expect(client.sendQueue.messages.single.clientMessageId, id);
    expect(client.sendQueue.messages.single.text, 'Private draft');
    expect(sends(second), isEmpty);
    await client.connect();
    await until(() => client.sendQueue.messages.isEmpty);
    await until(() => (outbox(storage)['items'] as List).isEmpty);
    expect(sends(second).single.body?['clientMessageId'], id);
    await client.dispose();
  });
  test('interrupted accepted request resumes same operation and does not duplicate server data', () async {
    final storage = SecureMemory(), first = FakeTransport();
    final gate = Completer<ChatResponse>();
    first.handler = (call) async {
      if (call.method == 'POST' && call.uri.path.endsWith('/messages')) {
        first.respond(call);
        return gate.future;
      }
      return first.respond(call);
    };
    var client = await durable(storage, first);
    final id = await client.sendQueue.enqueueDurably(
      conversationId: 'conv_test',
      text: 'Once',
    );
    await client.connect();
    await until(() => sends(first).isNotEmpty);
    expect(outbox(storage)['items'][0]['state'], 'sending');
    expect(outbox(storage)['items'][0]['attempts'], 1);
    await client.dispose();
    gate.complete(ChatResponse(201, first.messages.single));
    final second = FakeTransport()..messages.addAll(first.messages);
    client = await durable(storage, second);
    expect(client.sendQueue.messages.single.attempts, 1);
    await client.connect();
    await until(() => sends(second).isNotEmpty);
    await until(() => client.sendQueue.messages.isEmpty);
    expect(second.messages, hasLength(1));
    expect(sends(second).single.body, sends(first).single.body);
    expect(
      sends(second).single.headers['Idempotency-Key'] ??
          sends(second).single.headers['idempotency-key'],
      id,
    );
    await client.dispose();
  });
  test('failed enqueue and attempt-marker writes never transmit', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    final client = await durable(storage, transport);
    storage.failWrite = true;
    await expectLater(
      client.sendQueue.enqueueDurably(
        conversationId: 'conv_test',
        text: 'Not saved',
      ),
      throwsA(isA<ProtodeskChatException>()),
    );
    expect(client.sendQueue.messages, isEmpty);
    expect(sends(transport), isEmpty);
    storage.failWrite = false;
    await client.sendQueue.retryPersistence();
    await client.sendQueue.enqueueDurably(
      conversationId: 'conv_test',
      text: 'Marker first',
    );
    storage.failWrite = true;
    await client.connect();
    await until(() => client.sendQueue.storageBlocked);
    expect(sends(transport), isEmpty);
    storage.failWrite = false;
    await client.sendQueue.retryPersistence();
    await until(() => sends(transport).isNotEmpty);
    await client.dispose();
  });
  test('retry budget and server Retry-After survive restart', () async {
    final storage = SecureMemory(), first = FakeTransport();
    first.handler = (call) async =>
        call.method == 'POST' && call.uri.path.endsWith('/messages')
        ? const ChatResponse(429, {
            'error': {'code': 'chat.rate_limited'},
          }, retryAfter: Duration(minutes: 1))
        : first.respond(call);
    var client = await durable(storage, first, attempts: 1);
    final id = await client.sendQueue.enqueueDurably(
      conversationId: 'conv_test',
      text: 'Later',
    );
    await client.connect();
    await until(
      () => client.sendQueue.messages.single.state == ChatSendState.failed,
    );
    await client.dispose();
    final second = FakeTransport();
    client = await durable(storage, second, attempts: 1);
    expect(client.sendQueue.messages.single.state, ChatSendState.failed);
    expect(client.sendQueue.messages.single.attempts, 1);
    client.sendQueue.retry(id);
    await client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sends(second), isEmpty);
    expect(
      client.sendQueue.messages.single.retryAt!.isAfter(DateTime.now()),
      true,
    );
    await client.dispose();
  });
  test('expired records are pruned and corrupt records fail closed', () async {
    final storage = SecureMemory();
    var client = await durable(storage, FakeTransport());
    await client.sendQueue.enqueueDurably(
      conversationId: 'conv_test',
      text: 'Expired',
    );
    await client.dispose();
    final key = outboxKey(storage), value = outbox(storage);
    value['items'][0]['createdAt'] = DateTime.now()
        .subtract(const Duration(days: 2))
        .toUtc()
        .toIso8601String();
    value['items'][0]['expiresAt'] = DateTime.now()
        .subtract(const Duration(days: 1, hours: 1))
        .toUtc()
        .toIso8601String();
    storage.values[key] = jsonEncode(value);
    client = await durable(storage, FakeTransport());
    expect(client.sendQueue.messages, isEmpty);
    await client.dispose();
    value['items'][0]['id'] = 'invalid';
    storage.values[key] = jsonEncode(value);
    final transport = FakeTransport();
    await expectLater(
      durable(storage, transport),
      throwsA(
        isA<ProtodeskChatException>().having(
          (e) => e.code,
          'code',
          'chat.storage_corrupt',
        ),
      ),
    );
    expect(sends(transport), isEmpty);
  });
  test(
    'account partitions isolate drafts and disabling persistence removes them',
    () async {
      final storage = SecureMemory();
      var client = await durable(storage, FakeTransport());
      await client.sendQueue.enqueueDurably(
        conversationId: 'conv_test',
        text: 'Account A',
      );
      await client.dispose();
      client = await durable(storage, FakeTransport(), account: 'account-b');
      expect(client.sendQueue.messages, isEmpty);
      await client.dispose();
      client = await durable(storage, FakeTransport(), persist: false);
      expect(storage.values.keys.where((k) => k.endsWith('.outbox')), isEmpty);
      await client.dispose();
    },
  );
  test(
    'logout during a delayed outbox write leaves no resurrected record',
    () async {
      final storage = GatedStorage();
      final client = await durable(storage, FakeTransport());
      storage.block = true;
      final enqueue = client.sendQueue.enqueueDurably(
        conversationId: 'conv_test',
        text: 'Gone',
      );
      final rejected = expectLater(
        enqueue,
        throwsA(isA<ProtodeskChatException>()),
      );
      await until(() => storage.started);
      final logout = client.logout();
      storage.gate.complete();
      await logout;
      await rejected;
      expect(storage.values.keys.where((k) => k.endsWith('.outbox')), isEmpty);
      await client.dispose();
    },
  );
  test('logout tombstone fences stale outbox when deletion fails', () async {
    final storage = DeleteFailingStorage();
    var client = await durable(storage, FakeTransport());
    await client.sendQueue.enqueueDurably(
      conversationId: 'conv_test',
      text: 'Do not restore',
    );
    storage.failDelete = true;
    await expectLater(client.logout(), throwsA(isA<ProtodeskChatException>()));
    await client.dispose();
    storage.failDelete = false;
    client = await durable(storage, FakeTransport());
    expect(client.sendQueue.messages, isEmpty);
    await client.dispose();
  });
}

class GatedStorage extends SecureMemory {
  final gate = Completer<void>();
  bool block = false, started = false;
  @override
  Future<void> write(String key, String value) async {
    if (block && key.endsWith('.outbox')) {
      started = true;
      await gate.future;
    }
    await super.write(key, value);
  }
}

class DeleteFailingStorage extends SecureMemory {
  bool failDelete = false;
  @override
  Future<void> delete(String key) async {
    if (failDelete && key.endsWith('.outbox')) {
      throw StateError('secure store unavailable');
    }
    await super.delete(key);
  }
}
