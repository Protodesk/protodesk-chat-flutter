import 'dart:async';
import 'dart:convert';

import 'attachments_test.dart' show source;

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart';
import 'persistence_test.dart' show SecureMemory, anonymous, stored, code;

FakeTransport mergeTransport() {
  final transport = FakeTransport();
  transport.handler = (call) async {
    if (call.uri.path.endsWith('/bootstrap')) {
      return const ChatResponse(200, {
        'unreadCount': 0,
        'capabilities': {'identityMerge': true},
      });
    }
    if (call.uri.path.endsWith('/identity/merge')) {
      return ChatResponse(200, session(token: 'merged'));
    }
    if (call.uri.path.endsWith('/sessions/anonymous')) {
      return ChatResponse(201, anonymous());
    }
    return transport.respond(call);
  };
  return transport;
}

List<Call> merges(FakeTransport transport) => transport.calls
    .where((c) => c.uri.path.endsWith('/identity/merge'))
    .toList();

void main() {
  test(
    'explicit merge uses anonymous bearer once and adopts verified session',
    () async {
      final transport = mergeTransport();
      final client = await makeClient(transport);
      expect(
        await client.mergeAnonymousIdentity(
          () async => 'single-use',
          identityKey: 'account-a',
        ),
        ChatIdentityMergeOutcome.confirmed,
      );
      expect(client.identityMergeOutcome, ChatIdentityMergeOutcome.confirmed);
      expect(
        merges(transport).single.headers['Authorization'],
        'Bearer access',
      );
      expect(merges(transport).single.body!['identityToken'], 'single-use');
      expect(transport.calls.where((c) => c.method == 'DELETE'), isEmpty);
      await client.listConversations();
      expect(transport.calls.last.headers['Authorization'], 'Bearer merged');
      await expectLater(
        client.mergeAnonymousIdentity(
          () async => 'again',
          identityKey: 'account-a',
        ),
        throwsA(code('chat.anonymous_identity_required')),
      );
      await client.dispose();
    },
  );

  test(
    'pending text and in-flight mutations block merge without losing work',
    () async {
      final transport = mergeTransport();
      final client = await makeClient(transport);
      await client.disconnect();
      await client.sendQueue.enqueueDurably(
        conversationId: 'conv_test',
        text: 'Pending',
      );
      await expectLater(
        client.mergeAnonymousIdentity(() async => 'token', identityKey: 'a'),
        throwsA(code('chat.identity_merge_pending_work')),
      );
      expect(client.sendQueue.messages.single.text, 'Pending');
      await client.sendQueue.discard(
        client.sendQueue.messages.single.clientMessageId,
      );
      final old = transport.handler!;
      final gate = Completer<ChatResponse>();
      transport.handler = (call) =>
          call.uri.path.endsWith('/messages') && call.method == 'POST'
          ? gate.future
          : old(call);
      final sending = client.sendMessage(
        conversationId: 'conv_test',
        clientMessageId: ProtodeskChatClient.newOperationId(),
        text: 'Direct',
      );
      await expectLater(
        client.mergeAnonymousIdentity(() async => 'token', identityKey: 'a'),
        throwsA(code('chat.identity_merge_pending_work')),
      );
      gate.complete(ChatResponse(201, message()));
      await sending;
      expect(merges(transport), isEmpty);
      await client.dispose();
    },
  );

  test(
    'definitive conflict restores the anonymous identity without retry',
    () async {
      final transport = mergeTransport();
      final old = transport.handler!;
      transport.handler = (call) async =>
          call.uri.path.endsWith('/identity/merge')
          ? const ChatResponse(409, {
              'error': {'code': 'chat.identity_merge_conflict'},
            })
          : old(call);
      final client = await makeClient(transport);
      await expectLater(
        client.mergeAnonymousIdentity(() async => 'token', identityKey: 'a'),
        throwsA(code('chat.identity_merge_conflict')),
      );
      expect(client.state, ChatClientState.ready);
      await client.listConversations();
      expect(transport.calls.last.headers['Authorization'], 'Bearer access');
      expect(merges(transport).length, 1);
      await client.dispose();
    },
  );

  test(
    'lost response fails closed; recovery uses a fresh verified exchange',
    () async {
      final transport = mergeTransport();
      final old = transport.handler!;
      transport.handler = (call) async {
        if (call.uri.path.endsWith('/identity/merge')) {
          throw const ProtodeskChatException(
            'chat.network_unavailable',
            retryable: true,
          );
        }
        return old(call);
      };
      final client = await makeClient(transport);
      await expectLater(
        client.mergeAnonymousIdentity(
          () async => 'first-token',
          identityKey: 'a',
        ),
        throwsA(code('chat.identity_merge_uncertain')),
      );
      expect(client.state, ChatClientState.failed);
      await expectLater(
        client.recoverIdentityMerge(() async => 'wrong', identityKey: 'other'),
        throwsA(code('chat.identity_merge_recovery_required')),
      );
      expect(
        await client.recoverIdentityMerge(
          () async => 'fresh-token',
          identityKey: 'a',
        ),
        ChatIdentityMergeOutcome.recoveredUnconfirmed,
      );
      expect(merges(transport).length, 1);
      expect(
        transport.calls
            .where((c) => c.uri.path == '/v1/chat/sessions')
            .last
            .body!['identityToken'],
        'fresh-token',
      );
      expect(client.state, ChatClientState.ready);
      await client.dispose();
    },
  );

  test('secure marker precedes merge; restart blocks anonymous resume and recovers target', () async {
    final storage = SecureMemory();
    final transport = mergeTransport();
    final old = transport.handler!;
    transport.handler = (call) async {
      if (call.uri.path.endsWith('/identity/merge')) {
        expect(
          storage.values.values
              .map((v) => jsonDecode(v))
              .any((v) => v['mergePending'] == true),
          true,
        );
        throw const ProtodeskChatException('chat.network_unavailable');
      }
      return old(call);
    };
    final client = await stored(storage, transport, create: true);
    await expectLater(
      client.mergeAnonymousIdentity(() async => 'token', identityKey: 'a'),
      throwsA(code('chat.identity_merge_uncertain')),
    );
    await client.dispose();
    final anonymousAttempt = mergeTransport();
    await expectLater(
      stored(storage, anonymousAttempt, create: true),
      throwsA(code('chat.identity_merge_recovery_required')),
    );
    expect(anonymousAttempt.calls, isEmpty);
    final restoredTransport = mergeTransport();
    final restored = await stored(
      storage,
      restoredTransport,
      account: 'a',
      provider: () async => 'fresh-on-restart',
    );
    expect(
      restored.identityMergeOutcome,
      ChatIdentityMergeOutcome.recoveredUnconfirmed,
    );
    expect(merges(restoredTransport), isEmpty);
    final source = storage.values.entries
        .where((e) => e.key.endsWith('.anonymous'))
        .single;
    expect(jsonDecode(source.value)['secret'], 'proof-1');
    expect(jsonDecode(source.value)['mergePending'], false);
    await restored.dispose();
  });

  test(
    'late merge after logout revokes issued session and never adopts it',
    () async {
      final transport = mergeTransport();
      final old = transport.handler!;
      final gate = Completer<ChatResponse>();
      transport.handler = (call) =>
          call.uri.path.endsWith('/identity/merge') ? gate.future : old(call);
      final client = await makeClient(transport);
      final merge = client.mergeAnonymousIdentity(
        () async => 'token',
        identityKey: 'a',
      );
      final assertion = expectLater(
        merge,
        throwsA(code('chat.operation_cancelled')),
      );
      await until(() => merges(transport).isNotEmpty);
      final logout = client.logout();
      gate.complete(ChatResponse(200, session(token: 'late-merge')));
      await logout;
      await assertion;
      expect(client.state, ChatClientState.signedOut);
      expect(
        transport.calls.any(
          (c) =>
              c.method == 'DELETE' &&
              c.headers['Authorization'] == 'Bearer late-merge',
        ),
        true,
      );
      await client.dispose();
    },
  );

  test('capability absence and concurrent upgrade never consume extra identity tokens', () async {
    final transport = mergeTransport();
    final client = await makeClient(transport);
    final token = Completer<String>();
    final operation = client.mergeAnonymousIdentity(
      () => token.future,
      identityKey: 'a',
    );
    final assertion = expectLater(
      client.mergeAnonymousIdentity(() async => 'other', identityKey: 'b'),
      throwsA(code('chat.identity_merge_in_progress')),
    );
    await assertion;
    token.complete('one');
    await operation;
    expect(merges(transport).length, 1);
    await client.dispose();
    final disabled = FakeTransport();
    final other = await makeClient(disabled);
    var called = false;
    await expectLater(
      other.mergeAnonymousIdentity(() async {
        called = true;
        return 'token';
      }, identityKey: 'a'),
      throwsA(code('chat.feature_unavailable')),
    );
    expect(called, false);
    expect(other.state, ChatClientState.ready);
    await other.dispose();
  });

  test('secure marker failure prevents merge and confirmed adoption removes old proof', () async {
    final storage = SecureMemory();
    final transport = mergeTransport();
    final client = await stored(storage, transport, create: true);
    storage.failWrite = true;
    await expectLater(
      client.mergeAnonymousIdentity(() async => 'token', identityKey: 'a'),
      throwsA(code('chat.storage_unavailable')),
    );
    expect(merges(transport), isEmpty);
    expect(client.state, ChatClientState.failed);
    storage.failWrite = false;
    await client.dispose();
    final retryTransport = mergeTransport();
    final retry = await stored(storage, retryTransport);
    await retry.mergeAnonymousIdentity(
      () async => 'new-token',
      identityKey: 'a',
    );
    final source = jsonDecode(
      storage.values.entries
          .where((e) => e.key.endsWith('.anonymous'))
          .single
          .value,
    );
    expect(source['secret'], isNull);
    expect(source['mergeComplete'], true);
    await retry.continueAnonymously();
    expect(retry.state, ChatClientState.ready);
    expect(
      retryTransport.calls
          .where((c) => c.uri.path.endsWith('/sessions/anonymous'))
          .last
          .body!['resumeSecret'],
      isNull,
    );
    await retry.dispose();
  });
  test('verified adoption failure revokes issued credentials and retains recovery marker', () async {
    final storage = SecureMemory();
    final transport = mergeTransport();
    final original = transport.handler!;
    transport.handler = (call) async {
      final response = await original(call);
      if (call.uri.path.endsWith('/identity/merge')) storage.failWrite = true;
      return response;
    };
    final client = await stored(storage, transport, create: true);
    await expectLater(
      client.mergeAnonymousIdentity(() async => 'token', identityKey: 'a'),
      throwsA(code('chat.identity_merge_uncertain')),
    );
    expect(
      transport.calls.any(
        (c) =>
            c.method == 'DELETE' &&
            c.headers['Authorization'] == 'Bearer merged',
      ),
      true,
    );
    expect(
      storage.values.values
          .map((v) => jsonDecode(v))
          .any((v) => v['mergePending'] == true),
      true,
    );
    storage.failWrite = false;
    expect(
      await client.recoverIdentityMerge(() async => 'fresh', identityKey: 'a'),
      ChatIdentityMergeOutcome.recoveredUnconfirmed,
    );
    await client.dispose();
  });

  test(
    'merge discards anonymous replay cursor and late history response',
    () async {
      final transport = mergeTransport();
      final client = await makeClient(transport);
      await client.connect();
      await until(() => transport.sockets.isNotEmpty);
      transport.sockets.single.emit('realtime.ready', {
        'cursor': 'anonymous-boundary',
      });
      await until(
        () => client.connectionState == ChatConnectionState.connected,
      );
      expect(client.cachedConversations, isNotNull);
      final gate = Completer<ChatResponse>();
      final original = transport.handler!;
      transport.handler = (call) =>
          call.uri.path.endsWith('/messages') ? gate.future : original(call);
      final oldRead = client.listMessages('conv_test');
      final assertion = expectLater(
        oldRead,
        throwsA(code('chat.operation_cancelled')),
      );
      await client.mergeAnonymousIdentity(
        () async => 'token',
        identityKey: 'a',
      );
      gate.complete(
        ChatResponse(200, {
          'data': [message()],
          'hasMore': false,
        }),
      );
      await assertion;
      await until(
        () =>
            transport.sockets.length == 2 &&
            transport.sockets.last.sent.isNotEmpty,
      );
      expect(transport.sockets.last.sent.single['cursor'], isNull);
      expect(client.cachedMessages('conv_test'), isNull);
      await client.dispose();
    },
  );

  test(
    'provider failure restores identity and does not write a merge marker',
    () async {
      final storage = SecureMemory();
      final transport = mergeTransport();
      final client = await stored(storage, transport, create: true);
      await expectLater(
        client.mergeAnonymousIdentity(
          () async =>
              throw const ProtodeskChatException('host.login_cancelled'),
          identityKey: 'a',
        ),
        throwsA(code('host.login_cancelled')),
      );
      expect(client.state, ChatClientState.ready);
      expect(merges(transport), isEmpty);
      expect(
        storage.values.values
            .map((v) => jsonDecode(v))
            .any((v) => v['mergePending'] == true),
        false,
      );
      await client.dispose();
    },
  );
  test('failed attachment remains owned by anonymous identity until explicitly discarded', () async {
    final transport = mergeTransport();
    final original = transport.handler!;
    transport.handler = (call) async =>
        call.uri.path.endsWith('/attachments/uploads')
        ? const ChatResponse(422, {
            'error': {'code': 'chat.attachment_invalid'},
          })
        : original(call);
    final client = await initializeChat(
      ChatClientOptions(
        publicChatAppId: appId,
        baseUrl: Uri.parse('https://api.example.test'),
        transport: transport,
        attachmentStorageOrigins: {Uri.parse('https://storage.example.test')},
      ),
    );
    await client.connect();
    await until(() => transport.sockets.isNotEmpty);
    transport.sockets.single.emit('realtime.ready', {'cursor': 'boundary'});
    await until(() => client.connectionState == ChatConnectionState.connected);
    final upload = client.attachments.upload('conv_test', source());
    await upload.settled;
    await expectLater(
      client.mergeAnonymousIdentity(() async => 'token', identityKey: 'a'),
      throwsA(code('chat.identity_merge_pending_work')),
    );
    expect(client.attachments.uploads.single, same(upload));
    expect(merges(transport), isEmpty);
    await client.attachments.cancel(upload);
    await client.mergeAnonymousIdentity(() async => 'token', identityKey: 'a');
    expect(client.identityMergeOutcome, ChatIdentityMergeOutcome.confirmed);
    await client.dispose();
  });
}
