import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/fake_transport.dart';

void main() {
  test(
    'read reports canonical boundary and fences late logout response',
    () async {
      final transport = FakeTransport();
      final gate = Completer<ChatResponse>();
      transport.handler = (call) async => call.uri.path.endsWith('/read')
          ? gate.future
          : transport.respond(call);
      final client = await makeClient(transport);
      final result = client.markRead(
        conversationId: 'conv_test',
        throughMessageId: 'msg_test',
      );
      final assertion = expectLater(
        result,
        throwsA(
          isA<ProtodeskChatException>().having(
            (e) => e.code,
            'code',
            'chat.operation_cancelled',
          ),
        ),
      );
      await until(
        () => transport.calls.any((c) => c.uri.path.endsWith('/read')),
      );
      expect(
        transport.calls.where((c) => c.uri.path.endsWith('/read')).single.body,
        {'throughMessageId': 'msg_test'},
      );
      await client.logout();
      gate.complete(
        ChatResponse(200, {
          'conversationId': 'conv_test',
          'throughMessageId': 'msg_test',
          'readAt': DateTime.now().toIso8601String(),
          'unreadCount': 0,
        }),
      );
      await assertion;
      await client.dispose();
    },
  );

  test(
    'unread uses aggregate bootstrap and rejects malformed totals',
    () async {
      final transport = FakeTransport();
      Object count = 7;
      transport.handler = (call) async => call.uri.path.endsWith('/bootstrap')
          ? ChatResponse(200, {'unreadCount': count})
          : transport.respond(call);
      final client = await makeClient(transport);
      expect(await client.getUnreadCount(), 7);
      count = -1;
      await expectLater(
        client.getUnreadCount(),
        throwsA(isA<ProtodeskChatException>()),
      );
      await client.dispose();
    },
  );

  testWidgets(
    'typing throttles, expires, rejects reordered starts and clears on disconnect',
    (tester) async {
      final transport = FakeTransport();
      final client = await makeClient(transport);
      await client.connect();
      await tester.pump();
      final socket = transport.sockets.single;
      socket.emit('realtime.ready', {'cursor': 'c1'});
      await tester.pump();
      expect(client.connectionState, ChatConnectionState.connected);
      client.setTyping('conv_test', true);
      expect(socket.sent.where((f) => f['type'] == 'typing.set'), isEmpty);
      await client.getUnreadCount();
      client.setTyping('conv_test', true);
      client.setTyping('conv_test', true);
      expect(socket.sent.where((f) => f['type'] == 'typing.set').length, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(socket.sent.last['typing'], false);
      final now = DateTime.now().toUtc();
      Map<String, dynamic> frame(bool typing, DateTime at) => {
        'conversationId': 'conv_test',
        'typing': typing,
        'occurredAt': at.toIso8601String(),
        'expiresAt': at.add(const Duration(seconds: 1)).toIso8601String(),
      };
      socket.emit('typing.changed', frame(true, now));
      await tester.pump();
      expect(client.isTyping('conv_test'), true);
      await tester.pump(const Duration(seconds: 1));
      expect(client.isTyping('conv_test'), false);
      socket.emit('typing.changed', frame(true, now));
      await tester.pump();
      expect(client.isTyping('conv_test'), false);
      socket.emit(
        'typing.changed',
        frame(true, now.add(const Duration(milliseconds: 10))),
      );
      await tester.pump();
      await client.disconnect();
      expect(client.isTyping('conv_test'), false);
      final sent = socket.sent.length;
      client.setTyping('conv_test', true);
      expect(socket.sent.length, sent);
      await client.dispose();
    },
  );

  testWidgets(
    'loading history never marks read; explicit action sends selected boundary',
    (tester) async {
      final transport = FakeTransport();
      transport.messages.add({...message(), 'sender': 'agent'});
      transport.handler = (call) async => call.uri.path.endsWith('/read')
          ? ChatResponse(200, {
              'conversationId': 'conv_test',
              'throughMessageId': call.body!['throughMessageId'],
              'readAt': DateTime.now().toIso8601String(),
              'unreadCount': 0,
            })
          : transport.respond(call);
      final client = await makeClient(transport);
      // Host-owned read semantics: the screen reports nothing and shows no
      // read control; the host calls client.markRead itself.
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(client: client, automaticReadReporting: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('conv_test')));
      await tester.pumpAndSettle();
      expect(
        transport.calls.where((c) => c.uri.path.endsWith('/read')),
        isEmpty,
      );
      expect(find.text('Mark read through here'), findsNothing);
      await client.markRead(
        conversationId: 'conv_test',
        throughMessageId: 'msg_test',
      );
      expect(
        transport.calls.where((c) => c.uri.path.endsWith('/read')).single.body,
        {'throughMessageId': 'msg_test'},
      );
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );

  test('unread controller discards in-flight totals on logout', () async {
    final transport = FakeTransport();
    final gate = Completer<ChatResponse>();
    transport.handler = (call) async => call.uri.path.endsWith('/bootstrap')
        ? gate.future
        : transport.respond(call);
    final client = await makeClient(transport);
    final unread = ChatUnreadController(client);
    await until(
      () => transport.calls.any((c) => c.uri.path.endsWith('/bootstrap')),
    );
    await client.logout();
    gate.complete(const ChatResponse(200, {'unreadCount': 42}));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(unread.count, isNull);
    expect(unread.isStale, true);
    await unread.dispose();
    await client.dispose();
  });
  test(
    'read bursts coalesce total refresh and a racing response stays stale',
    () async {
      final transport = FakeTransport();
      Completer<ChatResponse>? gate;
      var total = 9;
      transport.handler = (call) async {
        if (call.uri.path.endsWith('/bootstrap')) {
          return gate?.future ?? ChatResponse(200, {'unreadCount': total});
        }
        if (call.uri.path.endsWith('/read')) {
          return ChatResponse(200, {
            'conversationId': 'conv_test',
            'throughMessageId': 'msg_test',
            'readAt': DateTime.now().toIso8601String(),
            'unreadCount': 0,
          });
        }
        return transport.respond(call);
      };
      final client = await makeClient(transport);
      final unread = ChatUnreadController(client);
      await unread.refresh();
      expect(unread.count, 9);
      gate = Completer<ChatResponse>();
      final refresh = unread.refresh();
      for (var i = 0; i < 20; i++) {
        await client.markRead(
          conversationId: 'conv_test',
          throughMessageId: 'msg_test',
        );
      }
      await Future<void>.delayed(Duration.zero);
      gate.complete(const ChatResponse(200, {'unreadCount': 9}));
      await refresh;
      expect(unread.isStale, true);
      total = 0;
      gate = null;
      await until(() => unread.count == 0 && !unread.isStale);
      expect(
        transport.calls.where((c) => c.uri.path.endsWith('/bootstrap')).length,
        3,
      );
      await unread.dispose();
      await client.dispose();
    },
  );
}
