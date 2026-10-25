import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

ChatAttachmentSource source() => ChatAttachmentSource(
  filename: 'note.txt',
  contentType: 'text/plain',
  bytes: Uint8List.fromList([65, 66, 67]),
);
Map<String, dynamic> readyAttachment() => {
  'id': 'att_1',
  'filename': 'note.txt',
  'contentType': 'text/plain',
  'sizeBytes': 3,
  'status': 'ready',
};
Map<String, dynamic> capability() => {
  'uploadId': 'upload_1',
  'attachmentId': 'att_1',
  'method': 'PUT',
  'url': 'https://storage.example.test/object?secret=capability',
  'headers': {'Content-Type': 'text/plain'},
  'expiresAt': DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
};

class BinaryTransport implements ChatAttachmentTransport {
  int puts = 0;
  Completer<void>? barrier;
  ChatTransferCancellation? cancellation;
  @override
  Future<void> upload(
    Uri url,
    String contentType,
    Uint8List bytes,
    ChatTransferCancellation cancel,
    void Function(int) onProgress,
  ) async {
    puts++;
    cancellation = cancel;
    onProgress(1);
    if (barrier != null) await barrier!.future;
    cancel.check();
    onProgress(bytes.length);
  }

  @override
  Future<Uint8List> download(
    Uri url,
    int maxBytes,
    ChatTransferCancellation cancel,
  ) async {
    if (barrier != null) await barrier!.future;
    cancel.check();
    return Uint8List.fromList([65, 66, 67]);
  }
}

ChatAttachments manager(
  AttachmentRequest request,
  BinaryTransport binary, {
  bool Function()? available,
}) => ChatAttachments(
  request: request,
  available: available ?? () => true,
  operationId: () => 'operation',
  storageOrigins: {Uri.parse('https://storage.example.test')},
  transport: binary,
);
void main() {
  test(
    'conversation-bound progress and validation; ready release purges source',
    () async {
      final binary = BinaryTransport()..barrier = Completer();
      final calls = <(String, String, Map<String, dynamic>?, String?)>[];
      final completed = Completer<Map<String, dynamic>>();
      final uploads = manager((m, p, b, k) async {
        calls.add((m, p, b, k));
        return p.endsWith('/complete') ? completed.future : capability();
      }, binary);
      final upload = uploads.upload('conv_original', source());
      await Future<void>.delayed(Duration.zero);
      expect(upload.state, ChatUploadState.uploading);
      expect(upload.sentBytes, 1);
      expect(calls.single.$3!['conversationId'], 'conv_original');
      binary.barrier!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(upload.state, ChatUploadState.processing);
      expect(upload.attachment, isNull);
      completed.complete(readyAttachment());
      await upload.settled;
      expect(upload.state, ChatUploadState.ready);
      expect(upload.sentBytes, 3);
      expect(calls.last.$4, 'operation-complete');
      uploads.release(upload);
      expect(upload.source, isNull);
      expect(uploads.uploads, isEmpty);
      await uploads.close();
    },
  );
  test('completion retry preserves IDs without another PUT', () async {
    final binary = BinaryTransport();
    var attempts = 0;
    final keys = <String?>[];
    final uploads = manager((m, p, b, k) async {
      if (p.endsWith('/complete')) {
        keys.add(k);
        if (++attempts == 1)
          throw const ProtodeskChatException(
            'chat.attachment_unavailable',
            retryable: true,
          );
        return readyAttachment();
      }
      return capability();
    }, binary);
    final upload = uploads.upload('conv_1', source());
    await upload.settled;
    expect(upload.state, ChatUploadState.failed);
    await uploads.retry(upload);
    expect(upload.state, ChatUploadState.ready);
    expect(binary.puts, 1);
    expect(keys, ['operation-complete', 'operation-complete']);
    await uploads.close();
  });
  test('offline/concurrency bounds reject before mutations and purge fences late calls', () async {
    var online = false, calls = 0;
    final binary = BinaryTransport()..barrier = Completer();
    final uploads = manager(
      (m, p, b, k) async {
        calls++;
        return capability();
      },
      binary,
      available: () => online,
    );
    expect(
      () => uploads.upload('conv_1', source()),
      throwsA(isA<ProtodeskChatException>()),
    );
    expect(calls, 0);
    online = true;
    final items = List.generate(3, (_) => uploads.upload('conv_1', source()));
    expect(
      () => uploads.upload('conv_1', source()),
      throwsA(isA<ProtodeskChatException>()),
    );
    await Future<void>.delayed(Duration.zero);
    uploads.clear();
    binary.barrier!.complete();
    await Future.wait(items.map((u) => u.settled));
    expect(uploads.uploads, isEmpty);
    expect(
      items.every((u) => u.source == null && u.attachment == null),
      isTrue,
    );
    expect(calls, 3);
    await uploads.close();
  });
  test(
    'cancel during initiation cleans late remote upload, never PUTs',
    () async {
      final init = Completer<Map<String, dynamic>>();
      final binary = BinaryTransport();
      final deleted = <String>[];
      final uploads = manager((m, p, b, k) async {
        if (m == 'DELETE') {
          deleted.add(p);
          return {};
        }
        return init.future;
      }, binary);
      final upload = uploads.upload('conv_1', source());
      final cancel = uploads.cancel(upload);
      init.complete(capability());
      await cancel;
      expect(binary.puts, 0);
      expect(deleted, ['/v1/chat/attachments/uploads/upload_1']);
      expect(upload.state, ChatUploadState.canceled);
      expect(upload.source, isNull);
      await uploads.close();
    },
  );
  test(
    'suspension aborts and explicit retry uses the same initiation key',
    () async {
      final binary = BinaryTransport()..barrier = Completer();
      final keys = <String?>[];
      final uploads = manager((m, p, b, k) async {
        if (p.endsWith('/complete')) return readyAttachment();
        keys.add(k);
        return capability();
      }, binary);
      final upload = uploads.upload('conv_1', source());
      await Future<void>.delayed(Duration.zero);
      uploads.suspend();
      expect(binary.cancellation!.isCancelled, isTrue);
      binary.barrier!.complete();
      await upload.settled;
      expect(upload.error!.retryable, isTrue);
      expect(upload.error!.code, 'sdk.attachment_interrupted');
      binary.barrier = null;
      await uploads.retry(upload);
      expect(keys, ['operation', 'operation']);
      expect(upload.state, ChatUploadState.ready);
      await uploads.close();
    },
  );
  for (final change in <Map<String, dynamic>>[
    {'url': 'https://storage.example.test.attacker.test/object'},
    {'url': 'https://user:password@storage.example.test/object'},
    {'url': 'http://storage.example.test/object'},
    {
      'headers': {'Content-Type': 'text/plain', 'Authorization': 'secret'},
    },
    {'expiresAt': '2000-01-01T00:00:00Z'},
    {'method': 'POST'},
  ]) {
    test('reject unsafe capability $change', () async {
      final binary = BinaryTransport();
      final uploads = manager(
        (m, p, b, k) async => {...capability(), ...change},
        binary,
      );
      final upload = uploads.upload('conv_1', source());
      await upload.settled;
      expect(upload.error!.code, 'sdk.attachment_capability_invalid');
      expect(binary.puts, 0);
      await uploads.close();
    });
  }
  test('download result cannot escape identity purge', () async {
    final binary = BinaryTransport()..barrier = Completer();
    final uploads = manager((m, p, b, k) async => capability(), binary);
    final download = uploads.download(
      ChatAttachment.fromJson(readyAttachment()),
    );
    final assertion = expectLater(
      download,
      throwsA(isA<ProtodeskChatException>()),
    );
    await Future<void>.delayed(Duration.zero);
    uploads.clear();
    binary.barrier!.complete();
    await assertion;
    await uploads.close();
  });
  test('failed scan or mismatched completion never becomes sendable', () async {
    for (final result in [
      {...readyAttachment(), 'status': 'failed'},
      {...readyAttachment(), 'id': 'att_other'},
    ]) {
      final uploads = manager(
        (m, p, b, k) async => p.endsWith('/complete') ? result : capability(),
        BinaryTransport(),
      );
      final upload = uploads.upload('conv_1', source());
      await upload.settled;
      expect(upload.state, ChatUploadState.failed);
      expect(upload.attachment, isNull);
      expect(upload.error!.retryable, isFalse);
      await uploads.close();
    }
  });
  test(
    'ten retained bodies limit and explicit cancel frees capacity',
    () async {
      final uploads = manager(
        (m, p, b, k) async =>
            p.endsWith('/complete') ? readyAttachment() : capability(),
        BinaryTransport(),
      );
      for (var i = 0; i < 10; i++) {
        await uploads.upload('conv_1', source()).settled;
      }
      expect(
        () => uploads.upload('conv_1', source()),
        throwsA(isA<ProtodeskChatException>()),
      );
      await uploads.cancel(uploads.uploads.first);
      await uploads.upload('conv_1', source()).settled;
      expect(uploads.uploads.length, 10);
      await uploads.close();
    },
  );
  test('source owns immutable bytes and rejects unsupported metadata', () {
    final bytes = Uint8List.fromList([1]);
    final file = ChatAttachmentSource(
      filename: 'a.png',
      contentType: 'image/png',
      bytes: bytes,
    );
    bytes[0] = 2;
    expect(file.bytes.single, 1);
    expect(() => file.bytes[0] = 3, throwsUnsupportedError);
    expect(
      () => ChatAttachmentSource(
        filename: '../a.txt',
        contentType: 'text/plain',
        bytes: bytes,
      ),
      throwsA(isA<ProtodeskChatException>()),
    );
    expect(
      () => ChatAttachmentSource(
        filename: 'a.html',
        contentType: 'text/html',
        bytes: bytes,
      ),
      throwsA(isA<ProtodeskChatException>()),
    );
  });
  test('native PUT bytes/type/progress, no credentials; reject redirects and oversized reads', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final calls = <String>[];
    final subscription = server.listen((request) async {
      calls.add(request.uri.path);
      expect(request.headers.value('authorization'), isNull);
      expect(request.headers.value('cookie'), isNull);
      if (request.method == 'PUT') {
        expect(request.headers.contentType!.mimeType, 'text/plain');
        final received = await request.fold<List<int>>(
          [],
          (a, b) => a..addAll(b),
        );
        expect(received, [65, 66, 67]);
      } else if (request.uri.path == '/redirect') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/secret');
      } else {
        request.response.add([65, 66, 67, 68]);
      }
      await request.response.close();
    });
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final transport = NativeChatAttachmentTransport();
    final progress = <int>[];
    await transport.upload(
      base.resolve('/put'),
      'text/plain',
      source().bytes,
      ChatTransferCancellation(),
      progress.add,
    );
    expect(progress.last, 3);
    await expectLater(
      transport.download(
        base.resolve('/redirect'),
        3,
        ChatTransferCancellation(),
      ),
      throwsA(isA<ProtodeskChatException>()),
    );
    await expectLater(
      transport.download(base.resolve('/large'), 3, ChatTransferCancellation()),
      throwsA(
        isA<ProtodeskChatException>().having(
          (e) => e.code,
          'code',
          'sdk.attachment_response_too_large',
        ),
      ),
    );
    expect(calls, ['/put', '/redirect', '/large']);
    await subscription.cancel();
    await server.close(force: true);
  });
}
