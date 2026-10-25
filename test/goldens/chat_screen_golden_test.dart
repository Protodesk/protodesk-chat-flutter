// Baselines are macOS renders; other hosts skip them (see docs/testing.md).
@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/bootstrap.dart';
import '../support/fake_transport.dart';
import '../support/help_fixtures.dart';

// Fonts come from the pinned Flutter SDK, not a machine-specific absolute path.
Future<void> loadFonts() async {
  final configFile = File('.dart_tool/package_config.json').absolute;
  final config = jsonDecode(configFile.readAsStringSync()) as Map;
  final flutter = (config['packages'] as List).cast<Map>().singleWhere(
    (p) => p['name'] == 'flutter',
  );
  final root = configFile.uri
      .resolve('${flutter['rootUri']}/')
      .resolve('../../bin/cache/artifacts/material_fonts/');
  for (final entry in {
    'Roboto': ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf'],
    'MaterialIcons': ['MaterialIcons-Regular.otf'],
  }.entries) {
    final loader = FontLoader(entry.key);
    for (final file in entry.value) {
      loader.addFont(
        Future.value(
          ByteData.sublistView(
            File.fromUri(root.resolve(file)).readAsBytesSync(),
          ),
        ),
      );
    }
    await loader.load();
  }
}

void main() {
  for (final variant in [
    ('en_light_history', 'en', false, 1.0, const Size(390, 780), 'history'),
    ('id_dark_large_history', 'id', true, 2.0, const Size(390, 844), 'history'),
    ('en_light_empty_tablet', 'en', false, 1.0, const Size(900, 700), 'empty'),
    ('id_dark_offline_queue', 'id', true, 1.0, const Size(390, 780), 'queue'),
    ('en_light_messages', 'en', false, 1.0, const Size(390, 780), 'messages'),
    ('en_light_home', 'en', false, 1.0, const Size(390, 780), 'home'),
    ('id_dark_large_home', 'id', true, 2.0, const Size(390, 844), 'home'),
    ('en_light_help', 'en', false, 1.0, const Size(390, 844), 'help'),
    ('id_dark_help_article', 'id', true, 1.0, const Size(390, 844), 'article'),
    ('en_light_setup', 'en', false, 1.0, const Size(390, 844), 'setup'),
    ('en_light_home_tablet', 'en', false, 1.0, const Size(1024, 768), 'home'),
    ('id_dark_help_tablet', 'id', true, 1.0, const Size(1024, 768), 'help'),
  ]) {
    testWidgets('golden ${variant.$1}', (tester) async {
      await tester.runAsync(loadFonts);
      await tester.binding.setSurfaceSize(variant.$5);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final transport = FakeTransport();
      // Times render in local time: pin them to 09:41 local on every machine.
      final at = DateTime(2026, 10, 25, 9, 41).toUtc().toIso8601String();
      final listed = const {
        'messages',
        'home',
        'help',
        'article',
        'setup',
      }.contains(variant.$6);
      if (listed) {
        transport.handler = (call) async {
          final path = call.uri.path;
          final help = helpResponse(call);
          if (help != null) return help;
          if (path.endsWith('/bootstrap')) {
            return ChatResponse(
              200,
              bootstrap(
                appearance: {
                  'preferredColorScheme': variant.$3 ? 'dark' : 'light',
                  'logoUrl': null,
                },
                help: variant.$6 != 'setup',
                preChatForm: variant.$6 == 'setup'
                    ? {
                        'enabled': true,
                        'intro':
                            'Tell us a little about you so we can help faster.',
                        'fields': [
                          {
                            'id': 'name',
                            'type': 'text',
                            'label': 'Name',
                            'required': true,
                          },
                          {
                            'id': 'email',
                            'type': 'email',
                            'label': 'Email',
                            'required': false,
                            'placeholder': 'you@example.com',
                          },
                          {
                            'id': 'consent',
                            'type': 'checkbox',
                            'label':
                                'I agree to be contacted about this request',
                            'required': true,
                          },
                        ],
                      }
                    : null,
                widget: {
                  if (variant.$6 == 'setup')
                    'routingChoices': [
                      {'id': 'sales', 'label': 'Buying Protodesk'},
                      {'id': 'support', 'label': 'Using Protodesk'},
                    ],
                  if (variant.$2 == 'id') 'headerTitle': 'Hubungi kami',
                  'links': [
                    {
                      'label': 'Order status',
                      'url': 'https://status.example.test',
                    },
                  ],
                },
              ),
            );
          }
          if (path.endsWith('/conversations') &&
              call.method == 'GET' &&
              variant.$6 == 'setup') {
            return const ChatResponse(200, {
              'data': [],
              'hasMore': false,
              'nextCursor': null,
            });
          }
          if (path.endsWith('/conversations') && call.method == 'GET') {
            return ChatResponse(200, {
              'data': [
                {
                  ...conversation(),
                  'subject': 'Where is my order?',
                  'unreadCount': 2,
                  'updatedAt': '2026-10-21T08:00:00Z',
                },
                {
                  ...conversation(),
                  'id': 'conv_older',
                  'subject': 'Billing question',
                  'status': 'resolved',
                  'updatedAt': '2026-09-30T08:00:00Z',
                },
              ],
              'hasMore': false,
              'nextCursor': null,
            });
          }
          return transport.respond(call);
        };
      }
      if (variant.$6 == 'history')
        transport.messages.addAll([
          {
            ...message(
              id: 'msg_agent',
              text: variant.$2 == 'id'
                  ? 'Kami akan membantu Anda.'
                  : 'We can help with your order.',
            ),
            'sender': 'agent',
            'createdAt': at,
          },
          {
            ...message(
              id: 'msg_customer',
              text: variant.$2 == 'id'
                  ? 'Di mana pesanan saya?'
                  : 'Where is my order?',
            ),
            'createdAt': at,
          },
        ]);
      // English shows the optional contact form; Indonesian shows it not offered.
      if (variant.$1 == 'en_light_history')
        transport.contact = {
          'email': '',
          'dismissed': false,
          'canRequest': true,
        };
      final client = await makeClient(transport);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(variant.$2),
          localizationsDelegates: ChatLocalizations.localizationsDelegates,
          supportedLocales: ChatLocalizations.supportedLocales,
          theme: (variant.$3 ? ChatTheme.dark() : ChatTheme.light()).copyWith(
            platform: TargetPlatform.android,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(variant.$4),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: RepaintBoundary(
            key: key,
            child: ChatScreen(
              client: client,
              initialConversationId: listed ? null : 'conv_test',
              initialSection: switch (variant.$6) {
                'home' || 'setup' => ChatMessengerSection.home,
                'help' || 'article' => ChatMessengerSection.help,
                _ => ChatMessengerSection.messages,
              },
              onOpenLink: (_) async {},
              automaticReadReporting: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (variant.$6 == 'queue') {
        await client.disconnect();
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          'Pesan menunggu koneksi',
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Kirim'));
        await tester.pumpAndSettle();
      } else {
        transport.sockets.single.emit('realtime.ready', {'cursor': 'golden'});
        await tester.pumpAndSettle();
      }
      if (variant.$6 == 'queue')
        expect(find.text('Dalam antrean'), findsOneWidget);
      if (variant.$6 == 'setup') {
        await tester.tap(find.text('Send us a message'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();
      }
      if (variant.$6 == 'article') {
        await tester.tap(find.text('Lihat semua artikel'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('What is Protodesk?'));
        await tester.pumpAndSettle();
      }
      // Remove caret/focus from the snapshot; no clock, random IDs or network assets.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(key),
        matchesGoldenFile('${variant.$1}.png'),
      );
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    });
  }
}
