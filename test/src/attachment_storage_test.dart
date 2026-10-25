import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('protodesk_chat/attachment_files');
  const store = PlatformChatAttachmentFileStore();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'native adapter exposes only opaque handles and bounded binary payloads',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'available') return true;
        if (call.method == 'read') return Uint8List.fromList([1, 2, 3]);
        return null;
      });
      expect(await store.isAvailable(), isTrue);
      await store.write(
        'a' * 64,
        'b' * 64,
        '00000000-0000-4000-a000-000000000001',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(
        await store.read(
          'a' * 64,
          'b' * 64,
          '00000000-0000-4000-a000-000000000001',
        ),
        [1, 2, 3],
      );
      expect(
        (calls[1].arguments as Map).keys,
        unorderedEquals(['scope', 'partition', 'handle', 'bytes']),
      );
      await store.retain('a' * 64, 'b' * 64, {});
      await store.purge('a' * 64, 'b' * 64);
    },
  );
  test('unavailable plugin never falls back and raw filesystem errors are redacted', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(
        code: 'denied',
        message: '/secret/path token=secret',
      ),
    );
    expect(await store.isAvailable(), isFalse);
    await expectLater(
      store.read('a' * 64, 'b' * 64, 'handle'),
      throwsA(
        isA<ProtodeskChatException>().having(
          (e) => e.toString(),
          'safe error',
          'ProtodeskChatException(sdk.attachment_persistence_unavailable)',
        ),
      ),
    );
  });
}
