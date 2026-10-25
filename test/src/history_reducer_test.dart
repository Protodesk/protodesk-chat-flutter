import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';
import 'package:protodesk_chat/src/history_reducer.dart';

import '../support/fake_transport.dart';
import 'persistence_test.dart' show SecureMemory;
import 'reconciliation_test.dart' show persisted, checkpoint;

const later = '2026-10-25T00:01:00Z';
Map<String, dynamic> history({bool more = false}) => {
  'conversations': {
    'data': [conversation()],
    'hasMore': more,
    'nextCursor': more ? 'conv-page' : null,
  },
  'conversationId': 'conv_test',
  'messages': {
    'data': [message()],
    'hasMore': more,
    'nextCursor': more ? 'msg-page' : null,
  },
};
ChatServerEvent evt(String type, Map<String, dynamic> data) =>
    ChatServerEvent.fromJson({
      'id': 'evt_test',
      'type': type,
      'data': {'schemaVersion': 1, ...data},
    });
void main() {
  test('incoming messages mark unread totals stale rather than double-count replay', () {
    final next = reduceHistory(
      history(),
      evt('message.created', {
        'message': {...message(id: 'msg_agent'), 'sender': 'agent'},
      }),
    );
    final conversation = ChatConversation.fromJson(
      next['conversations']['data'][0],
    );
    expect(conversation.unreadCount, 0);
    expect(conversation.unreadCountIsStale, true);
  });
  test(
    'unsupported events do not advance the checkpoint or fetch REST',
    () async {
      final storage = SecureMemory(), transport = FakeTransport();
      final client = await persisted(storage, transport);
      final errors = <ProtodeskChatException>[];
      final sub = client.errors.listen(errors.add);
      await client.connect();
      await until(() => transport.sockets.isNotEmpty);
      transport.sockets.single.emit('realtime.ready', {'cursor': 'boundary'});
      await until(
        () => client.connectionState == ChatConnectionState.connected,
      );
      final before = transport.calls.length;
      transport.sockets.single.emit('realtime.event', {
        'cursor': 'unsupported',
        'event': {
          'id': 'evt_unknown',
          'type': 'future.event',
          'data': {'schemaVersion': 1},
        },
      });
      await until(() => errors.isNotEmpty);
      expect(errors.single.code, 'chat.protocol_unsupported');
      expect(checkpoint(storage)?['cursor'], 'boundary');
      expect(transport.calls.length, before);
      await sub.cancel();
      await client.dispose();
    },
  );

  test(
    'full projections update locally without mutating the committed input',
    () {
      final old = history();
      var next = reduceHistory(
        old,
        evt('message.created', {
          'message': {...message(text: 'edited'), 'updatedAt': later},
        }),
      );
      expect(old['messages']['data'][0]['body'], 'Hello');
      expect(next['messages']['data'][0]['body'], 'edited');
      next = reduceHistory(
        next,
        evt('conversation.resolved', {
          'conversation': {
            ...conversation(),
            'status': 'resolved',
            'updatedAt': later,
          },
        }),
      );
      expect(next['conversations']['data'][0]['status'], 'resolved');
    },
  );
  test(
    'replayed creation cannot downgrade a newer snapshot or delivered status',
    () {
      var next = reduceHistory(
        history(),
        evt('message.delivered', {
          'conversationId': 'conv_test',
          'messageId': 'msg_test',
          'status': 'delivered',
          'occurredAt': later,
        }),
      );
      next = reduceHistory(
        next,
        evt('message.created', {
          'message': {...message(), 'status': 'pending'},
        }),
      );
      next = reduceHistory(
        next,
        evt('message.failed', {
          'conversationId': 'conv_test',
          'messageId': 'msg_test',
          'status': 'failed',
          'occurredAt': '2026-10-25T00:00:30Z',
        }),
      );
      expect(next['messages']['data'][0]['status'], 'delivered');
      expect(next['messages']['data'][0]['updatedAt'], later);
    },
  );
  test('equal versions preserve REST fields and distinct IDs deduplicate projections', () {
    final old = history();
    old['conversations']['data'][0]['unreadCount'] = 3;
    var next = reduceHistory(
      old,
      evt('conversation.updated', {'conversation': conversation()}),
    );
    expect(next['conversations']['data'][0]['unreadCount'], 3);
    for (var i = 0; i < 3; i++) {
      next = reduceHistory(
        next,
        evt('message.created', {
          'message': message(id: 'msg_new', clientId: 'stable-operation'),
        }),
      );
    }
    expect(next['messages']['data'], hasLength(2));
  });
  test('page boundary stays intact and old out-of-window rows are ignored', () {
    var next = reduceHistory(
      history(more: true),
      evt('message.created', {
        'message': {
          ...message(id: 'msg_new'),
          'createdAt': later,
          'updatedAt': later,
        },
      }),
    );
    expect(next['messages']['data'][0]['id'], 'msg_new');
    expect(next['messages']['nextCursor'], 'msg-page');
    next = reduceHistory(
      next,
      evt('message.created', {
        'message': {
          ...message(id: 'msg_old'),
          'createdAt': '2026-10-24T00:00:00Z',
        },
      }),
    );
    expect(next['messages']['data'], hasLength(2));
    expect(next['messages']['hasMore'], true);
  });
  test(
    'unwatched events and missing status rows do not fabricate messages',
    () {
      final old = history();
      var next = reduceHistory(
        old,
        evt('message.created', {
          'message': {
            ...message(id: 'msg_other'),
            'conversationId': 'conv_other',
          },
        }),
      );
      next = reduceHistory(
        next,
        evt('message.failed', {
          'conversationId': 'conv_test',
          'messageId': 'msg_missing',
          'status': 'failed',
          'occurredAt': later,
        }),
      );
      expect(next, old);
    },
  );
  test('malformed and unsupported events fail closed', () {
    for (final event in [
      evt('message.created', {}),
      evt('future.event', {}),
      evt('message.created', {'schemaVersion': 2, 'message': message()}),
      evt('message.failed', {
        'conversationId': 'conv_test',
        'messageId': 'msg_test',
        'status': 'delivered',
        'occurredAt': later,
      }),
    ]) {
      expect(
        () => reduceHistory(history(), event),
        throwsA(isA<ProtodeskChatException>()),
      );
    }
  });
  test(
    'ordinary event burst commits changes with zero additional HTTP requests',
    () async {
      final storage = SecureMemory(), transport = FakeTransport();
      final client = await persisted(storage, transport);
      await client.listMessages('conv_test');
      await client.connect();
      await until(() => transport.sockets.isNotEmpty);
      transport.sockets.single.emit('realtime.ready', {'cursor': 'boundary'});
      await until(
        () => client.connectionState == ChatConnectionState.connected,
      );
      final before = transport.calls.length;
      final received = <ChatServerEvent>[];
      final sub = client.events.listen(received.add);
      for (var i = 0; i < 20; i++) {
        transport.sockets.single.emit('realtime.event', {
          'cursor': 'event-$i',
          'event': {
            'id': 'evt_$i',
            'type': 'message.created',
            'data': {'schemaVersion': 1, 'message': message(id: 'msg_$i')},
          },
        });
      }
      await until(() => received.length == 20);
      expect(transport.calls.length, before);
      expect(client.cachedMessages('conv_test')!.data, hasLength(20));
      expect(checkpoint(storage)?['cursor'], 'event-19');
      await sub.cancel();
      await client.dispose();
    },
  );
  test('read events refresh only the affected cached conversation', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    final client = await persisted(storage, transport);
    await client.connect();
    await until(() => transport.sockets.isNotEmpty);
    transport.sockets.single.emit('realtime.ready', {'cursor': 'boundary'});
    await until(() => client.connectionState == ChatConnectionState.connected);
    final before = transport.calls.length;
    transport.handler = (call) async => call.uri.path.endsWith('/conv_test')
        ? ChatResponse(200, {...conversation(), 'unreadCount': 2})
        : transport.respond(call);
    transport.sockets.single.emit('realtime.event', {
      'cursor': 'read',
      'event': {
        'id': 'evt_read',
        'type': 'conversation.read',
        'data': {
          'schemaVersion': 1,
          'readState': {
            'conversationId': 'conv_test',
            'throughMessageId': 'msg_test',
            'readAt': later,
            'unreadCount': 0,
          },
        },
      },
    });
    await until(() => checkpoint(storage)?['cursor'] == 'read');
    expect(transport.calls.length, before + 1);
    expect(transport.calls.last.uri.path, '/v1/chat/conversations/conv_test');
    expect(client.cachedConversations!.data.single.unreadCount, 2);
    await client.dispose();
  });
}
