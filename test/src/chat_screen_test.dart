import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/fake_transport.dart';

void main() {
  testWidgets(
    'offline sends appear immediately and a full queue preserves the draft',
    (tester) async {
      final transport = FakeTransport();
      final client = await makeClient(
        transport,
        queueOptions: const ChatSendQueueOptions(maxMessages: 1),
      );
      final lifecycle = <ChatLifecycleEvent>[];
      final lifecycleSubscription = client.sdkLifecycleEvents.listen(
        lifecycle.add,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            client: client,
            initialSection: ChatMessengerSection.messages,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('conv_test')));
      await tester.pumpAndSettle();
      await client.disconnect();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Send',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Send',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), 'Waiting offline');
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Send',
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting offline'), findsOneWidget);
      expect(find.text('Queued'), findsOneWidget);
      expect(
        transport.calls.where(
          (c) => c.method == 'POST' && c.uri.path.endsWith('/messages'),
        ),
        isEmpty,
      );
      await tester.enterText(find.byType(TextField), 'Keep my draft');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Your send queue is full.'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep my draft',
      );
      await tester.tap(find.byTooltip('Discard queued message'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting offline'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(lifecycle, [
        ChatLifecycleEvent.chatOpened,
        ChatLifecycleEvent.chatClosed,
      ]);
      unawaited(lifecycleSubscription.cancel());
      await client.dispose();
    },
  );

  testWidgets(
    'loads conversation and message pages, retries, and shows the end',
    (tester) async {
      final transport = FakeTransport();
      var failOlder = true;
      transport.handler = (call) async {
        if (call.method == 'GET' && call.uri.path.endsWith('/conversations')) {
          final older = call.uri.queryParameters['cursor'] != null;
          return ChatResponse(200, {
            'data': [
              if (!older)
                conversation()
              else
                {
                  ...conversation(),
                  'id': 'conv_old',
                  'subject': 'Earlier support',
                },
            ],
            'hasMore': !older,
            'nextCursor': older ? null : 'older-conversations',
          });
        }
        if (call.method == 'GET' && call.uri.path.endsWith('/messages')) {
          final older = call.uri.queryParameters['cursor'] != null;
          if (older && failOlder)
            return const ChatResponse(503, {
              'error': {'code': 'chat.dependency_unavailable'},
            });
          return ChatResponse(200, {
            'data': [
              message(
                id: older ? 'msg_old' : 'msg_new',
                text: older ? 'Earlier message' : 'Latest message',
              ),
            ],
            'hasMore': !older,
            'nextCursor': older ? null : 'older-messages',
          });
        }
        return transport.respond(call);
      };
      final client = await makeClient(
        transport,
        queueOptions: const ChatSendQueueOptions(maxAttempts: 1),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            client: client,
            initialSection: ChatMessengerSection.messages,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load more conversations'));
      await tester.pumpAndSettle();
      expect(find.text('Earlier support'), findsOneWidget);
      expect(find.text('Load more conversations'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('conv_test')));
      await tester.pumpAndSettle();
      expect(find.text('Latest message'), findsOneWidget);
      await tester.tap(find.text('Load older messages'));
      await tester.pumpAndSettle();
      expect(find.text('Latest message'), findsOneWidget);
      expect(find.text('Retry loading history'), findsOneWidget);
      failOlder = false;
      await tester.tap(find.text('Retry loading history'));
      await tester.pumpAndSettle();
      expect(find.text('Earlier message'), findsOneWidget);
      expect(find.text('Latest message'), findsOneWidget);
      expect(find.text('Beginning of conversation'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );

  testWidgets(
    'opens conversation, retries identical send, and clears messages on logout',
    (tester) async {
      final transport = FakeTransport();
      var attempts = 0;
      transport.handler = (call) async {
        if (call.method == 'POST' &&
            call.uri.path.endsWith('/messages') &&
            ++attempts == 1) {
          transport.respond(call);
          throw const ProtodeskChatException(
            'chat.network_unavailable',
            retryable: true,
          );
        }
        return transport.respond(call);
      };
      final client = await makeClient(
        transport,
        queueOptions: const ChatSendQueueOptions(maxAttempts: 1),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            client: client,
            initialSection: ChatMessengerSection.messages,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start a conversation'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Hello customer');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(transport.messages.length, 1);
      expect(find.text('Hello customer'), findsOneWidget);
      await client.logout();
      await tester.pumpAndSettle();
      expect(find.text('Hello customer'), findsNothing);
      expect(find.text('Sign in to start chatting.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );
}
