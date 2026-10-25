import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/fake_transport.dart';

void main() {
  testWidgets(
    'locale and theme switch preserves draft and does not translate content',
    (tester) async {
      final t = FakeTransport();
      t.messages.add(message(text: 'Customer original message'));
      final client = await makeClient(t);
      Widget host(Locale locale, ThemeData theme) => MaterialApp(
        locale: locale,
        theme: theme,
        supportedLocales: ChatLocalizations.supportedLocales,
        localizationsDelegates: ChatLocalizations.localizationsDelegates,
        home: ChatScreen(client: client, initialConversationId: 'conv_test'),
      );
      await tester.pumpWidget(host(const Locale('en'), ChatTheme.light()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Keep this draft');
      await tester.pumpWidget(host(const Locale('id'), ChatTheme.dark()));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Kirim'), findsOneWidget);
      expect(find.byTooltip('Percakapan'), findsOneWidget);
      expect(find.text('Customer original message'), findsOneWidget);
      expect(find.text('Keep this draft'), findsOneWidget);
      expect(
        Theme.of(tester.element(find.byType(TextField))).brightness,
        Brightness.dark,
      );
      expect(find.byTooltip('Percakapan'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );
  testWidgets('screen branding and copy overrides stay local to chat', (
    tester,
  ) async {
    final client = await makeClient(FakeTransport());
    final brand = ChatTheme.dark(brandColor: Colors.orange);
    await tester.pumpWidget(
      MaterialApp(
        theme: ChatTheme.light(),
        home: ChatScreen(
          client: client,
          initialSection: ChatMessengerSection.messages,
          theme: brand,
          localizations: ChatLocalizations(
            const Locale('en'),
            overrides: {ChatText.startConversation: 'Talk to our team'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Talk to our team'), findsOneWidget);
    expect(
      Theme.of(tester.element(find.byType(FilledButton))).colorScheme,
      brand.colorScheme,
    );
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });
}
