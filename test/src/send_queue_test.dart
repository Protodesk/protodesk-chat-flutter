import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart';

ChatMessage confirmed(String id, {String text = 'Hello'}) =>
    ChatMessage.fromJson(message(clientId: id, text: text));
ChatSendQueue queue(
  Future<ChatMessage> Function(String, String, String) send, {
  ChatSendQueueOptions options = const ChatSendQueueOptions(
    baseRetryDelay: Duration(milliseconds: 1),
  ),
}) => ChatSendQueue(
  options: options,
  send: send,
  newId: ProtodeskChatClient.newOperationId,
  isReady: () => true,
);
void main() {
  test(
    'offline queue sends FIFO and ambiguous retry preserves ID and frozen body',
    () async {
      final calls = <List<String>>[];
      final q = queue((conv, id, text) async {
        calls.add([conv, id, text]);
        if (calls.length == 1) {
          throw const ProtodeskChatException(
            'chat.network_unavailable',
            retryable: true,
          );
        }
        return confirmed(id, text: text);
      });
      q.setActive(false);
      final first = q.enqueue(conversationId: 'conv_test', text: 'First');
      final second = q.enqueue(conversationId: 'conv_test', text: 'Second');
      expect(calls, isEmpty);
      expect(q.messages, hasLength(2));
      q.setActive(true);
      await until(() => q.messages.isEmpty);
      expect(calls[0], calls[1]);
      expect(calls[0][1], first);
      expect(calls[2][1], second);
      await q.close();
    },
  );
  test(
    'bounds count and UTF-8 bytes, expires drafts, and supports discard',
    () async {
      final q = queue(
        (c, id, text) async => confirmed(id),
        options: const ChatSendQueueOptions(
          maxMessages: 2,
          maxBytes: 4,
          maxAge: Duration(milliseconds: 60),
        ),
      );
      q.setActive(false);
      final id = q.enqueue(conversationId: 'conv_test', text: 'éé');
      expect(
        () => q.enqueue(conversationId: 'conv_test', text: 'x'),
        throwsA(isA<ProtodeskChatException>()),
      );
      q.discard(id);
      expect(q.messages, isEmpty);
      q.enqueue(conversationId: 'conv_test', text: 'a');
      q.enqueue(conversationId: 'conv_test', text: 'b');
      expect(
        () => q.enqueue(conversationId: 'conv_test', text: 'c'),
        throwsA(isA<ProtodeskChatException>()),
      );
      await until(() => q.messages.isEmpty);
      expect(q.lastError?.code, 'chat.send_queue_expired');
      await q.close();
    },
  );
  test('retry budget is finite and permanent failures are never automatically retried', () async {
    var calls = 0;
    final q = queue(
      (c, id, text) async {
        calls++;
        throw ProtodeskChatException(
          text == 'permanent'
              ? 'chat.conversation_not_writable'
              : 'chat.network_unavailable',
          retryable: text != 'permanent',
        );
      },
      options: const ChatSendQueueOptions(
        maxAttempts: 2,
        baseRetryDelay: Duration(milliseconds: 1),
      ),
    );
    q.enqueue(conversationId: 'conv_test', text: 'transient');
    await until(() => q.messages.single.state == ChatSendState.failed);
    expect(calls, 2);
    final id = q.enqueue(conversationId: 'conv_test', text: 'permanent');
    await until(() => q.messages.last.state == ChatSendState.failed);
    q.retry(id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, 3);
    expect(q.messages.last.error?.code, 'chat.conversation_not_writable');
    await q.close();
  });
  test('manual retry honors server Retry-After', () async {
    var calls = 0;
    final q = queue((c, id, text) async {
      if (++calls == 1) {
        throw const ProtodeskChatException(
          'chat.rate_limited',
          retryable: true,
          retryAfter: Duration(milliseconds: 80),
        );
      }
      return confirmed(id);
    });
    final id = q.enqueue(conversationId: 'conv_test', text: 'Hello');
    await until(() => q.messages.single.error != null);
    q.retry(id);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls, 1);
    await until(() => q.messages.isEmpty);
    expect(calls, 2);
    await q.close();
  });
  test(
    'echo before lost HTTP response confirms once and suppresses retry',
    () async {
      final gate = Completer<ChatMessage>();
      var calls = 0;
      final q = queue((c, id, text) {
        calls++;
        return gate.future;
      });
      final accepted = <ChatMessage>[];
      final sub = q.accepted.listen(accepted.add);
      final id = q.enqueue(conversationId: 'conv_test', text: 'Hello');
      q.acknowledge(confirmed(id));
      gate.completeError(
        const ProtodeskChatException(
          'chat.network_unavailable',
          retryable: true,
        ),
      );
      await until(() => accepted.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(q.messages, isEmpty);
      expect(calls, 1);
      await sub.cancel();
      await q.close();
    },
  );
  test(
    'optimistic history becomes one canonical row after acceptance',
    () async {
      final transport = FakeTransport();
      final gate = Completer<ChatResponse>();
      transport.handler = (call) async =>
          call.method == 'POST' && call.uri.path.endsWith('/messages')
          ? gate.future
          : transport.respond(call);
      final client = await makeClient(transport);
      final history = ChatHistoryController(
        client,
        conversationId: 'conv_test',
      );
      final id = client.sendQueue.enqueue(
        conversationId: 'conv_test',
        text: 'Hello',
      );
      expect(history.messages.single.clientMessageId, id);
      expect(history.messages.single.status, 'sending');
      gate.complete(ChatResponse(201, message(clientId: id)));
      await until(() => history.messages.single.id == 'msg_test');
      expect(history.messages, hasLength(1));
      expect(client.sendQueue.messages, isEmpty);
      await history.dispose();
      await client.dispose();
    },
  );
  test('disconnect pauses unsent text; reconnect resumes and logout fences late acceptance', () async {
    final transport = FakeTransport();
    final gate = Completer<ChatResponse>();
    transport.handler = (call) async =>
        call.method == 'POST' && call.uri.path.endsWith('/messages')
        ? gate.future
        : transport.respond(call);
    final client = await makeClient(transport);
    await client.disconnect();
    final accepted = <ChatMessage>[];
    final sub = client.sendQueue.accepted.listen(accepted.add);
    final id = client.sendQueue.enqueue(
      conversationId: 'conv_test',
      text: 'private',
    );
    expect(
      transport.calls.where((c) => c.uri.path.endsWith('/messages')),
      isEmpty,
    );
    await client.connect();
    await until(
      () => transport.calls.any((c) => c.uri.path.endsWith('/messages')),
    );
    await client.logout();
    gate.complete(ChatResponse(201, message(clientId: id)));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(client.sendQueue.messages, isEmpty);
    expect(accepted, isEmpty);
    await sub.cancel();
    await client.dispose();
  });
}
