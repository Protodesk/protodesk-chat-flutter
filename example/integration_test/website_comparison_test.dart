import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../../test/src/attachments_test.dart' as uploadFixture;
import '../../test/support/bootstrap.dart';
import '../../test/support/fake_transport.dart';

/// A native capture of the same published, read-only content as the browser.
/// The test never connects to a real customer session.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const raw = String.fromEnvironment('CHAT_COMPARISON_FIXTURE');
  testWidgets('Android website comparison and reopen', (tester) async {
    expect(Platform.isAndroid, isTrue);
    final input = jsonDecode(raw) as Map<String, dynamic>;
    final manifest = input['manifest'] as Map<String, dynamic>;
    final listing = input['listing'] as Map<String, dynamic>;
    final article = input['article'] as Map<String, dynamic>;
    final viewport = Size(
      (input['width'] as num).toDouble(),
      (input['height'] as num).toDouble(),
    );
    final codec = await ui.instantiateImageCodec(
      base64Decode(input['logo'] as String),
    );
    final logo = (await codec.getNextFrame()).image;
    codec.dispose();
    const url = 'https://fixture.example.test/logo.png';
    final imageKey = await const ResizeImage(
      NetworkImage(url),
      width: 108,
    ).obtainKey(ImageConfiguration.empty);
    PaintingBinding.instance.imageCache.putIfAbsent(
      imageKey,
      () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: logo))),
    );
    final threads = (input['threads'] as List).cast<Map<String, dynamic>>();
    var populated = false;
    var submitted = 0;
    final fullWindow = ValueNotifier(false);
    final transport = FakeTransport();
    transport.handler = (call) async {
      final path = call.uri.path;
      if (path.endsWith('/bootstrap')) {
        return ChatResponse(200, {
          ...bootstrap(
            appearance: {
              'primaryColor': input['color'],
              'preferredColorScheme': 'light',
              'logoUrl': url,
            },
            widget: {'links': []},
          ),
          'capabilities': {
            'attachments': true,
            'helpCenter': true,
            'typing': true,
            'anonymousIdentityReset': true,
          },
          'unreadCount': 0,
        });
      }
      if (path.endsWith('/help-center')) return ChatResponse(200, manifest);
      if (path.endsWith('/articles')) return ChatResponse(200, listing);
      if (path.endsWith('/${article['id']}')) return ChatResponse(200, article);
      if (path.endsWith('/uploads'))
        return ChatResponse(201, uploadFixture.capability());
      if (path.endsWith('/complete'))
        return ChatResponse(200, uploadFixture.readyAttachment());
      if (populated) {
        for (final thread in threads) {
          final conversation = thread['conversation'] as Map<String, dynamic>;
          final id = conversation['id'];
          if (path.endsWith('/$id')) return ChatResponse(200, conversation);
          if (path.endsWith('/$id/messages') && call.method == 'POST') {
            submitted++;
            return ChatResponse(201, {
              ...message(
                text: call.body!['body'] as String,
                clientId: call.body!['clientMessageId'] as String,
              ),
              'conversationId': id,
            });
          }
          if (path.endsWith('/$id/messages')) {
            return ChatResponse(200, {
              'data': thread['messages'],
              'hasMore': false,
            });
          }
          if (path.endsWith('/$id/read')) {
            return ChatResponse(200, {
              'conversationId': id,
              'throughMessageId': call.body?['throughMessageId'],
              'unreadCount': 0,
              'readAt': conversation['updatedAt'],
            });
          }
        }
        if (path.endsWith('/conversations')) {
          return ChatResponse(200, {
            'data': threads.map((t) => t['conversation']).toList(),
            'hasMore': false,
          });
        }
      }
      if (path.endsWith('/conversations') && call.method == 'GET')
        return const ChatResponse(200, {
          'data': [],
          'hasMore': false,
          'nextCursor': null,
        });
      return transport.respond(call);
    };
    final client = await initializeChat(
      ChatClientOptions(
        publicChatAppId: appId,
        baseUrl: Uri.parse('https://api.example.test'),
        transport: transport,
        attachmentTransport: uploadFixture.BinaryTransport(),
        attachmentStorageOrigins: {Uri.parse('https://storage.example.test')},
      ),
    );
    final region = GlobalKey();
    late BuildContext host;
    try {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: ChatLocalizations.localizationsDelegates,
          supportedLocales: ChatLocalizations.supportedLocales,
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: fullWindow,
            builder: (context, full, _) => SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox.fromSize(
                  size: full ? MediaQuery.sizeOf(context) : viewport,
                  child: RepaintBoundary(
                    key: region,
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        size: full ? MediaQuery.sizeOf(context) : viewport,
                        padding: EdgeInsets.zero,
                        viewPadding: EdgeInsets.zero,
                      ),
                      child: child!,
                    ),
                  ),
                ),
              ),
            ),
          ),
          home: Builder(
            builder: (context) {
              host = context;
              return const Scaffold();
            },
          ),
        ),
      );
      Future<void> open({String? thread, bool dark = false}) async {
        unawaited(
          client.openChat(
            host,
            initialConversationId: thread,
            theme: dark
                ? ChatTheme.dark(
                    brandColor: Color(
                      int.parse(
                        (input['color'] as String).replaceFirst('#', 'ff'),
                        radix: 16,
                      ),
                    ),
                  )
                : null,
            onOpenAttachment: (_, _) async {},
            attachmentPicker: () async => uploadFixture.source(),
            onOpenLink: (_) async {},
          ),
        );
        await tester.pumpAndSettle();
        transport.sockets.last.emit('realtime.ready', {'cursor': 'fixture'});
        await tester.pumpAndSettle();
      }

      Future<void> snap(String name) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final surface =
            region.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        expect(surface.size, viewport);
        final image = await surface.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        (binding.reportData ??= {})[name] = base64Encode(
          png!.buffer.asUint8List(),
        );
      }

      await open();
      await snap('chat');
      final inputField = find.byType(TextField);
      await tester.enterText(inputField, 'Unsent draft on Android');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await open();
      expect(
        tester.widget<TextField>(inputField).controller!.text,
        'Unsent draft on Android',
      );
      await tester.tap(find.byTooltip('Conversations'));
      await snap('messages');
      await tester.tap(find.text('Home'));
      await snap('home');
      await tester.tap(find.text('Help'));
      await snap('help');
      await tester.tap(find.text('Getting started').first);
      await snap('collection');
      await tester.tap(find.text(article['title'] as String).first);
      await snap('article');
      final title = find.text(article['title'] as String).last;
      final compactWidth = tester.getSize(title).width;
      await tester.tap(find.byTooltip('Expand article'));
      await tester.pumpAndSettle();
      expect(tester.getSize(title).width, greaterThan(compactWidth));
      await tester.tap(find.byTooltip('Restore article size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('On this page'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      unawaited(client.openHelpCenter(host));
      await tester.pumpAndSettle();
      expect(find.text(article['title'] as String), findsWidgets);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Getting started'), findsOneWidget);
      Future<void> close() async {
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
      }

      await close();
      populated = true;
      final plain = threads.first['conversation']['id'] as String;
      final file = threads.last['conversation']['id'] as String;
      await open(thread: plain);
      await snap('populated');
      fullWindow.value = true;
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      await tester.tap(field);
      for (var i = 0; i < 40 && tester.view.viewInsets.bottom == 0; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        tester.view.viewInsets.bottom,
        greaterThan(0),
        reason: 'The Android IME must be visible',
      );
      await tester.pump(const Duration(milliseconds: 500));
      debugPrint('CHAT_COMPARISON_KEYBOARD_VISIBLE');
      // Android can keep the IME open after submitting a multiline field.
      for (var i = 0; i < 100 && submitted == 0; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        submitted,
        1,
        reason: 'The keyboard must submit the fixture draft exactly once',
      );
      if (tester.view.viewInsets.bottom > 0) {
        FocusManager.instance.primaryFocus?.unfocus();
        for (var i = 0; i < 60 && tester.view.viewInsets.bottom > 0; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(tester.view.viewInsets.bottom, 0);
      }
      fullWindow.value = false;
      await tester.pumpAndSettle();
      await close();
      await open(thread: file);
      await snap('attachment');
      await tester.tap(find.byTooltip('Attach file'));
      await tester.pumpAndSettle();
      expect(find.text('note.txt'), findsOneWidget);
      await snap('staged');
      await tester.tap(find.byTooltip('Remove attachment'));
      await tester.pumpAndSettle();
      await close();
      // An explicit new presentation picks up the requested dark appearance.
      await open(thread: plain);
      await close();
      await open(thread: file, dark: true);
      await snap('dark');
    } finally {
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    }
  }, skip: raw.isEmpty);
}
