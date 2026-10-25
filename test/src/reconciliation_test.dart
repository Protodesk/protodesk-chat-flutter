import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart';
import 'persistence_test.dart' show SecureMemory;

Future<ProtodeskChatClient> persisted(
  SecureMemory storage,
  FakeTransport transport, {
  String account = 'account-a',
}) => initializeChat(
  ChatClientOptions(
    publicChatAppId: appId,
    baseUrl: Uri.parse('https://chat.example.com'),
    transport: transport,
    storage: storage,
    identityKey: account,
    identityTokenProvider: () async => 'host-token',
  ),
);
Map<String, dynamic> event(String id) => {
  'id': id,
  'type': 'message.created',
  'data': {'schemaVersion': 1, 'message': message()},
};
Map<String, dynamic>? checkpoint(SecureMemory storage) {
  final keys = storage.values.keys.where((k) => k.endsWith('.history'));
  return keys.isEmpty
      ? null
      : jsonDecode(storage.values[keys.single]!) as Map<String, dynamic>;
}

void main() {
  test('REST failure retries without committing the ready boundary', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    final client = await persisted(storage, transport);
    final errors = <ProtodeskChatException>[];
    final sub = client.errors.listen(errors.add);
    transport.handler = (c) async => c.uri.path.endsWith('/conversations')
        ? const ChatResponse(503, {
            'error': {'code': 'chat.dependency_unavailable'},
          })
        : transport.respond(c);
    await client.connect();
    await until(() => transport.sockets.isNotEmpty);
    transport.sockets.first.emit('realtime.ready', {'cursor': 'uncommitted'});
    await until(() => transport.sockets.length == 2);
    expect(checkpoint(storage), null);
    expect(transport.sockets.last.sent.single['cursor'], null);
    expect(errors, isNotEmpty);
    await sub.cancel();
    await client.dispose();
  });

  test(
    'slow reconciliation bounds incoming frames and reconnects for replay',
    () async {
      final storage = SecureMemory(), transport = FakeTransport();
      final client = await persisted(storage, transport);
      final gate = Completer<ChatResponse>();
      var requested = false;
      transport.handler = (c) async {
        if (c.uri.path.endsWith('/conversations')) {
          requested = true;
          return gate.future;
        }
        return transport.respond(c);
      };
      final errors = <ProtodeskChatException>[];
      final sub = client.errors.listen(errors.add);
      await client.connect();
      await until(() => transport.sockets.isNotEmpty);
      transport.sockets.first.emit('realtime.ready', {'cursor': 'boundary'});
      await until(() => requested);
      for (var i = 0; i < 140; i++) {
        transport.sockets.first.emit('realtime.heartbeat');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete(
        ChatResponse(200, {
          'data': [conversation()],
          'hasMore': false,
        }),
      );
      await until(() => transport.sockets.length == 2);
      expect(errors.single.code, 'chat.realtime_backpressure');
      expect(transport.sockets.last.sent.single['cursor'], 'boundary');
      await sub.cancel();
      await client.dispose();
    },
  );

  test(
    'ready waits for REST and queued events commit before publication',
    () async {
      final storage = SecureMemory(), transport = FakeTransport();
      final client = await persisted(storage, transport);
      await client.listMessages('conv_test');
      final gate = Completer<ChatResponse>();
      transport.handler = (call) async {
        if (call.uri.path.endsWith('/conversations')) return gate.future;
        return transport.respond(call);
      };
      final received = <ChatServerEvent>[];
      final sub = client.events.listen((e) {
        expect(checkpoint(storage)?['cursor'], 'event-1');
        received.add(e);
      });
      await client.connect();
      await until(() => transport.sockets.isNotEmpty);
      transport.sockets.single.emit('realtime.ready', {'cursor': 'boundary'});
      transport.messages.add(message());
      transport.sockets.single.emit('realtime.event', {
        'cursor': 'event-1',
        'event': event('evt_1'),
      });
      await until(
        () => transport.calls.any((c) => c.uri.path.endsWith('/conversations')),
      );
      expect(checkpoint(storage), null);
      expect(client.connectionState, ChatConnectionState.connecting);
      expect(received, isEmpty);
      gate.complete(
        ChatResponse(200, {
          'data': [conversation()],
          'hasMore': false,
        }),
      );
      await until(() => received.length == 1);
      expect(client.cachedMessages('conv_test')!.data.single.id, 'msg_test');
      await sub.cancel();
      await client.dispose();
    },
  );

  test(
    'restart restores cursor and history; duplicate replay is not republished',
    () async {
      final storage = SecureMemory(), firstTransport = FakeTransport();
      firstTransport.messages.add(message());
      var client = await persisted(storage, firstTransport);
      await client.listMessages('conv_test');
      await client.connect();
      await until(() => firstTransport.sockets.isNotEmpty);
      firstTransport.sockets.single.emit('realtime.ready', {
        'cursor': 'boundary',
      });
      firstTransport.sockets.single.emit('realtime.event', {
        'cursor': 'event-1',
        'event': event('evt_1'),
      });
      await until(() => checkpoint(storage)?['cursor'] == 'event-1');
      await client.dispose();
      final transport = FakeTransport()
        ..messages.add(message(text: 'authoritative'));
      client = await persisted(storage, transport);
      final received = <ChatServerEvent>[];
      final sub = client.events.listen(received.add);
      await client.connect();
      await until(() => transport.sockets.isNotEmpty);
      expect(transport.sockets.single.sent.single['cursor'], 'event-1');
      expect(client.cachedMessages('conv_test')!.data.single.text, 'Hello');
      transport.sockets.single.emit('realtime.ready', {'cursor': 'event-1'});
      transport.sockets.single.emit('realtime.event', {
        'cursor': 'event-2',
        'event': event('evt_1'),
      });
      await until(() => checkpoint(storage)?['cursor'] == 'event-2');
      expect(received, isEmpty);
      expect(
        client.cachedMessages('conv_test')!.data.single.text,
        'authoritative',
      );
      await sub.cancel();
      await client.dispose();
    },
  );

  test(
    'failed durable write preserves old checkpoint and emits no event',
    () async {
      final storage = SecureMemory(), transport = FakeTransport();
      final client = await persisted(storage, transport);
      final received = <ChatServerEvent>[], errors = <ProtodeskChatException>[];
      final sub = client.events.listen(received.add),
          err = client.errors.listen(errors.add);
      await client.connect();
      await until(() => transport.sockets.isNotEmpty);
      transport.sockets.single.emit('realtime.ready', {'cursor': 'boundary'});
      await until(() => checkpoint(storage)?['cursor'] == 'boundary');
      storage.failWrite = true;
      transport.sockets.single.emit('realtime.event', {
        'cursor': 'event-1',
        'event': event('evt_1'),
      });
      await until(() => errors.isNotEmpty);
      expect(errors.single.code, 'chat.storage_unavailable');
      expect(checkpoint(storage)?['cursor'], 'boundary');
      expect(received, isEmpty);
      await sub.cancel();
      await err.cancel();
      await client.dispose();
    },
  );

  test('resync reconnects empty and does not commit replacement until REST succeeds', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    final client = await persisted(storage, transport);
    await client.connect();
    await until(() => transport.sockets.isNotEmpty);
    transport.sockets.first.emit('realtime.ready', {'cursor': 'old'});
    await until(() => checkpoint(storage)?['cursor'] == 'old');
    transport.sockets.first.emit('realtime.resync_required');
    await until(() => transport.sockets.length == 2);
    expect(transport.sockets.last.sent.single['cursor'], null);
    final gate = Completer<ChatResponse>();
    transport.handler = (c) async => c.uri.path.endsWith('/conversations')
        ? gate.future
        : transport.respond(c);
    transport.sockets.last.emit('realtime.ready', {'cursor': 'replacement'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(checkpoint(storage)?['cursor'], null);
    gate.complete(
      ChatResponse(200, {
        'data': [conversation()],
        'hasMore': false,
      }),
    );
    await until(() => checkpoint(storage)?['cursor'] == 'replacement');
    await client.dispose();
  });

  test('logout fences reconciliation and deletes sensitive history', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    final client = await persisted(storage, transport);
    await client.connect();
    await until(() => transport.sockets.isNotEmpty);
    transport.sockets.single.emit('realtime.ready', {'cursor': 'old'});
    await until(() => checkpoint(storage) != null);
    final gate = Completer<ChatResponse>();
    var requested = false;
    transport.handler = (c) async {
      if (c.uri.path.endsWith('/conversations')) {
        requested = true;
        return gate.future;
      }
      return transport.respond(c);
    };
    await client.disconnect();
    await client.connect();
    await until(() => transport.sockets.length == 2);
    transport.sockets.last.emit('realtime.ready', {'cursor': 'late'});
    await until(() => requested);
    await client.logout();
    gate.complete(
      ChatResponse(200, {
        'data': [conversation()],
        'hasMore': false,
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(checkpoint(storage), null);
    expect(client.cachedConversations, null);
    await client.dispose();
    final next = await persisted(
      storage,
      FakeTransport(),
      account: 'account-b',
    );
    expect(next.cachedConversations, null);
    await next.dispose();
  });
}
