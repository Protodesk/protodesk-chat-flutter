import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart';

Map<String, dynamic> row(String id, int minute, {String status = 'pending'}) =>
    {
      ...message(id: id, text: id),
      'createdAt': '2026-10-25T00:${minute.toString().padLeft(2, '0')}:00Z',
      'updatedAt': '2026-10-25T00:${minute.toString().padLeft(2, '0')}:00Z',
      'status': status,
    };
ChatResponse page(List<Map<String, dynamic>> data, {String? next}) =>
    ChatResponse(200, {
      'data': data,
      'hasMore': next != null,
      'nextCursor': next,
    });
void main() {
  test('initial page applies events against its boundary without isolated older rows', () async {
    final transport = FakeTransport();
    final gate = Completer<ChatResponse>();
    transport.handler = (call) async => call.uri.path.endsWith('/messages')
        ? gate.future
        : transport.respond(call);
    final client = await makeClient(transport);
    final history = ChatHistoryController(client, conversationId: 'conv_test');
    final pending = history.loadNext();
    history.includeMessage(ChatMessage.fromJson(row('msg_ancient', 1)));
    gate.complete(page([row('msg_recent', 3)], next: 'older'));
    await pending;
    expect(history.messages.map((v) => v.id), ['msg_recent']);
    await history.dispose();
    await client.dispose();
  });

  test(
    'pages are single-flight, deduplicated, ordered and stop at the end',
    () async {
      final transport = FakeTransport();
      final gate = Completer<ChatResponse>();
      transport.handler = (c) async {
        if (c.uri.path.endsWith('/messages')) {
          return c.uri.queryParameters['cursor'] == null
              ? page([row('msg_new', 3)], next: 'older')
              : gate.future;
        }
        return transport.respond(c);
      };
      final client = await makeClient(transport);
      final history = ChatHistoryController(
        client,
        conversationId: 'conv_test',
      );
      await history.loadNext();
      final first = history.loadNext(), second = history.loadNext();
      expect(identical(first, second), true);
      gate.complete(page([row('msg_new', 3), row('msg_old', 1)]));
      await first;
      expect(history.messages.map((v) => v.id), ['msg_new', 'msg_old']);
      expect(history.hasMore, false);
      final before = transport.calls.length;
      await history.loadNext();
      expect(transport.calls.length, before);
      await history.dispose();
      await client.dispose();
    },
  );
  test(
    'page failures retry the same opaque cursor without discarding loaded rows',
    () async {
      final transport = FakeTransport();
      var fail = true;
      transport.handler = (c) async {
        if (c.uri.path.endsWith('/conversations')) {
          if (c.uri.queryParameters['cursor'] == null)
            return page([conversation()], next: 'opaque+/=');
          if (fail)
            return const ChatResponse(503, {
              'error': {'code': 'chat.dependency_unavailable'},
            });
          return page([
            {...conversation(), 'id': 'conv_old'},
          ]);
        }
        return transport.respond(c);
      };
      final client = await makeClient(transport);
      final tested = ChatHistoryController(client);
      await tested.loadNext();
      await tested.loadNext();
      expect(tested.conversations, hasLength(1));
      expect(tested.nextCursor, 'opaque+/=');
      expect(tested.error, isNotNull);
      fail = false;
      await tested.loadNext();
      expect(tested.error, null);
      expect(tested.conversations, hasLength(2));
      expect(transport.calls.last.uri.queryParameters['cursor'], 'opaque+/=');
      await tested.dispose();
      await client.dispose();
    },
  );
  test('repeated cursors fail closed and refresh starts a new chain', () async {
    final transport = FakeTransport();
    transport.handler = (c) async => c.uri.path.endsWith('/messages')
        ? page([row('msg_one', 1)], next: 'same')
        : transport.respond(c);
    final client = await makeClient(transport);
    final history = ChatHistoryController(client, conversationId: 'conv_test');
    await history.loadNext();
    await history.loadNext();
    expect(history.error?.code, 'chat.invalid_page_cursor');
    expect(history.messages, hasLength(1));
    await history.refresh();
    expect(history.error, null);
    await history.dispose();
    await client.dispose();
  });
  test('refresh and logout reject late page responses', () async {
    final transport = FakeTransport();
    final gates = <Completer<ChatResponse>>[];
    transport.handler = (c) async {
      if (c.uri.path.endsWith('/messages')) {
        final gate = Completer<ChatResponse>();
        gates.add(gate);
        return gate.future;
      }
      return transport.respond(c);
    };
    final client = await makeClient(transport);
    final history = ChatHistoryController(client, conversationId: 'conv_test');
    final old = history.loadNext();
    await until(() => gates.length == 1);
    final fresh = history.refresh();
    await until(() => gates.length == 2);
    gates[1].complete(page([row('msg_current', 2)]));
    await fresh;
    gates[0].complete(page([row('msg_stale', 1)]));
    await old;
    expect(history.messages.single.id, 'msg_current');
    final pending = history.refresh();
    await until(() => gates.length == 3);
    await client.logout();
    gates[2].complete(page([row('msg_private', 3)]));
    await pending;
    await until(() => history.messages.isEmpty);
    expect(history.messages, isEmpty);
    await history.dispose();
    await client.dispose();
  });
  test('realtime updates to an unloaded old row survive an overlapping page response', () async {
    final transport = FakeTransport();
    final older = Completer<ChatResponse>();
    transport.handler = (c) async {
      if (c.uri.path.endsWith('/messages'))
        return c.uri.queryParameters['cursor'] == null
            ? page([row('msg_new', 3)], next: 'older')
            : older.future;
      return transport.respond(c);
    };
    final client = await makeClient(transport);
    await client.listMessages('conv_test');
    await client.connect();
    await until(() => transport.sockets.isNotEmpty);
    transport.sockets.single.emit('realtime.ready', {'cursor': 'start'});
    await until(() => client.connectionState == ChatConnectionState.connected);
    final history = ChatHistoryController(client, conversationId: 'conv_test');
    await history.loadNext();
    final pending = history.loadNext();
    final received = Completer<void>();
    final sub = client.events.listen((_) => received.complete());
    transport.sockets.single.emit('realtime.event', {
      'cursor': 'delivered',
      'event': {
        'id': 'evt_delivered',
        'type': 'message.delivered',
        'data': {
          'schemaVersion': 1,
          'conversationId': 'conv_test',
          'messageId': 'msg_old',
          'status': 'delivered',
          'occurredAt': '2026-10-25T00:04:00Z',
        },
      },
    });
    await received.future;
    older.complete(page([row('msg_old', 1)]));
    await pending;
    expect(history.messages.last.status, 'delivered');
    expect(history.messages.first.id, 'msg_new');
    await sub.cancel();
    await history.dispose();
    await client.dispose();
  });
  test(
    'reconnect restarts pagination rather than hiding a gap between pages',
    () async {
      final transport = FakeTransport();
      transport.handler = (c) async => c.uri.path.endsWith('/messages')
          ? page([
              row(
                c.uri.queryParameters['cursor'] == null
                    ? 'msg_latest'
                    : 'msg_old',
                1,
              ),
            ], next: c.uri.queryParameters['cursor'] == null ? 'older' : null)
          : transport.respond(c);
      final client = await makeClient(transport);
      final history = ChatHistoryController(
        client,
        conversationId: 'conv_test',
      );
      await history.loadNext();
      await history.loadNext();
      expect(history.messages, hasLength(2));
      await client.connect();
      await until(() => transport.sockets.isNotEmpty);
      transport.sockets.single.emit('realtime.ready', {'cursor': 'boundary'});
      await until(() => history.messages.length == 1);
      expect(history.nextCursor, 'older');
      expect(history.hasMore, true);
      await history.dispose();
      await client.dispose();
    },
  );
}
