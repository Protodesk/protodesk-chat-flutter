import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';
import 'package:protodesk_chat/src/lifecycle.dart';

import '../support/fake_transport.dart';

void main() {
  test('ready events follow successful sign-in and do not replay', () async {
    final transport = FakeTransport();
    final gate = Completer<void>();
    transport.handler = (call) async {
      await gate.future;
      return transport.respond(call);
    };
    final client = startChat(
      ChatClientOptions(
        publicChatAppId: appId,
        baseUrl: Uri.parse('https://api.example.test'),
        transport: transport,
      ),
    );
    final events = <ChatLifecycleEvent>[];
    final subscription = client.sdkLifecycleEvents.listen(events.add);
    expect(events, isEmpty);
    gate.complete();
    await client.waitUntilReady();
    await Future<void>.delayed(Duration.zero);
    expect(events, [ChatLifecycleEvent.sessionReady]);
    await subscription.cancel();
    final lateEvents = <ChatLifecycleEvent>[];
    final lateSubscription = client.sdkLifecycleEvents.listen(lateEvents.add);
    await Future<void>.delayed(Duration.zero);
    expect(lateEvents, isEmpty);
    lateSubscription.pause();
    client.trackChatPresentation()();
    await client.dispose().timeout(const Duration(seconds: 2));
    lateSubscription.resume();
    await lateSubscription.cancel();
  });

  test(
    'readiness is explicit and identity changes cancel pending readiness',
    () async {
      final transport = FakeTransport();
      final exchange = Completer<ChatResponse>();
      final started = Completer<void>();
      transport.handler = (call) {
        if (call.uri.path.endsWith('/sessions/anonymous')) {
          started.complete();
          return exchange.future;
        }
        return Future.value(transport.respond(call));
      };
      final client = startChat(
        ChatClientOptions(
          publicChatAppId: appId,
          baseUrl: Uri.parse('https://api.example.test'),
          transport: transport,
        ),
      );
      final events = <ChatLifecycleEvent>[];
      final subscription = client.sdkLifecycleEvents.listen(events.add);
      final pending = client.waitUntilReady();
      final rejected = expectLater(
        pending,
        throwsA(isA<ProtodeskChatException>()),
      );
      await started.future;
      final logout = client.logout();
      exchange.complete(ChatResponse(200, session()));
      await rejected;
      await logout;
      expect(events, isEmpty);
      await subscription.cancel();
      await client.dispose();
    },
  );

  test(
    'lifecycle attaches once, detaches, resumes without replay, and closes',
    () async {
      var attached = 0, detached = 0;
      void Function(ChatClientState)? listener;
      final lifecycle = ChatLifecycle((value) {
        listener = value;
        if (value == null) {
          detached++;
        } else {
          attached++;
        }
      });
      expect(attached, 0);
      final a = <ChatLifecycleEvent>[], b = <ChatLifecycleEvent>[];
      final first = lifecycle.events.listen(a.add);
      final second = lifecycle.events.listen(b.add);
      expect(attached, 1);
      listener!(ChatClientState.ready);
      await Future<void>.delayed(Duration.zero);
      expect(a, [ChatLifecycleEvent.sessionReady]);
      expect(b, a);
      await first.cancel();
      expect(detached, 0);
      await second.cancel();
      expect(detached, 1);
      lifecycle.emit(ChatLifecycleEvent.chatOpened);
      final third = lifecycle.events.listen(a.add);
      await Future<void>.delayed(Duration.zero);
      expect(a.length, 1);
      expect(attached, 2);
      await third.cancel();
      lifecycle.dispose();
      lifecycle.emit(ChatLifecycleEvent.chatClosed);
    },
  );

  testWidgets('openChat presents and dismisses without disposing the client', (
    tester,
  ) async {
    final client = await makeClient(FakeTransport());
    final events = <ChatLifecycleEvent>[];
    final subscription = client.sdkLifecycleEvents.listen(events.add);
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            host = context;
            return const SizedBox();
          },
        ),
      ),
    );
    var closed = false;
    final presentation = client
        .openChat(
          host,
          routeSettings: const RouteSettings(name: 'chat'),
          automaticReadReporting: false,
        )
        .then((_) => closed = true);
    await tester.pumpAndSettle();
    final screen = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(screen.client, same(client));
    expect(screen.automaticReadReporting, false);
    expect(events, [ChatLifecycleEvent.chatOpened]);
    expect(closed, false);
    Navigator.of(host).pop();
    await tester.pumpAndSettle();
    // Cancellation detaches synchronously. Do not await its shared completion
    // future across Flutter's fake-clock zones before disposing async resources.
    unawaited(subscription.cancel());
    expect(events, [
      ChatLifecycleEvent.chatOpened,
      ChatLifecycleEvent.chatClosed,
    ]);
    expect(client.state, ChatClientState.ready);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
    await presentation;
  });

  testWidgets('unmounted context and signed-out client cannot open a route', (
    tester,
  ) async {
    final client = await makeClient(FakeTransport());

    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            host = context;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    await expectLater(
      client.openChat(host),
      throwsA(isA<ProtodeskChatException>()),
    );
    await client.logout();
    await expectLater(
      client.waitUntilReady(),
      throwsA(isA<ProtodeskChatException>()),
    );
    await client.dispose();
  });

  test(
    'custom presentation closure is idempotent and client isolated',
    () async {
      final a = await makeClient(FakeTransport());
      final b = await makeClient(FakeTransport());
      final events = <ChatLifecycleEvent>[];
      final other = <ChatLifecycleEvent>[];
      final sa = a.sdkLifecycleEvents.listen(events.add);
      final sb = b.sdkLifecycleEvents.listen(other.add);
      final close = a.trackChatPresentation();
      close();
      close();
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        ChatLifecycleEvent.chatOpened,
        ChatLifecycleEvent.chatClosed,
      ]);
      expect(other, isEmpty);
      await sa.cancel();
      await sb.cancel();
      await a.dispose();
      await b.dispose();
    },
  );
}
