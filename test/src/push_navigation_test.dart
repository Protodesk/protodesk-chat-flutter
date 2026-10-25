import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart';

const conv = 'conv_aaaaaaaaaaaaaaaaaaaaaaaaaa';
const intent = 'nti_aaaaaaaaaaaaaaaaaaaaaaaaaa';
Map<String, dynamic> payload({
  String id = intent,
  String app = appId,
  String conversationId = conv,
}) => {
  'protodesk': {
    'schemaVersion': 1,
    'type': 'message.created',
    'publicChatAppId': app,
    'conversationId': conversationId,
    'notificationIntentId': id,
  },
};
FakeTransport pushTransport() {
  final t = FakeTransport();
  t.handler = (call) async {
    if (call.method == 'GET' &&
        call.uri.path.startsWith('/v1/chat/conversations/')) {
      return ChatResponse(200, {
        ...conversation(),
        'id': call.uri.pathSegments.last,
      });
    }
    return t.respond(call);
  };
  return t;
}

void main() {
  test(
    'lifecycle reports accepted taps once, independent of reporting failure',
    () async {
      final transport = pushTransport();
      final original = transport.handler!;
      transport.handler = (call) async {
        if (call.uri.path.endsWith('/open')) return const ChatResponse(503, {});
        return original(call);
      };
      final client = await makeClient(transport);
      final events = <ChatLifecycleEvent>[];
      final subscription = client.sdkLifecycleEvents.listen(events.add);
      var accept = false;
      final nav = client.createPushNavigation(onNavigate: (_) => accept);
      nav.setReadiness(active: true, navigatorReady: true);
      nav.handlePushPayload(payload());
      await until(() => !nav.hasPending);
      expect(events, isEmpty);
      accept = true;
      final next = payload(id: 'nti_baaaaaaaaaaaaaaaaaaaaaaaaa');
      nav.handlePushPayload(next);
      await until(() => events.isNotEmpty);
      nav.handlePushPayload(next);
      await Future<void>.delayed(Duration.zero);
      expect(events, [ChatLifecycleEvent.pushOpened]);
      await nav.dispose();
      await subscription.cancel();
      await client.dispose();
    },
  );

  test('logout from host navigation suppresses stale push lifecycle', () async {
    final client = await makeClient(pushTransport());
    final events = <ChatLifecycleEvent>[];
    final subscription = client.sdkLifecycleEvents.listen(events.add);
    Future<void>? logout;
    final nav = client.createPushNavigation(
      onNavigate: (_) {
        logout = client.logout();
        return true;
      },
    );
    nav.setReadiness(active: true, navigatorReady: true);
    nav.handlePushPayload(payload());
    await until(() => logout != null);
    await logout;
    expect(events, isEmpty);
    await nav.dispose();
    await subscription.cancel();
    await client.dispose();
  });

  test('strict envelopes accept provider shapes and reject spoofed/unsupported data', () {
    expect(isProtodeskPush(payload(), publicChatAppId: appId), isTrue);
    expect(
      isProtodeskPush({
        'protodesk': jsonEncode(payload()['protodesk']),
      }, publicChatAppId: appId),
      isTrue,
    );
    for (final data in [
      null,
      {},
      payload(app: 'other'),
      payload(conversationId: '../evil'),
      {'protodesk': '{broken'},
      {
        'protodesk': {'schemaVersion': 2},
      },
      {
        'protodesk': {...payload()['protodesk'], 'type': 'chat.push.test'},
      },
      payload(id: 'nti_aaaaaaaaaaaaaaaaaaaaaaaaab'),
    ]) {
      expect(isProtodeskPush(data, publicChatAppId: appId), isFalse);
    }
  });
  test('buffers latest, deduplicates, waits for foreground and navigator, reports only open', () async {
    final transport = pushTransport();
    final client = await makeClient(transport);
    addTearDown(client.dispose);
    final opened = <String>[];
    final nav = client.createPushNavigation(
      onNavigate: (c) {
        opened.add(c.id);
        return true;
      },
    );
    addTearDown(nav.dispose);
    nav.handlePushPayload(payload());
    const newer = 'nti_baaaaaaaaaaaaaaaaaaaaaaaaa';
    nav.handlePushPayload(
      payload(id: newer, conversationId: 'conv_baaaaaaaaaaaaaaaaaaaaaaaaa'),
    );
    nav.setReadiness(active: false, navigatorReady: true);
    await Future<void>.delayed(Duration.zero);
    expect(opened, isEmpty);
    nav.setReadiness(active: true, navigatorReady: true);
    await until(
      () => transport.calls.any((c) => c.uri.path.endsWith('/$newer/open')),
    );
    expect(opened, ['conv_baaaaaaaaaaaaaaaaaaaaaaaaa']);
    nav.handlePushPayload(payload(id: newer));
    await Future<void>.delayed(Duration.zero);
    expect(opened.length, 1);
    expect(transport.calls.any((c) => c.uri.path.endsWith('/read')), isFalse);
  });
  test(
    'cold-start waits for sign-in; stale identity response never navigates',
    () async {
      final transport = pushTransport();
      final login = Completer<ChatResponse>();
      final resolve = Completer<ChatResponse>();
      transport.handler = (call) async {
        if (call.uri.path == '/v1/chat/sessions' && call.method == 'POST')
          return login.future;
        if (call.uri.path.endsWith('/$conv')) return resolve.future;
        return transport.respond(call);
      };
      final client = startChat(
        ChatClientOptions(
          publicChatAppId: appId,
          baseUrl: Uri.parse('https://api.example.test'),
          transport: transport,
        ),
      );
      addTearDown(client.dispose);
      var count = 0;
      final nav = client.createPushNavigation(
        onNavigate: (_) {
          count++;
          return true;
        },
      );
      addTearDown(nav.dispose);
      nav.handlePushPayload(payload());
      nav.setReadiness(active: true, navigatorReady: true);
      expect(count, 0);
      login.complete(ChatResponse(201, session()));
      await client.ready;
      await until(
        () => transport.calls.any((c) => c.uri.path.endsWith('/$conv')),
      );
      await client.logout();
      resolve.complete(ChatResponse(200, {...conversation(), 'id': conv}));
      await Future<void>.delayed(Duration.zero);
      expect(count, 0);
      expect(nav.handlePushPayload(payload()), isFalse);
      expect(nav.hasPending, isFalse);
    },
  );
  test(
    'expired tap and unauthorized conversation never navigate or report',
    () async {
      final transport = pushTransport();
      final client = await makeClient(transport);
      addTearDown(client.dispose);
      var count = 0;
      final nav = client.createPushNavigation(
        onNavigate: (_) {
          count++;
          return true;
        },
        pendingLifetime: const Duration(milliseconds: 10),
      );
      addTearDown(nav.dispose);
      final errors = <ProtodeskChatException>[];
      final sub = nav.errors.listen(errors.add);
      addTearDown(sub.cancel);
      nav.handlePushPayload(payload());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      nav.setReadiness(active: true, navigatorReady: true);
      expect(nav.hasPending, isFalse);
      transport.handler = (call) async => call.uri.path.endsWith('/$conv')
          ? const ChatResponse(404, {'code': 'chat.conversation_not_found'})
          : transport.respond(call);
      nav.handlePushPayload(payload(id: 'nti_baaaaaaaaaaaaaaaaaaaaaaaaa'));
      await until(() => errors.isNotEmpty);
      expect(count, 0);
      expect(transport.calls.any((c) => c.uri.path.endsWith('/open')), isFalse);
    },
  );
  test('background during lookup defers until resume; newer tap supersedes in-flight', () async {
    final transport = pushTransport();
    final client = await makeClient(transport);
    addTearDown(client.dispose);
    final first = Completer<ChatResponse>();
    var gets = 0;
    transport.handler = (call) async {
      if (call.method == 'GET') {
        if (++gets == 1) return first.future;
        return ChatResponse(200, {
          ...conversation(),
          'id': call.uri.pathSegments.last,
        });
      }
      return transport.respond(call);
    };
    final opened = <String>[];
    final nav = client.createPushNavigation(
      onNavigate: (c) {
        opened.add(c.id);
        return true;
      },
    );
    addTearDown(nav.dispose);
    nav.setReadiness(active: true, navigatorReady: true);
    nav.handlePushPayload(payload());
    await until(() => gets == 1);
    nav.setReadiness(active: false, navigatorReady: true);
    first.complete(ChatResponse(200, {...conversation(), 'id': conv}));
    await Future<void>.delayed(Duration.zero);
    expect(opened, isEmpty);
    nav.handlePushPayload(
      payload(
        id: 'nti_baaaaaaaaaaaaaaaaaaaaaaaaa',
        conversationId: 'conv_baaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    );
    nav.setReadiness(active: true, navigatorReady: true);
    await until(() => opened.isNotEmpty);
    expect(opened, ['conv_baaaaaaaaaaaaaaaaaaaaaaaaa']);
  });
  test('route refusal does not report and dispose fences lookup', () async {
    final transport = pushTransport();
    final client = await makeClient(transport);
    addTearDown(client.dispose);
    var count = 0;
    final nav = client.createPushNavigation(
      onNavigate: (_) {
        count++;
        return false;
      },
    );
    nav.setReadiness(active: true, navigatorReady: true);
    nav.handlePushPayload(payload());
    await until(() => count == 1);
    expect(transport.calls.any((c) => c.uri.path.endsWith('/open')), isFalse);
    await nav.dispose();
    expect(nav.handlePushPayload(payload()), isFalse);
  });
  test('session refresh completes before navigation; reporting failure never reopens route', () async {
    final t = pushTransport();
    var lookups = 0;
    final refresh = Completer<ChatResponse>();
    t.handler = (call) async {
      if (call.uri.path.endsWith('/$conv')) {
        if (++lookups == 1)
          return const ChatResponse(401, {'code': 'chat.session_expired'});
        return ChatResponse(200, {...conversation(), 'id': conv});
      }
      if (call.uri.path.endsWith('/sessions/refresh')) return refresh.future;
      if (call.uri.path.endsWith('/open'))
        return const ChatResponse(503, {'code': 'chat.unavailable'});
      return t.respond(call);
    };
    final c = await makeClient(t);
    addTearDown(c.dispose);
    var opened = 0;
    final n = c.createPushNavigation(
      onNavigate: (_) {
        opened++;
        return true;
      },
    );
    addTearDown(n.dispose);
    final errors = <ProtodeskChatException>[];
    final sub = n.errors.listen(errors.add);
    addTearDown(sub.cancel);
    n.setReadiness(active: true, navigatorReady: true);
    n.handlePushPayload(payload());
    await until(
      () => t.calls.any((c) => c.uri.path.endsWith('/sessions/refresh')),
    );
    expect(opened, 0);
    refresh.complete(ChatResponse(200, session(token: 'refreshed')));
    await until(() => errors.isNotEmpty);
    expect(opened, 1);
    n.handlePushPayload(payload());
    await Future<void>.delayed(Duration.zero);
    expect(opened, 1);
  });
}
