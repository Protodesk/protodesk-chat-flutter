import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/fake_transport.dart';

void main() {
  testWidgets(
    'agent indicators isolate actors, ignore customer echoes and expire independently',
    (tester) async {
      final transport = FakeTransport();
      final client = await makeClient(transport);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(client: client)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('conv_test')));
      await tester.pumpAndSettle();
      final socket = transport.sockets.single;
      socket.emit('realtime.ready', {'cursor': 'c1'});
      await tester.pump();
      await tester.pump();
      final now = DateTime.now().toUtc();
      final a = 'actor_${List.filled(64, 'a').join()}';
      final b = 'actor_${List.filled(64, 'b').join()}';
      void emit({
        String? actor,
        bool typing = true,
        int offset = 0,
        int ttl = 8,
        String conversation = 'conv_test',
      }) {
        final at = now.add(Duration(milliseconds: offset));
        socket.emit('typing.changed', {
          'conversationId': conversation,
          'typing': typing,
          'occurredAt': at.toIso8601String(),
          'expiresAt': at.add(Duration(seconds: ttl)).toIso8601String(),
          if (actor != null) 'actor': {'kind': 'agent', 'id': actor},
        });
      }

      emit(); // Legacy customer echo.
      await tester.pump();
      await tester.pump();
      expect(client.typingAgents('conv_test'), isEmpty);
      expect(find.text('Support is typing…'), findsNothing);
      emit(actor: a, ttl: 1);
      emit(actor: b, ttl: 3);
      await tester.pump();
      await tester.pump();
      expect(client.typingAgents('conv_test').length, 2);
      expect(find.text('Support agents are typing…'), findsOneWidget);
      emit(
        typing: false,
        offset: 1,
        ttl: 0,
      ); // Customer stop cannot stop agents.
      await tester.pump();
      await tester.pump();
      expect(client.typingAgents('conv_test').length, 2);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump();
      expect(client.typingAgents('conv_test').single.id, b);
      expect(find.text('Support is typing…'), findsOneWidget);
      emit(actor: b, typing: false, offset: 2, ttl: 0);
      emit(actor: b); // Reordered start cannot revive stopped actor.
      emit(
        actor: 'usr_private',
      ); // Invalid actor cannot be relabeled as customer/agent.
      emit(actor: a, conversation: 'conv_elsewhere', ttl: 2);
      await tester.pump();
      await tester.pump();
      expect(client.typingAgents('conv_test'), isEmpty);
      expect(find.text('Support is typing…'), findsNothing);
      expect(client.typingAgents('conv_elsewhere').length, 1);
      await client.disconnect();
      expect(client.typingAgents('conv_elsewhere'), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );
}
