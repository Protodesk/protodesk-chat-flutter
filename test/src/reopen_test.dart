import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/fake_transport.dart';
import '../support/help_fixtures.dart';

Future<BuildContext> host(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (value) {
          context = value;
          return const Scaffold(body: Text('Host'));
        },
      ),
    ),
  );
  return context;
}

void main() {
  testWidgets(
    'a dismissed draft stays editable across Help and is cleared on identity change',
    (tester) async {
      final client = await makeClient(helpTransport());
      final context = await host(tester);
      unawaited(client.openChat(context, attachmentPicker: () async => null));
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      await tester.enterText(field, 'I still need help');
      final editor = tester.widget<TextField>(field).controller!;
      editor.selection = const TextSelection.collapsed(offset: 3);
      final theme = Theme.of(tester.element(field));
      expect(theme.textTheme.bodyMedium!.fontFamily, 'Roboto');
      expect(theme.colorScheme.onPrimary, Colors.white);
      expect(tester.getSize(find.byTooltip('Close')), const Size.square(36));
      expect(
        tester.getSize(find.byTooltip('Attach file')),
        const Size.square(32),
      );
      expect(tester.getSize(find.byTooltip('Send')), const Size.square(34));
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(find.byType(ChatMessenger), findsNothing);
      unawaited(client.openHelpCenter(context));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'setup');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      unawaited(client.openChat(context));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller, same(editor));
      expect(editor.text, 'I still need help');
      expect(editor.selection.baseOffset, 3);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      unawaited(client.openHelpCenter(context));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, 'setup');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await client.identify(
        () async => 'new-host-session',
        identityKey: 'second-account',
      );
      await tester.pumpAndSettle();
      unawaited(client.openChat(context));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );

  testWidgets(
    'Help preserves the article, its scroll offset, and Back to the topic',
    (tester) async {
      final client = await makeClient(helpTransport());
      final context = await host(tester);
      unawaited(client.openHelpCenter(context));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('help-collection-getting-started')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('What is Protodesk?'));
      await tester.pumpAndSettle();
      final body = find.byType(SingleChildScrollView).first;
      await tester.drag(body, const Offset(0, -175));
      await tester.pumpAndSettle();
      final controller = tester.widget<SingleChildScrollView>(body).controller!;
      final offset = controller.offset;
      expect(offset, greaterThan(0));
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      unawaited(client.openHelpCenter(context));
      await tester.pumpAndSettle();
      expect(find.text('What you can do'), findsOneWidget);
      expect(controller.offset, offset);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      unawaited(client.openHelpCenterArticle(context, 'a5'));
      await tester.pumpAndSettle();
      expect(controller.offset, offset);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Navigate your Protodesk workspace'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );
}
