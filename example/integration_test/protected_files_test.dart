import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

// Requires native file-protection metadata; current iOS Simulator lacks it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native managed files survive adapter recreation and purge', (
    tester,
  ) async {
    const store = PlatformChatAttachmentFileStore();
    final scope = DateTime.now().microsecondsSinceEpoch
        .toRadixString(16)
        .padLeft(64, '0');
    final partition = 'b' * 64;
    final handle = ProtodeskChatClient.newOperationId();
    expect(await store.isAvailable(), isTrue);
    try {
      await store.write(
        scope,
        partition,
        handle,
        Uint8List.fromList([1, 2, 3]),
      );
      expect(
        await const PlatformChatAttachmentFileStore().read(
          scope,
          partition,
          handle,
        ),
        [1, 2, 3],
      );
      await store.retain(scope, partition, {});
      await expectLater(
        store.read(scope, partition, handle),
        throwsA(isA<ProtodeskChatException>()),
      );
    } finally {
      await store.purge(scope, partition);
    }
  });
}
