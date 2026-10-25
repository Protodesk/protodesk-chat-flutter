import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/bootstrap.dart';
import '../support/fake_transport.dart';

/// Serves a configured bootstrap; everything else uses the fake defaults.
FakeTransport configured({
  String greeting = 'Hi! How can we help you?',
  String status = 'open',
}) {
  final transport = FakeTransport();
  transport.handler = (call) async {
    final path = call.uri.path;
    if (path.endsWith('/bootstrap')) {
      return ChatResponse(200, bootstrap(widget: {'greeting': greeting}));
    }
    if (path.endsWith('/conversations') && call.method == 'GET') {
      return ChatResponse(200, {
        'data': [
          {...conversation(), 'status': status, 'unreadCount': 2},
        ],
        'hasMore': false,
        'nextCursor': null,
      });
    }
    return transport.respond(call);
  };
  return transport;
}

Widget host(
  ProtodeskChatClient client, {
  VoidCallback? onClose,
  bool reduceMotion = false,
  String? initial,
  ChatMessengerSection section = ChatMessengerSection.messages,
  Future<void> Function(Uri)? onOpenLink,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: child!,
  ),
  home: ChatMessenger(
    client: client,
    onClose: onClose,
    initialConversationId: initial,
    automaticReadReporting: false,
    initialSection: section,
    onOpenLink: onOpenLink,
  ),
);

void main() {
  testWidgets('Messages section lists cards and starts conversations', (
    tester,
  ) async {
    final transport = configured();
    final client = await makeClient(transport);
    await tester.pumpWidget(host(client));
    await tester.pumpAndSettle();
    // Section header and the selected tab.
    expect(find.text('Messages'), findsNWidgets(2));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
    expect(find.text('Your conversations'), findsOneWidget);
    expect(find.text('Pick up where you left off.'), findsOneWidget);
    final card = find.byKey(const ValueKey('conv_test'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('2')), findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.textContaining('Open · ')),
      findsOneWidget,
    );
    expect(find.text('Start a conversation'), findsOneWidget);
    expect(find.byTooltip('Close'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('empty Messages section explains where replies go', (
    tester,
  ) async {
    final transport = FakeTransport();
    transport.handler = (call) async =>
        call.uri.path.endsWith('/conversations') && call.method == 'GET'
        ? const ChatResponse(200, {
            'data': [],
            'hasMore': false,
            'nextCursor': null,
          })
        : transport.respond(call);
    final client = await makeClient(transport);
    await tester.pumpWidget(host(client));
    await tester.pumpAndSettle();
    expect(find.text('No messages yet'), findsOneWidget);
    expect(
      find.text('Start a conversation and your replies will stay here.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('thread header shows brand, status, back and close', (
    tester,
  ) async {
    final transport = configured();
    final client = await makeClient(transport);
    var closed = 0;
    await tester.pumpWidget(host(client, onClose: () => closed++));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conv_test')));
    await tester.pumpAndSettle();
    // App name in the header (the greeting bubble repeats it as sender).
    expect(find.text('Protodesk'), findsWidgets);
    expect(find.text('Connecting…'), findsOneWidget);
    transport.sockets.single.emit('realtime.ready', {'cursor': 'c1'});
    await tester.pumpAndSettle();
    // A healthy connection needs no status line in a conversation.
    expect(find.text('Connected'), findsNothing);
    expect(find.text('Powered by Protodesk'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    expect(closed, 1);
    await tester.tap(find.byTooltip('Conversations'));
    await tester.pumpAndSettle();
    expect(find.text('Your conversations'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('greeting types briefly, then shows; empty threads guide', (
    tester,
  ) async {
    final transport = configured();
    final client = await makeClient(transport);
    await tester.pumpWidget(host(client, initial: 'conv_test'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Hi! How can we help you?'), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Hi! How can we help you?'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();

    final reduced = await makeClient(configured());
    await tester.pumpWidget(
      host(reduced, initial: 'conv_test', reduceMotion: true),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Hi! How can we help you?'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await reduced.dispose();

    final plain = await makeClient(configured(greeting: ''));
    await tester.pumpWidget(host(plain, initial: 'conv_test'));
    await tester.pumpAndSettle();
    expect(find.text('Start the conversation'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await plain.dispose();
  });

  testWidgets('bubbles: customer at the end, notices labelled, reply note', (
    tester,
  ) async {
    final transport = configured();
    transport.messages.addAll([
      {
        ...message(id: 'msg_notice', text: 'Chat was reassigned'),
        'sender': 'system',
      },
      message(id: 'msg_customer', text: 'Where is my order?'),
    ]);
    final client = await makeClient(transport);
    await tester.pumpWidget(host(client, initial: 'conv_test'));
    await tester.pumpAndSettle();
    expect(find.text('Automated notice'), findsOneWidget);
    expect(
      find.text('Message received. Replies will appear here.'),
      findsOneWidget,
    );
    final screen = tester.getRect(find.byType(ChatMessenger));
    final bubble = tester.getRect(find.text('Where is my order?'));
    expect(bubble.center.dx, greaterThan(screen.center.dx));

    transport.messages.insert(0, {
      ...message(id: 'msg_reply', text: 'Shipped today'),
      'sender': 'agent',
    });
    await client.listMessages('conv_test');
    await tester.tap(find.byTooltip('Conversations'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conv_test')));
    await tester.pumpAndSettle();
    final reply = tester.getRect(find.text('Shipped today'));
    expect(reply.center.dx, lessThan(screen.center.dx));
    expect(
      find.text('Message received. Replies will appear here.'),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('closed conversations disable the composer with a notice', (
    tester,
  ) async {
    final transport = configured(status: 'closed');
    final client = await makeClient(transport);
    await tester.pumpWidget(host(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conv_test')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This conversation is closed. Start a new conversation to contact support.',
      ),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    final send = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Send'),
        matching: find.byType(IconButton),
      ),
    );
    expect(send.onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('Chat App brand colour themes the messenger; host theme wins', (
    tester,
  ) async {
    final client = await makeClient(configured());
    await tester.pumpWidget(host(client, initial: 'conv_test'));
    await tester.pumpAndSettle();
    final branded = Theme.of(tester.element(find.byType(TextField)));
    expect(branded.brightness, Brightness.dark); // preferredColorScheme: dark
    // The configured colour itself, not Material's derived tone.
    expect(branded.colorScheme.primary, const Color(0xff00a5d1));
    await tester.pumpWidget(
      MaterialApp(
        home: ChatMessenger(
          client: client,
          initialConversationId: 'conv_test',
          theme: ChatTheme.light(brandColor: Colors.purple),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(TextField))).brightness,
      Brightness.light,
    );
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('openChat shows close and dismisses the route', (tester) async {
    final client = await makeClient(configured());
    late BuildContext launcher;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            launcher = context;
            return const SizedBox();
          },
        ),
      ),
    );
    final opened = client.openChat(launcher, automaticReadReporting: false);
    await tester.pumpAndSettle();
    expect(find.byType(ChatMessenger), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await opened;
    expect(find.byType(ChatMessenger), findsNothing);
    await client.dispose();
  });

  group('Home', () {
    FakeTransport withConversations(List<Map<String, dynamic>> data) {
      final transport = FakeTransport();
      transport.handler = (call) async {
        final path = call.uri.path;
        // Help is covered by help_screen_test.dart.
        if (path.endsWith('/bootstrap')) {
          return ChatResponse(200, bootstrap(help: false));
        }
        if (path.endsWith('/conversations') && call.method == 'GET') {
          return ChatResponse(200, {
            'data': data,
            'hasMore': false,
            'nextCursor': null,
          });
        }
        return transport.respond(call);
      };
      return transport;
    }

    testWidgets('continues the active conversation and lists the recent one', (
      tester,
    ) async {
      final transport = withConversations([
        {...conversation(), 'subject': 'Where is my order?', 'unreadCount': 3},
        {
          ...conversation(),
          'id': 'conv_old',
          'subject': 'Billing question',
          'status': 'resolved',
        },
      ]);
      final client = await makeClient(transport);
      await tester.pumpWidget(host(client, section: ChatMessengerSection.home));
      await tester.pumpAndSettle();
      expect(find.text('Chat with us'), findsOneWidget);
      expect(
        find.text(
          'We’re here to help. Ask a question and our team will reply here.',
        ),
        findsOneWidget,
      );
      final active = find.byKey(const ValueKey('conv_test'));
      expect(
        find.descendant(
          of: active,
          matching: find.text('Continue conversation'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: active, matching: find.text('3')),
        findsOneWidget,
      );
      expect(find.text('Recent conversation'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('conv_old')),
          matching: find.text('Billing question'),
        ),
        findsOneWidget,
      );

      await tester.tap(active);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byTooltip('Send'), findsOneWidget);
      await tester.tap(find.byTooltip('Conversations'));
      await tester.pumpAndSettle();
      expect(find.text('Chat with us'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });

    testWidgets('starts a conversation when none is active', (tester) async {
      final transport = withConversations([
        {...conversation(), 'id': 'conv_done', 'status': 'closed'},
      ]);
      final client = await makeClient(transport);
      await tester.pumpWidget(host(client, section: ChatMessengerSection.home));
      await tester.pumpAndSettle();
      expect(find.text('Send us a message'), findsOneWidget);
      expect(find.text('Our team will reply here'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-start')));
      await tester.pumpAndSettle();
      expect(
        transport.calls.where(
          (c) => c.method == 'POST' && c.uri.path.endsWith('/conversations'),
        ),
        hasLength(1),
      );
      expect(find.byTooltip('Send'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });

    testWidgets('configured links need a host opener', (tester) async {
      final transport = withConversations([]);
      final client = await makeClient(transport);
      await tester.pumpWidget(host(client, section: ChatMessengerSection.home));
      await tester.pumpAndSettle();
      expect(find.text('Helpful links'), findsNothing);
      expect(find.text('Status'), findsNothing);

      final opened = <Uri>[];
      await tester.pumpWidget(
        host(
          client,
          section: ChatMessengerSection.home,
          onOpenLink: (url) async => opened.add(url),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Helpful links'), findsOneWidget);
      // Only the HTTPS link without credentials survives configuration parsing.
      expect(find.text('Unsafe'), findsNothing);
      await tester.tap(find.text('Status'));
      expect(opened, [Uri.parse('https://status.example.test')]);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });

    testWidgets('tabs switch sections and Messages shows the unread total', (
      tester,
    ) async {
      final transport = withConversations([conversation()]);
      final client = await makeClient(transport);
      await tester.pumpWidget(host(client, section: ChatMessengerSection.home));
      await tester.pumpAndSettle();
      final badge = find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byType(Badge),
      );
      expect(badge, findsWidgets);
      expect(
        find.descendant(of: badge.first, matching: find.text('2')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Messages'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your conversations'), findsOneWidget);
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(find.text('Chat with us'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });
  });
}
