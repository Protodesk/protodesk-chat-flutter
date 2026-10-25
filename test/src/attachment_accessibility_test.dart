import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/fake_transport.dart';
import 'attachments_test.dart' as fixtures;

final pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII=',
);

class ImageTransport extends fixtures.BinaryTransport {
  @override
  Future<Uint8List> download(
    Uri uri,
    int maxBytes,
    ChatTransferCancellation cancel,
  ) async => pixel;
}

void main() {
  testWidgets(
    'localized preview has named image, trapped focus and no reduced-motion transition',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final transport = FakeTransport();
      transport.messages.add({
        ...message(),
        'attachments': [
          {
            ...fixtures.readyAttachment(),
            'filename': 'foto.png',
            'contentType': 'image/png',
            'sizeBytes': pixel.length,
          },
        ],
      });
      transport.handler = (call) async => call.uri.path.endsWith('/download')
          ? ChatResponse(200, fixtures.capability())
          : transport.respond(call);
      final client = await initializeChat(
        ChatClientOptions(
          publicChatAppId: appId,
          baseUrl: Uri.parse('https://api.example.test'),
          transport: transport,
          attachmentTransport: ImageTransport(),
          attachmentStorageOrigins: {Uri.parse('https://storage.example.test')},
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('id'),
          localizationsDelegates: ChatLocalizations.localizationsDelegates,
          supportedLocales: ChatLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: ChatScreen(client: client, initialConversationId: 'conv_test'),
        ),
      );
      await tester.pumpAndSettle();
      transport.sockets.single.emit('realtime.ready', {'cursor': 'ready'});
      await tester.pumpAndSettle();
      await tester.tap(find.text('foto.png (${pixel.length} bita)'));
      await tester.pumpAndSettle();
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.semanticLabel, 'foto.png');
      expect(image.excludeFromSemantics, isFalse);
      final route = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.traversalEdgeBehavior, TraversalEdgeBehavior.closedLoop);
      expect(find.text('Tutup'), findsOneWidget);
      await tester.tap(find.text('Tutup'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
      semantics.dispose();
    },
  );
}
