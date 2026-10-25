import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart';

void main() {
  test(
    'foreground churn waits for an invalidated handshake to close',
    () async {
      final transport = DelayedTransport();
      final client = await makeClient(transport);
      await client.connect();
      await until(() => transport.attempts == 1);
      await client.disconnect();
      await client.connect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.attempts, 1);
      transport.gate.complete(transport.first);
      await until(() => transport.attempts == 2);
      expect(transport.first.controller.isClosed, isTrue);
      await client.dispose();
    },
  );
  test('operation IDs follow the backend UUID contract', () {
    final ids = List.generate(100, (_) => ProtodeskChatClient.newOperationId());
    expect(ids.toSet().length, 100);
    for (final id in ids) {
      expect(
        RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ).hasMatch(id),
        isTrue,
      );
    }
  });
  test(
    'anonymous and verified exchanges use customer credentials only',
    () async {
      final transport = FakeTransport();
      final client = await makeClient(transport);
      expect(transport.calls.first.body!['publicChatAppId'], appId);
      expect(transport.calls.first.body!['installationId'], isNotEmpty);
      await client.identify(() async => 'single-use-identity-token');
      expect(
        transport.calls.last.body!['identityToken'],
        'single-use-identity-token',
      );
      expect(transport.calls.where((c) => c.method == 'DELETE').length, 1);
      await client.dispose();
    },
  );
  test('concurrent requests share one rotating refresh', () async {
    final transport = FakeTransport();
    final gate = Completer<ChatResponse>();
    transport.handler = (call) async {
      if (call.uri.path.endsWith('/anonymous')) {
        return ChatResponse(201, session(expired: true));
      }
      if (call.uri.path.endsWith('/refresh')) return gate.future;
      return transport.respond(call);
    };
    final client = await makeClient(transport);
    final first = client.listConversations(),
        second = client.listMessages('conv_test');
    await until(
      () => transport.calls.any((c) => c.uri.path.endsWith('/refresh')),
    );
    gate.complete(ChatResponse(200, session(token: 'replacement')));
    await Future.wait([first, second]);
    expect(
      transport.calls.where((c) => c.uri.path.endsWith('/refresh')).length,
      1,
    );
    expect(transport.calls.last.headers['Authorization'], 'Bearer replacement');
    await client.dispose();
  });
  test(
    'ambiguous refresh fails closed and never reuses the refresh token',
    () async {
      final transport = FakeTransport();
      transport.handler = (call) async {
        if (call.uri.path.endsWith('/anonymous')) {
          return ChatResponse(201, session(expired: true));
        }
        if (call.uri.path.endsWith('/refresh')) {
          throw const ProtodeskChatException(
            'chat.network_unavailable',
            retryable: true,
          );
        }
        return transport.respond(call);
      };
      final client = await makeClient(transport);
      await expectLater(
        client.listConversations(),
        throwsA(isA<ProtodeskChatException>()),
      );
      expect(client.state, ChatClientState.failed);
      await expectLater(
        client.listConversations(),
        throwsA(isA<ProtodeskChatException>()),
      );
      expect(
        transport.calls.where((c) => c.uri.path.endsWith('/refresh')).length,
        1,
      );
      await client.dispose();
    },
  );
  test('logout rejects late account responses and keeps local state cleared on revoke failure', () async {
    final transport = FakeTransport();
    final response = Completer<ChatResponse>();
    transport.handler = (call) async {
      if (call.uri.path.endsWith('/conversations')) return response.future;
      if (call.method == 'DELETE') {
        return const ChatResponse(503, {
          'error': {'code': 'chat.dependency_unavailable'},
        });
      }
      return transport.respond(call);
    };
    final client = await makeClient(transport);
    final pending = client.listConversations();
    final rejected = expectLater(
      pending,
      throwsA(
        isA<ProtodeskChatException>().having(
          (e) => e.code,
          'code',
          'chat.operation_cancelled',
        ),
      ),
    );
    await until(
      () => transport.calls.any((c) => c.uri.path.endsWith('/conversations')),
    );
    await expectLater(client.logout(), throwsA(isA<ProtodeskChatException>()));
    response.complete(
      ChatResponse(200, {
        'data': [conversation()],
        'hasMore': false,
      }),
    );
    await rejected;
    expect(client.state, ChatClientState.signedOut);
    await client.dispose();
  });
  test('overlapping identify cannot install the older identity', () async {
    final transport = FakeTransport();
    final oldToken = Completer<String>();
    final client = await makeClient(transport);
    final old = client.identify(() => oldToken.future);
    final rejected = expectLater(old, throwsA(isA<ProtodeskChatException>()));
    await until(() => client.state == ChatClientState.initializing);
    await client.identify(() async => 'new-identity');
    oldToken.complete('old-identity');
    await rejected;
    expect(
      transport.calls.where((c) => c.body?['identityToken'] == 'old-identity'),
      isEmpty,
    );
    expect(client.state, ChatClientState.ready);
    await client.dispose();
  });
  test(
    'message retry preserves both operation identifiers and payload',
    () async {
      final transport = FakeTransport();
      var failed = false;
      transport.handler = (call) async {
        if (call.method == 'POST' &&
            call.uri.path.endsWith('/messages') &&
            !failed) {
          failed = true;
          transport.respond(call); // Accepted but response lost.
          throw const ProtodeskChatException(
            'chat.network_unavailable',
            retryable: true,
          );
        }
        return transport.respond(call);
      };
      final client = await makeClient(transport);
      Future<ChatMessage> send() => client.sendMessage(
        conversationId: 'conv_test',
        clientMessageId: 'stable-operation',
        text: 'Hello',
      );
      await expectLater(send(), throwsA(isA<ProtodeskChatException>()));
      final delivered = await send();
      expect(delivered.text, 'Hello');
      expect(transport.messages.length, 1);
      final calls = transport.calls
          .where((c) => c.method == 'POST' && c.uri.path.endsWith('/messages'))
          .toList();
      expect(calls[0].body, calls[1].body);
      expect(calls[0].headers, calls[1].headers);
      await client.dispose();
    },
  );
  test('fresh tickets, resume cursor, deduplication, resync and intentional disconnect', () async {
    final transport = FakeTransport();
    final client = await makeClient(transport);
    final events = <ChatServerEvent>[];
    final sub = client.events.listen(events.add);
    await client.connect();
    await client.connect();
    await until(() => transport.sockets.length == 1);
    final first = transport.sockets.first;
    expect(first.sent.single['cursor'], null);
    first.emit('realtime.ready', {'cursor': null});
    final event = {
      'id': 'evt_one',
      'type': 'message.created',
      'data': {'schemaVersion': 1, 'message': message()},
    };
    first.emit('realtime.event', {'cursor': 'opaque-cursor', 'event': event});
    first.emit('realtime.event', {'cursor': 'opaque-cursor', 'event': event});
    first.emit('realtime.drain', {'reconnectAfterMs': 1});
    await until(() => transport.sockets.length == 2);
    expect(events.length, 1);
    expect(transport.sockets[1].sent.single['cursor'], 'opaque-cursor');
    expect(transport.socketUris[0].queryParameters.keys, ['ticket']);
    expect(transport.socketUris[0], isNot(transport.socketUris[1]));
    transport.sockets[1].emit('realtime.resync_required');
    await until(() => transport.sockets.length == 3);
    expect(transport.sockets[2].sent.single['cursor'], null);
    await client.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(transport.sockets.length, 3);
    await sub.cancel();
    await client.dispose();
  });
  test('insecure remote origins and credential URLs are rejected', () {
    for (final origin in [
      'http://example.com',
      'https://secret@example.com',
      'https://example.com?token=secret',
    ]) {
      expect(
        () => ChatClientOptions(
          publicChatAppId: appId,
          baseUrl: Uri.parse(origin),
        ),
        throwsArgumentError,
      );
    }
  });
}

class DelayedTransport extends FakeTransport {
  final gate = Completer<ChatSocket>();
  final first = FakeSocket();
  int attempts = 0;
  @override
  Future<ChatSocket> connect(Uri uri) async {
    if (++attempts == 1) return gate.future;
    return super.connect(uri);
  }
}
