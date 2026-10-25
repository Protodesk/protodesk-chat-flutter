import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/fake_transport.dart';

void main() {
  testWidgets(
    'push route opens selected history and identity change clears it',
    (tester) async {
      final t = FakeTransport();
      t.messages.add(message(text: 'Push conversation history'));
      final client = await makeClient(t);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(client: client, initialConversationId: 'conv_test'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Push conversation history'), findsOneWidget);
      expect(
        t.calls.any((c) => c.uri.path.endsWith('/conv_test/messages')),
        isTrue,
      );
      await client.logout();
      await tester.pumpAndSettle();
      expect(find.text('Push conversation history'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );
}
