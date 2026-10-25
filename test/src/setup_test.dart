import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/bootstrap.dart';
import '../support/fake_transport.dart';

const form = {
  'enabled': true,
  'intro': 'Tell us a little about you.',
  'fields': [
    {'id': 'name', 'type': 'text', 'label': 'Name', 'required': true},
    {'id': 'email', 'type': 'email', 'label': 'Email', 'required': false},
    {
      'id': 'topic',
      'type': 'select',
      'label': 'Topic',
      'required': true,
      'options': ['Billing', 'Shipping'],
    },
    {
      'id': 'consent',
      'type': 'checkbox',
      'label': 'I agree to be contacted',
      'required': true,
    },
  ],
};

const routes = [
  {'id': 'sales', 'label': 'Buying Protodesk'},
  {'id': 'support', 'label': 'Using Protodesk'},
];

/// No conversations yet, a pre-chat form and routing choices.
FakeTransport setupTransport({
  bool reset = false,
  List<int> createFailures = const [],
  int deleteFailure = 0,
}) {
  final failures = [...createFailures];
  final transport = FakeTransport();
  transport.handler = (call) async {
    final path = call.uri.path;
    if (path.endsWith('/bootstrap')) {
      final body = bootstrap(
        help: false,
        preChatForm: form,
        widget: {'routingChoices': routes, 'greeting': ''},
      );
      if (reset) {
        (body['capabilities']
                as Map<String, dynamic>)['anonymousIdentityReset'] =
            true;
      }
      return ChatResponse(200, body);
    }
    if (path.endsWith('/conversations') && call.method == 'GET') {
      return const ChatResponse(200, {
        'data': [],
        'hasMore': false,
        'nextCursor': null,
      });
    }
    if (path.endsWith('/conversations') &&
        call.method == 'POST' &&
        failures.isNotEmpty) {
      failures.removeAt(0);
      return const ChatResponse(422, {
        'error': {'code': 'chat.pre_chat_invalid'},
      });
    }
    if (path.endsWith('/anonymous-identity') && deleteFailure > 0) {
      return ChatResponse(deleteFailure, const {
        'error': {'code': 'chat.dependency_unavailable'},
      });
    }
    return transport.respond(call);
  };
  return transport;
}

Iterable<Call> creates(FakeTransport transport) => transport.calls.where(
  (c) => c.method == 'POST' && c.uri.path.endsWith('/conversations'),
);

Future<ProtodeskChatClient> pumpHome(
  WidgetTester tester,
  FakeTransport transport, {
  Map<String, dynamic> preChat = const {},
  String? routingChoiceId,
}) async {
  await tester.binding.setSurfaceSize(const Size(400, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final client = await makeClient(transport);
  await tester.pumpWidget(
    MaterialApp(
      home: ChatMessenger(
        client: client,
        preChat: preChat,
        routingChoiceId: routingChoiceId,
        automaticReadReporting: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return client;
}

void main() {
  testWidgets('required setup validates before creating a conversation', (
    tester,
  ) async {
    final transport = setupTransport();
    final client = await pumpHome(tester, transport);
    await tester.tap(find.text('Send us a message'));
    await tester.pumpAndSettle();
    expect(find.text('Before we start'), findsOneWidget);
    expect(find.text('Tell us a little about you.'), findsOneWidget);
    expect(find.text('What can we help with?'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('This field is required.'), findsNWidgets(2));
    expect(find.text('Please check this box to continue.'), findsOneWidget);
    expect(find.text('Choose where you need help.'), findsOneWidget);
    expect(creates(transport), isEmpty);

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('pre-chat-email')),
        matching: find.byType(TextField),
      ),
      'not-an-email',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('valid setup sends values and opens the conversation', (
    tester,
  ) async {
    final transport = setupTransport();
    final client = await pumpHome(tester, transport);
    await tester.tap(find.text('Send us a message'));
    await tester.pumpAndSettle();
    Finder field(String id) => find.descendant(
      of: find.byKey(ValueKey('pre-chat-$id')),
      matching: find.byType(TextField),
    );
    await tester.enterText(field('name'), '  Ada  ');
    await tester.enterText(field('email'), 'ada@example.com');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shipping').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.textContaining('I agree to be contacted', findRichText: true),
    );
    await tester.tap(find.text('Using Protodesk'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(creates(transport).single.body, {
      'subject': '',
      'preChat': {
        'name': 'Ada',
        'email': 'ada@example.com',
        'topic': 'Shipping',
        'consent': true,
      },
      'routingChoiceId': 'support',
    });
    expect(find.byTooltip('Send'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('a stale form reloads configuration and asks again', (
    tester,
  ) async {
    final transport = setupTransport(createFailures: [422]);
    final client = await pumpHome(tester, transport);
    await tester.tap(find.text('Send us a message'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('pre-chat-name')),
        matching: find.byType(TextField),
      ),
      'Ada',
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Billing').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.textContaining('I agree to be contacted', findRichText: true),
    );
    await tester.tap(find.text('Buying Protodesk'));
    final bootstraps = transport.calls
        .where((c) => c.uri.path.endsWith('/bootstrap'))
        .length;
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      find.text('The form changed. Review the latest options and continue.'),
      findsOneWidget,
    );
    expect(
      transport.calls.where((c) => c.uri.path.endsWith('/bootstrap')).length,
      greaterThan(bootstraps),
    );
    expect(find.byTooltip('Send'), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  testWidgets('host-supplied setup values skip the form', (tester) async {
    final transport = setupTransport();
    final client = await pumpHome(
      tester,
      transport,
      preChat: {'name': 'Ada'},
      routingChoiceId: 'sales',
    );
    await tester.tap(find.text('Send us a message'));
    await tester.pumpAndSettle();
    expect(find.text('Before we start'), findsNothing);
    expect(creates(transport).single.body!['routingChoiceId'], 'sales');
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });

  group('Start over', () {
    Future<void> openThread(WidgetTester tester) async {
      await tester.tap(find.text('Send us a message'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('pre-chat-name')),
          matching: find.byType(TextField),
        ),
        'Ada',
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Billing').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.textContaining('I agree to be contacted', findRichText: true),
      );
      await tester.tap(find.text('Buying Protodesk'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }

    testWidgets('confirmed reset revokes and signs in as a new visitor', (
      tester,
    ) async {
      final transport = setupTransport(reset: true);
      final client = await pumpHome(tester, transport);
      await openThread(tester);
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start over'));
      await tester.pumpAndSettle();
      expect(find.text('Start over?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Start over'));
      await tester.pumpAndSettle();
      expect(
        transport.calls.where(
          (c) =>
              c.method == 'DELETE' &&
              c.uri.path.endsWith('/anonymous-identity'),
        ),
        hasLength(1),
      );
      expect(find.text('Start over?'), findsNothing);
      expect(client.state, ChatClientState.ready);
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });

    testWidgets('a failed reset keeps the identity and explains why', (
      tester,
    ) async {
      final transport = setupTransport(reset: true, deleteFailure: 503);
      final client = await pumpHome(tester, transport);
      await openThread(tester);
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start over'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Start over'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'We could not confirm the reset. Your chat identity has not been cleared.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(client.state, ChatClientState.ready);
      expect(find.byTooltip('Send'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });

    testWidgets('hidden without the reset capability', (tester) async {
      final client = await pumpHome(tester, setupTransport());
      await openThread(tester);
      expect(find.byTooltip('Chat options'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });
  });

  testWidgets(
    'the top edge of Home\'s card, drawn over the intro, is tappable',
    (tester) async {
      final transport = setupTransport();
      final client = await pumpHome(tester, transport);
      final card = tester.getRect(find.byKey(const ValueKey('home-start')));
      await tester.tapAt(card.topCenter + const Offset(0, 6));
      await tester.pumpAndSettle();
      expect(find.text('Before we start'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );
}
