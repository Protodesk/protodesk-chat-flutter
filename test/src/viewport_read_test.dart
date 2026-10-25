import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/fake_transport.dart';

List<Call> reads(FakeTransport transport) =>
    transport.calls.where((call) => call.uri.path.endsWith('/read')).toList();

Future<ProtodeskChatClient> openChat(
  WidgetTester tester,
  FakeTransport transport, {
  bool automatic = true,
  GlobalKey<NavigatorState>? navigator,
}) async {
  transport.handler ??= (call) async {
    if (call.uri.path.endsWith('/read')) {
      return ChatResponse(200, {
        'conversationId': 'conv_test',
        'throughMessageId': call.body!['throughMessageId'],
        'unreadCount': 0,
        'readAt': DateTime.now().toIso8601String(),
      });
    }
    return transport.respond(call);
  };
  final client = await makeClient(transport);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: ChatScreen(client: client, automaticReadReporting: automatic),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('conv_test')));
  await tester.pumpAndSettle();
  return client;
}

Future<void> dwell(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

Future<void> closeChat(WidgetTester tester, ProtodeskChatClient client) async {
  await tester.pumpWidget(const SizedBox());
  await client.dispose();
}

void main() {
  testWidgets(
    'visible incoming tile needs dwell, reports once, and opt-out works',
    (tester) async {
      final transport = FakeTransport()
        ..messages.add({...message(), 'sender': 'agent'});
      final client = await openChat(tester, transport);
      expect(reads(transport), isEmpty);
      await dwell(tester);
      expect(reads(transport).single.body, {'throughMessageId': 'msg_test'});
      await dwell(tester);
      expect(reads(transport).length, 1);
      await closeChat(tester, client);
      final disabled = FakeTransport()
        ..messages.add({...message(), 'sender': 'agent'});
      final other = await openChat(tester, disabled, automatic: false);
      await dwell(tester);
      expect(reads(disabled), isEmpty);
      await closeChat(tester, other);
    },
  );

  testWidgets('dialog coverage resets dwell and background never reports', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final transport = FakeTransport()
      ..messages.add({...message(), 'sender': 'agent'});
    final client = await openChat(tester, transport, navigator: navigator);
    await tester.pump(const Duration(milliseconds: 400));
    unawaited(
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Covered')),
      ),
    );
    await tester.pumpAndSettle();
    await dwell(tester);
    expect(reads(transport), isEmpty);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await dwell(tester);
    expect(reads(transport), isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await dwell(tester);
    expect(reads(transport).length, 1);
    await closeChat(tester, client);
  });

  testWidgets(
    'cached offscreen tiles and oversized content are never automatically read',
    (tester) async {
      final transport = FakeTransport();
      transport.messages.add({
        ...message(text: List.filled(120, 'Long message').join('\n')),
        'sender': 'agent',
      });
      final client = await openChat(tester, transport);
      await dwell(tester);
      expect(reads(transport), isEmpty);
      await closeChat(tester, client);
      final cached = FakeTransport();
      for (var i = 0; i < 20; i++) {
        cached.messages.add({
          ...message(id: 'msg_$i', text: 'Message $i'),
          'sender': i == 19 ? 'agent' : 'endUser',
        });
      }
      final other = await openChat(tester, cached);
      await dwell(tester);
      expect(reads(cached), isEmpty);
      await closeChat(tester, other);
    },
  );

  testWidgets(
    'scroll gesture cancels dwell and stationary viewport resumes it',
    (tester) async {
      final transport = FakeTransport();
      for (var i = 0; i < 20; i++) {
        transport.messages.add({
          ...message(id: 'msg_${i.toString().padLeft(2, '0')}'),
          'sender': 'agent',
        });
      }
      final client = await openChat(tester, transport);
      final list = find.byKey(const ValueKey('message-history-conv_test'));
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      await dwell(tester);
      expect(reads(transport), isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      await dwell(tester);
      expect(reads(transport).length, 1);
      await closeChat(tester, client);
    },
  );

  testWidgets(
    'failed automatic report does not loop and logout cancels pending dwell',
    (tester) async {
      final transport = FakeTransport()
        ..messages.add({...message(), 'sender': 'agent'});
      transport.handler = (call) async => call.uri.path.endsWith('/read')
          ? const ChatResponse(503, {
              'error': {'code': 'chat.unavailable'},
            })
          : transport.respond(call);
      final client = await openChat(tester, transport);
      await dwell(tester);
      await dwell(tester);
      expect(reads(transport).length, 1);
      await closeChat(tester, client);
      final otherTransport = FakeTransport()
        ..messages.add({...message(), 'sender': 'agent'});
      final other = await openChat(tester, otherTransport);
      await other.logout();
      await dwell(tester);
      expect(reads(otherTransport), isEmpty);
      await closeChat(tester, other);
    },
  );
  testWidgets(
    'in-flight reports stay single-flight and late results cannot restore signed-out UI',
    (tester) async {
      final transport = FakeTransport()
        ..messages.add({...message(), 'sender': 'agent'});
      final gate = Completer<ChatResponse>();
      transport.handler = (call) async => call.uri.path.endsWith('/read')
          ? gate.future
          : transport.respond(call);
      final client = await openChat(tester, transport);
      await dwell(tester);
      await dwell(tester);
      expect(reads(transport).length, 1);
      await client.logout();
      gate.complete(
        ChatResponse(200, {
          'conversationId': 'conv_test',
          'throughMessageId': 'msg_test',
          'readAt': DateTime.now().toIso8601String(),
          'unreadCount': 0,
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Read through here'), findsNothing);
      expect(find.text('Sign in to start chatting.'), findsOneWidget);
      await closeChat(tester, client);
    },
  );
  testWidgets('retained IndexedStack tab cannot report while hidden', (
    tester,
  ) async {
    final transport = FakeTransport()
      ..messages.add({...message(), 'sender': 'agent'});
    transport.handler = (call) async => call.uri.path.endsWith('/read')
        ? ChatResponse(200, {
            'conversationId': 'conv_test',
            'throughMessageId': 'msg_test',
            'readAt': DateTime.now().toIso8601String(),
            'unreadCount': 0,
          })
        : transport.respond(call);
    final client = await makeClient(transport);
    final index = ValueNotifier<int>(0);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: index,
          builder: (context, value, child) => IndexedStack(
            index: value,
            children: [child!, const Text('Other tab')],
          ),
          child: ChatScreen(client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conv_test')));
    await tester.pumpAndSettle();
    index.value = 1;
    await tester.pump();
    await dwell(tester);
    expect(reads(transport), isEmpty);
    index.value = 0;
    await tester.pump();
    await dwell(tester);
    expect(reads(transport).length, 1);
    await closeChat(tester, client);
    index.dispose();
  });
}
