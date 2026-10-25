import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/bootstrap.dart';
import '../support/fake_transport.dart';
import '../support/help_fixtures.dart';

/// Every messenger view, reached the way a person would.
enum View { home, messages, thread, help, article, setup }

FakeTransport qualityTransport({bool setup = false}) {
  final transport = FakeTransport();
  transport.messages.addAll([
    {
      ...message(id: 'msg_agent', text: 'We can help with your order.'),
      'sender': 'agent',
    },
    message(id: 'msg_customer', text: 'Where is my order?'),
  ]);
  transport.handler = (call) async {
    final path = call.uri.path;
    final help = helpResponse(call);
    if (help != null) return help;
    if (path.endsWith('/bootstrap')) {
      final body = bootstrap(
        appearance: {'preferredColorScheme': 'system', 'logoUrl': null},
        preChatForm: setup
            ? {
                'enabled': true,
                'intro': 'Tell us about you.',
                'fields': [
                  {
                    'id': 'name',
                    'type': 'text',
                    'label': 'Name',
                    'required': true,
                  },
                  {
                    'id': 'topic',
                    'type': 'select',
                    'label': 'Topic',
                    'required': false,
                    'options': ['Billing', 'Shipping'],
                  },
                  {
                    'id': 'consent',
                    'type': 'checkbox',
                    'label': 'I agree to be contacted',
                    'required': true,
                  },
                ],
              }
            : null,
        widget: {
          if (setup)
            'routingChoices': [
              {'id': 'sales', 'label': 'Buying Protodesk'},
            ],
        },
      );
      (body['capabilities'] as Map<String, dynamic>)['anonymousIdentityReset'] =
          true;
      return ChatResponse(200, body);
    }
    if (setup && path.endsWith('/conversations') && call.method == 'GET') {
      return const ChatResponse(200, {
        'data': [],
        'hasMore': false,
        'nextCursor': null,
      });
    }
    return transport.respond(call);
  };
  return transport;
}

Future<ProtodeskChatClient> reach(
  WidgetTester tester,
  View view, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  TextDirection direction = TextDirection.ltr,
  Locale locale = const Locale('en'),
}) async {
  final transport = qualityTransport(setup: view == View.setup);
  final client = await makeClient(transport);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: ChatLocalizations.localizationsDelegates,
      supportedLocales: ChatLocalizations.supportedLocales,
      theme: ChatTheme.light(),
      darkTheme: ChatTheme.dark(),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
          platformBrightness: brightness,
        ),
        child: Directionality(textDirection: direction, child: child!),
      ),
      home: ChatMessenger(
        client: client,
        onClose: () {},
        onOpenLink: (_) async {},
        attachmentPicker: () async => null,
        automaticReadReporting: false,
        initialConversationId: view == View.thread ? 'conv_test' : null,
        initialSection: switch (view) {
          View.messages => ChatMessengerSection.messages,
          View.help || View.article => ChatMessengerSection.help,
          _ => ChatMessengerSection.home,
        },
        initialHelpArticleId: view == View.article ? 'a5' : null,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (view == View.thread) {
    transport.sockets.single.emit('realtime.ready', {'cursor': 'q'});
    await tester.pumpAndSettle();
  }
  if (view == View.setup) {
    final start = find.byKey(const ValueKey('home-start'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();
  }
  return client;
}

void main() {
  for (final view in View.values) {
    for (final brightness in Brightness.values) {
      testWidgets('${view.name} ${brightness.name}: tap targets, labels, '
          'contrast', (tester) async {
        final semantics = tester.ensureSemantics();
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final client = await reach(tester, view, brightness: brightness);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        await tester.pumpWidget(const SizedBox());
        await client.dispose();
        semantics.dispose();
      });
    }
  }

  for (final view in View.values) {
    for (final (size, scale) in [
      (const Size(320, 640), 2.0),
      (const Size(320, 740), 3.0),
      (const Size(740, 320), 2.0),
    ]) {
      testWidgets('${view.name} at ${scale}x on $size lays out without '
          'overflow', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final client = await reach(
          tester,
          view,
          scale: scale,
          locale: const Locale('id'),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await client.dispose();
      });
    }
    testWidgets('${view.name} right-to-left lays out without overflow', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final client = await reach(tester, view, direction: TextDirection.rtl);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });
  }

  testWidgets('phones get a bottom bar; wide layouts get a rail', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    var client = await reach(tester, View.home);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();

    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    client = await reach(tester, View.home);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();
    expect(find.text('Your conversations'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });
}
