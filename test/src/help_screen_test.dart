import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/bootstrap.dart';
import '../support/fake_transport.dart';
import '../support/help_fixtures.dart';

FakeTransport helpTransport({
  bool help = true,
  bool unavailable = false,
  bool featured = true,
}) {
  final transport = FakeTransport();
  transport.handler = (call) async {
    final path = call.uri.path;
    if (path.endsWith('/bootstrap')) {
      return ChatResponse(200, bootstrap(help: help));
    }
    if (path.contains('/help-center') && unavailable) {
      return const ChatResponse(404, {
        'error': {'code': 'chat.help_center_unavailable'},
      });
    }
    return helpResponse(call, featured: featured) ?? transport.respond(call);
  };
  return transport;
}

Iterable<Call> helpCalls(FakeTransport transport) =>
    transport.calls.where((c) => c.uri.path.contains('/help-center'));

Future<ProtodeskChatClient> pumpMessenger(
  WidgetTester tester,
  FakeTransport transport, {
  ChatMessengerSection section = ChatMessengerSection.help,
  Future<void> Function(Uri)? onOpenLink,
}) async {
  final client = await makeClient(transport);
  await tester.pumpWidget(
    MaterialApp(
      home: ChatMessenger(
        client: client,
        initialSection: section,
        onOpenLink: onOpenLink,
        automaticReadReporting: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return client;
}

Finder get navigation => find.byType(NavigationBar);
Finder tab(String label) =>
    find.descendant(of: navigation, matching: find.text(label));

void main() {
  testWidgets('Help tab appears only with published Help', (tester) async {
    var client = await pumpMessenger(
      tester,
      helpTransport(),
      section: ChatMessengerSection.home,
    );
    expect(tab('Help'), findsOneWidget);
    expect(find.text('Find an answer'), findsOneWidget);
    expect(
      find.text(
        'We’re here to help. Ask a question or find an answer in the Help Center.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await client.dispose();

    client = await pumpMessenger(
      tester,
      helpTransport(help: false),
      section: ChatMessengerSection.home,
    );
    expect(tab('Help'), findsNothing);
    expect(find.text('Find an answer'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();

    // Enabled in configuration, but the server reports no published content.
    final transport = helpTransport(unavailable: true);
    client = await pumpMessenger(tester, transport);
    expect(tab('Help'), findsNothing);
    expect(find.text('Chat with us'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('browse a topic, read an article, go back', (tester) async {
    final opened = <Uri>[];
    final transport = helpTransport();
    final client = await pumpMessenger(
      tester,
      transport,
      onOpenLink: (url) async => opened.add(url),
    );
    expect(find.text('Protodesk'), findsOneWidget);
    expect(
      find.text('Find clear answers from our support team.'),
      findsOneWidget,
    );
    expect(find.text('Browse topics'), findsOneWidget);
    expect(find.text('Still need help?'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('help-collection-getting-started')),
    );
    await tester.pumpAndSettle();
    expect(
      helpCalls(transport).last.uri.queryParameters['collectionId'],
      'getting-started',
    );
    expect(find.text('Navigate your Protodesk workspace'), findsOneWidget);

    await tester.tap(find.text('What is Protodesk?'));
    await tester.pumpAndSettle();
    expect(find.text('What you can do'), findsOneWidget);
    expect(find.text('On this page'), findsOneWidget);
    expect(find.text('npx protodesk init'), findsOneWidget);
    expect(find.text('Starter'), findsOneWidget);
    expect(find.text('Related articles'), findsOneWidget);

    await tester.tap(find.byTooltip('Open in Help Center'));
    expect(
      opened.single.toString(),
      'https://help.example.test/en/articles/slug-a5',
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Navigate your Protodesk workspace'), findsOneWidget);
    // System back also walks the Help stack before leaving the screen.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Browse topics'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('article links open through the host adapter', (tester) async {
    final opened = <Uri>[];
    final client = await pumpMessenger(
      tester,
      helpTransport(),
      onOpenLink: (url) async => opened.add(url),
    );
    await tester.tap(find.text('View all articles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('What is Protodesk?'));
    await tester.pumpAndSettle();
    final link = find.textContaining('the setup guide', findRichText: true);
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tapOnText(find.textRange.ofSubstring('the setup guide'));
    expect(opened, [Uri.parse('https://help.example.test/en/articles/setup')]);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('search needs two characters and explains empty results', (
    tester,
  ) async {
    final transport = helpTransport();
    final client = await pumpMessenger(tester, transport);
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pump();
    expect(find.text('Type at least 2 characters to search.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'workspace');
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      helpCalls(transport).where((c) => c.uri.queryParameters['query'] != null),
      isEmpty,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(helpCalls(transport).last.uri.queryParameters['query'], 'workspace');
    expect(find.text('Search results'), findsOneWidget);
    expect(find.text('Navigate your Protodesk workspace'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nothing');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('No articles match this search.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('Contact support starts a conversation', (tester) async {
    final transport = helpTransport();
    final client = await pumpMessenger(tester, transport);
    await tester.ensureVisible(find.text('Contact support'));
    await tester.tap(find.text('Contact support'));
    await tester.pumpAndSettle();
    expect(
      transport.calls.where(
        (c) => c.method == 'POST' && c.uri.path.endsWith('/conversations'),
      ),
      hasLength(1),
    );
    expect(find.byTooltip('Send'), findsOneWidget);
    await tester.tap(find.byTooltip('Conversations'));
    await tester.pumpAndSettle();
    expect(find.text('Browse topics'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('Home suggestions and search open Help', (tester) async {
    final transport = helpTransport();
    final client = await pumpMessenger(
      tester,
      transport,
      section: ChatMessengerSection.home,
    );
    expect(find.text('Add knowledge sources for Evelin'), findsOneWidget);
    expect(find.text('Install Live Chat on your website'), findsOneWidget);
    await tester.tap(find.text('Use Evelin to prepare customer replies'));
    await tester.pumpAndSettle();
    expect(find.text('What you can do'), findsOneWidget);
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 2);

    await tester.tap(tab('Home'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'workspace');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Search results'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('Home lists topics when nothing is featured', (tester) async {
    final client = await pumpMessenger(
      tester,
      helpTransport(featured: false),
      section: ChatMessengerSection.home,
    );
    expect(find.text('Getting started'), findsOneWidget);
    expect(find.text('Conversations'), findsWidgets);
    await tester.ensureVisible(find.text('View all articles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View all articles'));
    await tester.pumpAndSettle();
    expect(find.text('All articles'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('language choice reloads Help in that locale', (tester) async {
    final transport = helpTransport();
    final client = await pumpMessenger(tester, transport);
    await tester.tap(find.byTooltip('Language: English'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bahasa Indonesia').last);
    await tester.pumpAndSettle();
    expect(helpCalls(transport).last.uri.queryParameters['locale'], 'id');
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  group('entry points', () {
    Future<BuildContext> launcher(WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      return captured;
    }

    testWidgets('openHelpCenter opens Help and closes the route', (
      tester,
    ) async {
      final client = await makeClient(helpTransport());
      final context = await launcher(tester);
      final opened = client.openHelpCenter(context);
      await tester.pump();
      // Help shows immediately while configuration loads: no Home flash.
      expect(find.text('Chat with us'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('Browse topics'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await opened;
      expect(find.byType(ChatMessenger), findsNothing);
      await client.dispose();
    });

    testWidgets('openHelpCenterArticle shows the article; Back goes to Help', (
      tester,
    ) async {
      final transport = helpTransport();
      final links = <Uri>[];
      final client = await makeClient(transport);
      final context = await launcher(tester);
      unawaited(
        client.openHelpCenterArticle(
          context,
          'a5',
          onOpenLink: (url) async => links.add(url),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('What you can do'), findsOneWidget);
      expect(
        helpCalls(transport).any((c) => c.uri.path.endsWith('/a5')),
        isTrue,
      );
      // The slug arrives with the article, enabling the public link.
      await tester.tap(find.byTooltip('Open in Help Center'));
      expect(links.single.path, '/en/articles/slug-a5');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Browse topics'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });

    testWidgets('falls back to Home when Help is unavailable', (tester) async {
      final client = await makeClient(helpTransport(unavailable: true));
      final context = await launcher(tester);
      unawaited(client.openHelpCenter(context));
      await tester.pumpAndSettle();
      expect(find.text('Chat with us'), findsOneWidget);
      expect(tab('Help'), findsNothing);
      expect(
        () => client.openHelpCenterArticle(context, ''),
        throwsA(isA<ProtodeskChatException>()),
      );
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });
  });
}
