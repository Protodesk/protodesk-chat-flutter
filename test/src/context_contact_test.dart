import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/fake_transport.dart';

Matcher throwsCode(String code) =>
    throwsA(isA<ProtodeskChatException>().having((e) => e.code, 'code', code));

Iterable<Call> contactPosts(FakeTransport transport) => transport.calls.where(
  (c) => c.method == 'POST' && c.uri.path.endsWith('/contact'),
);

Future<ProtodeskChatClient> openThread(
  WidgetTester tester,
  FakeTransport transport, {
  Locale locale = const Locale('en'),
}) async {
  transport.messages.add(message(id: 'msg_customer', text: 'Where is it?'));
  final client = await makeClient(transport);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: ChatLocalizations.localizationsDelegates,
      supportedLocales: ChatLocalizations.supportedLocales,
      home: ChatScreen(client: client, automaticReadReporting: false),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('conv_test')));
  await tester.pumpAndSettle();
  return client;
}

void main() {
  group('conversation context', () {
    test('parses provenance, screen and scalar metadata', () {
      final verified = ChatConversationContext.parse({
        'provenance': 'external_object_verified',
        'screen': 'order_details',
        'metadata': {
          'plan': 'pro',
          'seats': 3,
          'nested': {'no': true},
        },
      });
      expect(verified.provenance, ChatContextProvenance.externalObjectVerified);
      expect(verified.provenance.isVerified, isTrue);
      expect(verified.screen, 'order_details');
      expect(verified.metadata, {'plan': 'pro', 'seats': 3});
      expect(() => verified.metadata['x'] = 1, throwsUnsupportedError);
    });

    test('unknown provenance and missing context are never verified', () {
      final future = ChatConversationContext.parse({
        'provenance': 'partner_verified',
        'screen': null,
        'metadata': {},
      });
      expect(future.provenance, ChatContextProvenance.unknown);
      expect(future.provenance.isVerified, isFalse);
      expect(future.isEmpty, isTrue);
      final legacy = ChatConversation.fromJson(
        Map.of(conversation())..remove('context'),
      );
      expect(legacy.context.provenance, ChatContextProvenance.clientUnverified);
      expect(legacy.context.isEmpty, isTrue);
    });

    test('create input mirrors server limits before any request', () {
      final valid = ChatCreateConversationContext(
        screen: '  checkout ',
        metadata: {'entryPoint': 'help_button', 'step': 2, 'gift': false},
      );
      expect(valid.toJson(), {
        'screen': 'checkout',
        'metadata': {'entryPoint': 'help_button', 'step': 2, 'gift': false},
      });
      for (final metadata in <Map<String, Object?>>[
        {'sessionToken': 'x'},
        {'api-key': 'x'},
        {'user.password': 'x'},
        {'bad key': 'x'},
        {'nested': <String, Object?>{}},
        {'list': <Object?>[]},
        {'long': 'x' * 1025},
        {for (var i = 0; i < 25; i++) 'k$i': i},
        {for (var i = 0; i < 5; i++) 'k$i': 'x' * 1000},
      ]) {
        expect(
          () => ChatCreateConversationContext(metadata: metadata),
          throwsCode('chat.context_invalid'),
          reason: '$metadata',
        );
      }
      expect(
        () => ChatCreateConversationContext(screen: 's' * 129),
        throwsCode('chat.context_invalid'),
      );
      expect(
        () => ChatExternalObjectReference(type: '', externalId: 'order_1'),
        throwsCode('chat.external_object_invalid'),
      );
    });

    test('create sends explicit context or the client default', () async {
      final transport = FakeTransport();
      final client = await makeClient(
        transport,
        initialContext: ChatCreateConversationContext(screen: 'home'),
      );
      final created = await client.createConversation(
        idempotencyKey: ProtodeskChatClient.newOperationId(),
      );
      expect(created.context.screen, 'order_details');
      expect(transport.calls.last.body!['context'], {
        'screen': 'home',
        'metadata': {},
      });
      await client.createConversation(
        idempotencyKey: ProtodeskChatClient.newOperationId(),
        context: ChatCreateConversationContext(metadata: {'orderStep': 3}),
        externalObject: ChatExternalObjectReference(
          type: 'order',
          externalId: 'order_123',
        ),
      );
      expect(transport.calls.last.body!['context'], {
        'metadata': {'orderStep': 3},
      });
      expect(transport.calls.last.body!['externalObject'], {
        'type': 'order',
        'externalId': 'order_123',
      });
      await client.dispose();
    });
  });

  group('contact client', () {
    test('reads, shares and dismisses with operation IDs', () async {
      final transport = FakeTransport();
      transport.contact = {'email': '', 'dismissed': false, 'canRequest': true};
      final client = await makeClient(transport);
      expect(client.identityKind, ChatIdentityKind.anonymous);
      final initial = await client.getContact('conv_test');
      expect(initial.canRequest, isTrue);
      expect(initial.hasEmail, isFalse);

      final id = ProtodeskChatClient.newOperationId();
      final shared = await client.shareContactEmail(
        conversationId: 'conv_test',
        email: '  ada@example.com ',
        operationId: id,
      );
      expect(shared.email, 'ada@example.com');
      expect(shared.canRequest, isFalse);
      final post = contactPosts(transport).single;
      expect(post.uri.path, '/v1/chat/conversations/conv_test/contact');
      expect(post.body, {'email': 'ada@example.com'});
      expect(post.headers['Idempotency-Key'], id);

      await client.dismissContactRequest(
        conversationId: 'conv_test',
        operationId: ProtodeskChatClient.newOperationId(),
      );
      expect(contactPosts(transport).last.body, {'dismissed': true});
      await client.dispose();
    });

    test('rejects invalid email locally and malformed responses', () async {
      final transport = FakeTransport();
      final client = await makeClient(transport);
      for (final email in ['', 'ada', 'ada@example', 'a b@example.com']) {
        expect(
          () => client.shareContactEmail(
            conversationId: 'conv_test',
            email: email,
            operationId: ProtodeskChatClient.newOperationId(),
          ),
          throwsCode('chat.contact_invalid'),
        );
      }
      expect(contactPosts(transport), isEmpty);
      transport.contact = {
        'email': '',
        'dismissed': false,
        'canRequest': true,
        'customerId': 'cust_secret',
      };
      await expectLater(
        client.getContact('conv_test'),
        throwsCode('chat.invalid_response'),
      );
      await client.dispose();
    });
  });

  group('screen', () {
    testWidgets(
      'keeps business context and provenance off the customer screen',
      (tester) async {
        final transport = FakeTransport();
        var provenance = 'client_unverified';
        transport.handler = (call) async {
          final response = transport.respond(call);
          if (!call.uri.path.endsWith('/conversations')) return response;
          return ChatResponse(200, {
            'data': [
              {
                ...conversation(),
                'context': {
                  'provenance': provenance,
                  'screen': 'orderDetails',
                  'metadata': {},
                },
              },
            ],
            'hasMore': false,
            'nextCursor': null,
          });
        };
        final client = await openThread(tester, transport);
        // Context is for the support team; customers never see provenance.
        expect(find.textContaining('Started from'), findsNothing);
        expect(find.textContaining('verified'), findsNothing);

        provenance = 'server_verified';
        await tester.tap(find.byTooltip('Conversations'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('conv_test')));
        await tester.pumpAndSettle();
        expect(find.textContaining('Verified'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await client.dispose();
      },
    );

    testWidgets('initial conversation loads context by ID', (tester) async {
      final transport = FakeTransport();
      final client = await makeClient(transport);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            client: client,
            initialConversationId: 'conv_test',
            automaticReadReporting: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        transport.calls.where(
          (c) => c.uri.path.endsWith('/v1/chat/conversations/conv_test'),
        ),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });

    testWidgets('prompt validates, shares and confirms', (tester) async {
      final transport = FakeTransport();
      transport.contact = {'email': '', 'dismissed': false, 'canRequest': true};
      final client = await openThread(tester, transport);
      expect(find.text('Stay in touch'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Email (optional)'),
        'nope',
      );
      await tester.tap(find.text('Share email'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(contactPosts(transport), isEmpty);

      await tester.enterText(
        find.widgetWithText(TextField, 'Email (optional)'),
        'ada@example.com',
      );
      await tester.pump();
      expect(find.text('Enter a valid email address.'), findsNothing);
      await tester.tap(find.text('Share email'));
      await tester.pumpAndSettle();
      expect(find.text('Email shared with support.'), findsOneWidget);
      expect(find.text('Stay in touch'), findsNothing);
      expect(contactPosts(transport).single.body, {'email': 'ada@example.com'});
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });

    testWidgets('uncertain saves retry with the same key; rejections rotate', (
      tester,
    ) async {
      final transport = FakeTransport();
      transport.contact = {'email': '', 'dismissed': false, 'canRequest': true};
      final failures = [503, 409];
      transport.handler = (call) async {
        if (call.method == 'POST' &&
            call.uri.path.endsWith('/contact') &&
            failures.isNotEmpty) {
          final status = failures.removeAt(0);
          return ChatResponse(status, {
            'error': {
              'code': status == 503
                  ? 'chat.dependency_unavailable'
                  : 'chat.conflict',
            },
          });
        }
        return transport.respond(call);
      };
      final client = await openThread(tester, transport);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not save your choice. Try again or keep chatting.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(
        find.text('No problem. You can keep chatting here.'),
        findsOneWidget,
      );

      final keys = [
        for (final post in contactPosts(transport))
          post.headers['Idempotency-Key'],
      ];
      expect(keys, hasLength(3));
      expect(keys[1], keys[0], reason: '503 is uncertain: reuse the key');
      expect(keys[2], isNot(keys[1]), reason: '409 is definitive: new key');
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });

    testWidgets('prompt stays hidden when unavailable or not requested', (
      tester,
    ) async {
      final transport = FakeTransport();
      transport.handler = (call) async => call.uri.path.endsWith('/contact')
          ? const ChatResponse(404, {
              'error': {'code': 'chat.conversation_not_found'},
            })
          : transport.respond(call);
      final client = await openThread(tester, transport);
      expect(find.text('Stay in touch'), findsNothing);
      expect(find.text('Contact options could not load.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();

      final quiet = FakeTransport();
      final second = await openThread(tester, quiet);
      expect(find.text('Stay in touch'), findsNothing);
      expect(contactPosts(quiet), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await second.dispose();
    });

    testWidgets('no request before a saved customer message', (tester) async {
      final transport = FakeTransport();
      final client = await makeClient(transport);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(client: client, automaticReadReporting: false),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('conv_test')));
      await tester.pumpAndSettle();
      expect(
        transport.calls.where((c) => c.uri.path.endsWith('/contact')),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });

    testWidgets('load failure offers a retry; Indonesian copy', (tester) async {
      final transport = FakeTransport();
      transport.contact = {'email': '', 'dismissed': false, 'canRequest': true};
      var fail = true;
      transport.handler = (call) async {
        if (call.uri.path.endsWith('/contact') && fail) {
          return const ChatResponse(503, {
            'error': {'code': 'chat.dependency_unavailable'},
          });
        }
        return transport.respond(call);
      };
      final client = await openThread(
        tester,
        transport,
        locale: const Locale('id'),
      );
      expect(find.text('Opsi kontak belum dapat dimuat.'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Muat ulang opsi kontak'));
      await tester.pumpAndSettle();
      expect(find.text('Tetap terhubung'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });
  });
}
