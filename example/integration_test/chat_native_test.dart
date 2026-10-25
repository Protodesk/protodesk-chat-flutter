import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';
import '../../test/support/fake_transport.dart';

// Network is a deterministic protocol fixture; Keychain/Keystore storage is real.
class TrackedStorage implements ChatStorageAdapter {
  final keys = <String>{};
  final delegate = const PlatformChatStorage();
  @override
  bool get isPlatformSecure => true;
  @override
  Future<String?> read(String key) {
    keys.add(key);
    return delegate.read(key);
  }

  @override
  Future<void> write(String key, String value) {
    keys.add(key);
    return delegate.write(key, value);
  }

  @override
  Future<void> delete(String key) => delegate.delete(key);
  Future<void> clean() async {
    for (final key in keys) {
      await delegate.delete(key);
    }
  }
}

// Test-only dependency isolation: managed attachment persistence is disabled.
// File protection is exercised separately in protected_files_test.dart on hardware.
class DisabledAttachmentFiles implements ChatAttachmentFileStore {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<void> purge(String scope, String partition) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected attachment operation');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native secure outbox restores account A and stays isolated from B',
    (tester) async {
      expect(Platform.isIOS || Platform.isAndroid, isTrue);
      final storage = TrackedStorage();
      final clients = <ProtodeskChatClient>[];
      final run = DateTime.now().microsecondsSinceEpoch;
      Future<ProtodeskChatClient> start(
        String account,
        FakeTransport transport,
      ) async {
        final client = await initializeChat(
          ChatClientOptions(
            publicChatAppId: 'chat_test_native$run',
            baseUrl: Uri.parse('https://fixture.example.test'),
            platform: Platform.isIOS ? 'ios' : 'android',
            transport: transport,
            storage: storage,
            attachmentFileStore: DisabledAttachmentFiles(),
            persistSendQueue: true,
            identityKey: account,
            identityTokenProvider: () async => 'fixture-identity-$account',
          ),
        );
        clients.add(client);
        return client;
      }

      try {
        var client = await start('account-a', FakeTransport());
        await tester.pumpWidget(
          MaterialApp(
            home: ChatScreen(
              client: client,
              initialConversationId: 'conv_test',
            ),
          ),
        );
        await tester.pumpAndSettle();
        await client.disconnect();
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          'Durable account A message',
        );
        await tester.tap(find.text('Send'));
        await tester.pumpAndSettle();
        expect(find.text('Queued'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await client.dispose();

        client = await start('account-b', FakeTransport());
        await tester.pumpWidget(
          MaterialApp(
            home: ChatScreen(
              client: client,
              initialConversationId: 'conv_test',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Durable account A message'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await client.logout();
        await client.dispose();

        final wire = FakeTransport();
        client = await start('account-a', wire);
        await tester.pumpWidget(
          MaterialApp(
            home: ChatScreen(
              client: client,
              initialConversationId: 'conv_test',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Durable account A message'), findsOneWidget);
        wire.sockets.single.emit('realtime.ready', {'cursor': 'native-ready'});
        for (var i = 0; i < 100 && wire.messages.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(wire.messages.single['body'], 'Durable account A message');
        expect(find.text('Queued'), findsNothing);
        await client.logout();
        await tester.pumpAndSettle();
        expect(find.text('Durable account A message'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        for (final client in clients) {
          await client.dispose();
        }
        await storage.clean();
      }
    },
  );
}
