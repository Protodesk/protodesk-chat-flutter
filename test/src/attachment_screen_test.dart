import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/fake_transport.dart';
import 'attachments_test.dart' as fixtures;
import 'attachment_persistence_test.dart' show PrivateFiles;
import 'persistence_test.dart' show SecureMemory;

void main() {
  testWidgets(
    'composer waits for validation, freezes lost-response retry, and shows attachment history',
    (tester) async {
      final transport = FakeTransport();
      final binary = fixtures.BinaryTransport()..barrier = Completer();
      var sends = 0;
      transport.handler = (call) async {
        if (call.uri.path.endsWith('/uploads')) {
          return ChatResponse(201, fixtures.capability());
        }
        if (call.uri.path.endsWith('/complete')) {
          return ChatResponse(200, fixtures.readyAttachment());
        }
        if (call.uri.path.endsWith('/messages') && call.method == 'POST') {
          if (++sends == 1) {
            throw const ProtodeskChatException(
              'chat.network_unavailable',
              retryable: true,
            );
          }
          return ChatResponse(201, {
            ...message(
              text: call.body!['body'] as String,
              clientId: call.body!['clientMessageId'] as String,
            ),
            'attachments': [fixtures.readyAttachment()],
          });
        }
        return transport.respond(call);
      };
      final client = await initializeChat(
        ChatClientOptions(
          publicChatAppId: appId,
          baseUrl: Uri.parse('https://api.example.test'),
          transport: transport,
          attachmentTransport: binary,
          attachmentStorageOrigins: {Uri.parse('https://storage.example.test')},
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            client: client,
            attachmentPicker: () async => fixtures.source(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      transport.sockets.single.emit('realtime.ready', {'cursor': 'boundary'});
      await tester.pumpAndSettle();
      expect(client.connectionState, ChatConnectionState.connected);
      await tester.tap(find.byKey(const ValueKey('conv_test')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'With a file');
      await tester.tap(find.byTooltip('Attach file'));
      await tester.pump();
      await tester.pump();
      expect(find.text('note.txt'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip('Send'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      binary.barrier!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Ready'), findsOneWidget);
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      expect(find.text('Discard attachment draft'), findsOneWidget);
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      final posts = transport.calls
          .where((c) => c.method == 'POST' && c.uri.path.endsWith('/messages'))
          .toList();
      expect(posts, hasLength(2));
      expect(posts[0].body, posts[1].body);
      expect(posts[1].body!['attachmentIds'], ['att_1']);
      expect(find.text('note.txt (3 bytes)'), findsOneWidget);
      expect(client.attachments.uploads, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );
  testWidgets('late picker result after logout cannot initiate upload', (
    tester,
  ) async {
    final transport = FakeTransport();
    final client = await makeClient(transport);
    final picker = Completer<ChatAttachmentSource?>();
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(client: client, attachmentPicker: () => picker.future),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conv_test')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Attach file'));
    await tester.pump();
    await client.logout();
    await tester.pumpAndSettle();
    picker.complete(fixtures.source());
    await tester.pumpAndSettle();
    expect(
      transport.calls.where((c) => c.uri.path.endsWith('/uploads')),
      isEmpty,
    );
    expect(find.text('note.txt'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });
  testWidgets('downloaded image preview closes and clears on logout', (
    tester,
  ) async {
    final transport = FakeTransport();
    final binary = fixtures.BinaryTransport();
    final attachment = {
      ...fixtures.readyAttachment(),
      'contentType': 'image/png',
      'filename': 'image.png',
    };
    transport.handler = (call) async {
      if (call.uri.path.endsWith('/download')) {
        return ChatResponse(200, fixtures.capability());
      }
      if (call.method == 'GET' && call.uri.path.endsWith('/messages')) {
        return ChatResponse(200, {
          'data': [
            {
              ...message(),
              'attachments': [attachment],
            },
          ],
          'hasMore': false,
        });
      }
      return transport.respond(call);
    };
    final client = await initializeChat(
      ChatClientOptions(
        publicChatAppId: appId,
        baseUrl: Uri.parse('https://api.example.test'),
        transport: transport,
        attachmentTransport: binary,
        attachmentStorageOrigins: {Uri.parse('https://storage.example.test')},
      ),
    );
    await tester.pumpWidget(MaterialApp(home: ChatScreen(client: client)));
    await tester.pumpAndSettle();
    transport.sockets.single.emit('realtime.ready', {'cursor': 'boundary'});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conv_test')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('image.png (3 bytes)'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await client.logout();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('image.png (3 bytes)'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.dispose();
  });
  testWidgets(
    'offline attachment selection survives screen disposal and process restart',
    (tester) async {
      final files = PrivateFiles(), storage = SecureMemory();
      final transports = <FakeTransport>[];
      Future<ProtodeskChatClient> start() {
        final transport = FakeTransport();
        transports.add(transport);
        return initializeChat(
          ChatClientOptions(
            publicChatAppId: appId,
            baseUrl: Uri.parse('https://api.example.test'),
            transport: transport,
            storage: storage,
            identityKey: 'account',
            identityTokenProvider: () async => 'token',
            attachmentPersistence:
                ChatAttachmentPersistencePolicy.managedPrivateCopy,
            attachmentFileStore: files,
            attachmentStorageOrigins: {
              Uri.parse('https://storage.example.test'),
            },
          ),
        );
      }

      var client = await start();
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            client: client,
            attachmentPicker: () async => fixtures.source(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('conv_test')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Attach file'));
      await tester.pumpAndSettle();
      expect(find.text('note.txt'), findsOneWidget);
      expect(find.text('Queued'), findsOneWidget);
      expect(files.files, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
      client = await start();
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            client: client,
            attachmentPicker: () async => fixtures.source(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('conv_test')));
      await tester.pumpAndSettle();
      expect(find.text('note.txt'), findsOneWidget);
      expect(
        transports
            .expand((t) => t.calls)
            .where((c) => c.uri.path.endsWith('/uploads')),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Remove attachment'));
      await tester.pumpAndSettle();
      expect(find.text('note.txt'), findsNothing);
      expect(files.files, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await client.dispose();
    },
  );
}
