import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart';
import 'attachments_test.dart' as fixtures;
import 'persistence_test.dart' show SecureMemory;

class PrivateFiles implements ChatAttachmentFileStore {
  final files = <String, Uint8List>{};
  bool available = true, failWrite = false, failDelete = false;
  Completer<void>? writeGate;
  bool writing = false;
  String key(String scope, String partition, String handle) =>
      '$scope/$partition/$handle';
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<void> write(String s, String p, String h, Uint8List bytes) async {
    writing = true;
    if (writeGate != null) await writeGate!.future;
    if (failWrite) throw StateError('private file failed');
    files[key(s, p, h)] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> read(String s, String p, String h) async {
    final bytes = files[key(s, p, h)];
    if (bytes == null) throw StateError('missing source');
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String s, String p, String h) async {
    if (failDelete) throw StateError('deletion failed');
    files.remove(key(s, p, h));
  }

  @override
  Future<void> retain(String s, String p, Set<String> handles) async {
    files.removeWhere(
      (key, _) =>
          key.startsWith('$s/') &&
          !handles.any((h) => key == this.key(s, p, h)),
    );
  }

  @override
  Future<void> purge(String s, String p) async {
    if (failDelete) throw StateError('deletion failed');
    files.removeWhere((k, _) => k.startsWith('$s/$p/'));
  }
}

class Journal {
  Map<String, dynamic>? record;
  bool fail = false;
  final files = PrivateFiles();
  AttachmentPersistence wiring() => AttachmentPersistence(
    files: files,
    scope: 's' * 64,
    partition: 'a' * 64,
    load: () async => record == null
        ? null
        : jsonDecode(jsonEncode(record)) as Map<String, dynamic>,
    save: (value) async {
      if (fail) throw StateError('journal unavailable');
      record = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    },
    remove: () async {
      record = null;
    },
  );
}

class Fixture {
  final Journal journal = Journal();
  final calls = <(String, String, Map<String, dynamic>?, String?)>[];
  final binary = RecoverableBinary();
  DateTime now = DateTime.now();
  int counter = 0;
  bool online = false,
      completeUnavailable = false,
      expired = false,
      loseSend = false;
  final sends = <String>[];
  ChatAttachments start() => ChatAttachments(
    persistence: journal.wiring(),
    now: () => now,
    available: () => online,
    operationId: () =>
        '00000000-0000-4000-a000-${(++counter).toString().padLeft(12, '0')}',
    storageOrigins: {Uri.parse('https://storage.example.test')},
    transport: binary,
    request: (m, p, b, k) async {
      calls.add((m, p, b, k));
      if (p.endsWith('/complete')) {
        if (completeUnavailable)
          throw const ProtodeskChatException(
            'chat.attachment_unavailable',
            retryable: true,
            retryAfter: Duration(seconds: 5),
          );
        if (expired || !binary.accepted)
          throw const ProtodeskChatException(
            'chat.attachment_invalid',
            status: 409,
          );
        return fixtures.readyAttachment();
      }
      if (m == 'DELETE') return {};
      expired = false;
      return {
        ...fixtures.capability(),
        'expiresAt': now.add(const Duration(minutes: 15)).toIso8601String(),
      };
    },
    send: (conversation, id, text, ids) async {
      sends.add(id);
      if (loseSend)
        throw const ProtodeskChatException(
          'chat.network_unavailable',
          retryable: true,
        );
      return ChatMessage.fromJson({
        ...message(text: text, clientId: id),
        'attachments': [fixtures.readyAttachment()],
      });
    },
  );
}

class RecoverableBinary implements ChatAttachmentTransport {
  int puts = 0;
  bool accepted = false, loseResponse = false;
  @override
  Future<void> upload(
    Uri u,
    String type,
    Uint8List bytes,
    ChatTransferCancellation cancel,
    void Function(int) progress,
  ) async {
    cancel.check();
    puts++;
    accepted = true;
    progress(bytes.length);
    if (loseResponse)
      throw const ProtodeskChatException(
        'sdk.attachment_transfer_failed',
        retryable: true,
      );
  }

  @override
  Future<Uint8List> download(
    Uri u,
    int maxBytes,
    ChatTransferCancellation cancel,
  ) async => Uint8List.fromList([65, 66, 67]);
}

Future<void> ready(ChatAttachments manager) async =>
    until(() => manager.uploads.every((u) => u.state == ChatUploadState.ready));
void main() {
  test('private copy and journal precede mutations; restart restores ordered conversation selection', () async {
    final f = Fixture();
    var manager = f.start();
    await manager.restore();
    final first = await manager.uploadDurably('conv_one', fixtures.source());
    final second = await manager.uploadDurably('conv_two', fixtures.source());
    expect(f.calls, isEmpty);
    expect(f.journal.files.files.length, 2);
    final saved = jsonEncode(f.journal.record);
    expect(saved, isNot(contains('https://')));
    expect(saved, isNot(contains('Content-Type')));
    expect(saved, isNot(contains('Authorization')));
    expect(saved, isNot(contains('capability')));
    expect(saved, isNot(contains('QUJD')));
    await manager.close();
    manager = f.start();
    await manager.restore();
    expect(manager.uploads.map((u) => u.id), [first.id, second.id]);
    expect(manager.pendingUploads('conv_one').single.id, first.id);
    expect(f.calls, isEmpty);
    f.online = true;
    manager.setActive(true);
    await ready(manager);
    expect(f.binary.puts, 2);
    expect(f.journal.files.files, isEmpty);
    expect(
      f.calls
          .where((c) => c.$2.endsWith('/uploads'))
          .map((c) => c.$3!['conversationId']),
      ['conv_one', 'conv_two'],
    );
    expect(
      saved,
      isNot(contains(f.calls.first.$4!)),
    ); // derived raw retry key absent
    await manager.close();
  });
  test(
    'ambiguous PUT recovery completes before repeating binary upload',
    () async {
      final f = Fixture()..online = true;
      f.binary.loseResponse = true;
      var manager = f.start();
      await manager.restore();
      manager.setActive(true);
      final upload = await manager.uploadDurably(
        'conv_test',
        fixtures.source(),
      );
      await upload.settled;
      expect(upload.state, ChatUploadState.retryWait);
      await manager.close();
      f.now = f.now.add(const Duration(minutes: 1));
      manager = f.start();
      await manager.restore();
      manager.setActive(true);
      await ready(manager);
      expect(f.binary.puts, 1);
      expect(manager.uploads.single.id, upload.id);
      expect(f.calls.last.$2, endsWith('/complete'));
      await manager.close();
    },
  );
  test('expired remote generation rotates key, retains local id and source ordering', () async {
    final f = Fixture()..online = true;
    f.binary.loseResponse = true;
    var manager = f.start();
    await manager.restore();
    manager.setActive(true);
    final upload = await manager.uploadDurably('conv_test', fixtures.source());
    await upload.settled;
    final oldKey = f.calls.first.$4;
    await manager.close();
    f.now = f.now.add(const Duration(minutes: 16));
    f.expired = true;
    f.binary.loseResponse = false;
    manager = f.start();
    await manager.restore();
    manager.setActive(true);
    await ready(manager);
    final inits = f.calls.where((c) => c.$2.endsWith('/uploads')).toList();
    expect(inits, hasLength(2));
    expect(inits.last.$4, isNot(oldKey));
    expect(manager.uploads.single.id, upload.id);
    expect(f.binary.puts, 2);
    await manager.close();
  });
  test(
    'missing or changed private body fails closed, never mutates the server',
    () async {
      for (final corrupt in [false, true]) {
        final f = Fixture();
        var manager = f.start();
        await manager.restore();
        await manager.uploadDurably('conv_test', fixtures.source());
        await manager.close();
        if (corrupt) {
          f.journal.files.files.updateAll(
            (k, v) => Uint8List.fromList([1, 2, 3]),
          );
        } else {
          f.journal.files.files.clear();
        }
        manager = f.start();
        await manager.restore();
        f.online = true;
        manager.setActive(true);
        expect(
          manager.uploads.single.error!.code,
          'sdk.attachment_source_unavailable',
        );
        expect(f.calls, isEmpty);
        await manager.close();
      }
    },
  );
  test(
    'file or journal write failure rejects enqueue before any server request',
    () async {
      for (final fileFailure in [false, true]) {
        final f = Fixture()..online = true;
        final manager = f.start();
        await manager.restore();
        manager.setActive(true);
        if (fileFailure) {
          f.journal.files.failWrite = true;
        } else {
          f.journal.fail = true;
        }
        await expectLater(
          manager.uploadDurably('conv_test', fixtures.source()),
          throwsA(isA<ProtodeskChatException>()),
        );
        expect(f.calls, isEmpty);
        expect(f.journal.files.files, isEmpty);
        await manager.close();
      }
    },
  );
  test(
    'purge races private copy without leaking bodies or server mutations',
    () async {
      final f = Fixture();
      final manager = f.start();
      await manager.restore();
      f.journal.files.writeGate = Completer();
      final pending = manager.uploadDurably('conv_test', fixtures.source());
      final failed = expectLater(
        pending,
        throwsA(isA<ProtodeskChatException>()),
      );
      await until(() => f.journal.files.writing);
      final purge = manager.purge();
      f.journal.files.writeGate!.complete();
      await purge;
      await failed;
      expect(f.journal.files.files, isEmpty);
      expect(f.journal.record, isNull);
      expect(f.calls, isEmpty);
      await manager.close();
    },
  );
  test('retention and orphan cleanup run at recovery, unavailable adapter refuses opt-in', () async {
    final f = Fixture();
    var manager = f.start();
    await manager.restore();
    await manager.uploadDurably('conv_test', fixtures.source());
    await manager.close();
    f.journal.files.files['${'s' * 64}/${'b' * 64}/orphan'] = Uint8List(1);
    f.now = f.now.add(const Duration(hours: 25));
    manager = f.start();
    await manager.restore();
    expect(manager.uploads, isEmpty);
    expect(f.journal.files.files, isEmpty);
    await manager.close();
    f.journal.files.available = false;
    manager = f.start();
    await expectLater(
      manager.restore(),
      throwsA(isA<ProtodeskChatException>()),
    );
    await manager.close();
  });
  test('attachment message retry survives restart without another PUT or changed message ID', () async {
    final f = Fixture()..online = true;
    var manager = f.start();
    await manager.restore();
    manager.setActive(true);
    final upload = await manager.uploadDurably('conv_test', fixtures.source());
    await upload.settled;
    f.loseSend = true;
    await expectLater(
      manager.send('conv_test', 'Original caption', [upload]),
      throwsA(isA<ProtodeskChatException>()),
    );
    final id = f.sends.single;
    expect(manager.pendingDrafts.single.text, 'Original caption');
    await manager.close();
    manager = f.start();
    await manager.restore();
    manager.setActive(true);
    expect(manager.uploads.single.state, ChatUploadState.ready);
    expect(f.binary.puts, 1);
    await expectLater(
      manager.send('conv_test', 'Changed caption', manager.uploads),
      throwsA(isA<ProtodeskChatException>()),
    );
    f.loseSend = false;
    await manager.send('conv_test', 'Original caption', manager.uploads);
    expect(f.sends, [id, id]);
    expect(manager.uploads, isEmpty);
    expect(manager.pendingDrafts, isEmpty);
    await manager.close();
  });
  test('bounded automatic completion retries retain retry guidance and require explicit retry after six attempts', () async {
    final f = Fixture()
      ..online = true
      ..completeUnavailable = true;
    final manager = f.start();
    await manager.restore();
    manager.setActive(true);
    final upload = await manager.uploadDurably('conv_test', fixtures.source());
    await upload.settled;
    for (var attempt = 1; attempt < 6; attempt++) {
      expect(
        upload.retryAt!.difference(f.now),
        greaterThanOrEqualTo(const Duration(seconds: 5)),
      );
      f.now = f.now.add(const Duration(minutes: 1));
      manager.setActive(true);
      await upload.settled;
    }
    expect(upload.attempt, 6);
    expect(upload.state, ChatUploadState.failed);
    expect(f.binary.puts, 1);
    f.completeUnavailable = false;
    await manager.retry(upload);
    await ready(manager);
    await manager.close();
  });
  test('client dispose restores same identity; logout and account switch purge protected partition', () async {
    final storage = SecureMemory(), files = PrivateFiles();
    Future<ProtodeskChatClient> start() => initializeChat(
      ChatClientOptions(
        publicChatAppId: appId,
        baseUrl: Uri.parse('https://api.example.test'),
        transport: FakeTransport(),
        storage: storage,
        identityKey: 'account-a',
        identityTokenProvider: () async => 'token',
        attachmentPersistence:
            ChatAttachmentPersistencePolicy.managedPrivateCopy,
        attachmentFileStore: files,
        attachmentStorageOrigins: {Uri.parse('https://storage.example.test')},
      ),
    );
    var client = await start();
    final item = await client.attachments.uploadDurably(
      'conv_test',
      fixtures.source(),
    );
    await client.dispose();
    client = await start();
    expect(client.attachments.uploads.single.id, item.id);
    await client.identify(() async => 'other-token', identityKey: 'account-b');
    expect(client.attachments.uploads, isEmpty);
    expect(files.files, isEmpty);
    await client.attachments.uploadDurably('conv_test', fixtures.source());
    await client.logout();
    expect(files.files, isEmpty);
    expect(
      storage.values.keys.where((k) => k.endsWith('.attachments')),
      isEmpty,
    );
    await client.dispose();
  });
  test('restart cannot reset a pre-request sixth-attempt marker', () async {
    final f = Fixture();
    var manager = f.start();
    await manager.restore();
    await manager.uploadDurably('conv_test', fixtures.source());
    await manager.close();
    f.journal.record!['items'][0]['attempts'] = 6;
    f.journal.record!['items'][0]['state'] = 'retryWait';
    manager = f.start();
    await manager.restore();
    f.online = true;
    manager.setActive(true);
    expect(manager.uploads.single.state, ChatUploadState.failed);
    expect(
      manager.uploads.single.error!.code,
      'sdk.attachment_retry_exhausted',
    );
    expect(f.calls, isEmpty);
    await manager.retry(manager.uploads.single);
    await ready(manager);
    await manager.close();
  });
  test(
    'replacement recovery accepts only the original bytes and metadata',
    () async {
      final f = Fixture();
      var manager = f.start();
      await manager.restore();
      final original = await manager.uploadDurably(
        'conv_test',
        fixtures.source(),
      );
      await manager.close();
      f.journal.files.files.clear();
      manager = f.start();
      await manager.restore();
      final item = manager.uploads.single;
      await expectLater(
        manager.replaceSource(
          item,
          ChatAttachmentSource(
            filename: 'note.txt',
            contentType: 'text/plain',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ),
        throwsA(isA<ProtodeskChatException>()),
      );
      await manager.replaceSource(item, fixtures.source());
      expect(item.id, original.id);
      f.online = true;
      manager.setActive(true);
      await ready(manager);
      await manager.close();
    },
  );
  test('blocked journal prevents POST and explicit storage retry restores progress', () async {
    final f = Fixture();
    final manager = f.start();
    await manager.restore();
    final item = await manager.uploadDurably('conv_test', fixtures.source());
    f.journal.fail = true;
    f.online = true;
    manager.setActive(true);
    await item.settled;
    expect(manager.storageBlocked, isTrue);
    expect(f.calls, isEmpty);
    f.journal.fail = false;
    await manager.retryPersistence();
    await ready(manager);
    expect(manager.storageBlocked, isFalse);
    await manager.close();
  });
  test(
    'new identity journal epoch rejects old files after credential loss',
    () async {
      final files = PrivateFiles(), storage = SecureMemory();
      Future<ProtodeskChatClient> start() => initializeChat(
        ChatClientOptions(
          publicChatAppId: appId,
          baseUrl: Uri.parse('https://api.example.test'),
          transport: FakeTransport(),
          storage: storage,
          identityKey: 'account',
          identityTokenProvider: () async => 'token',
          attachmentPersistence:
              ChatAttachmentPersistencePolicy.managedPrivateCopy,
          attachmentFileStore: files,
          attachmentStorageOrigins: {Uri.parse('https://storage.example.test')},
        ),
      );
      var client = await start();
      await client.attachments.uploadDurably('conv_test', fixtures.source());
      await client.dispose();
      storage.values.removeWhere((k, v) => !k.endsWith('.attachments'));
      client = await start();
      expect(client.attachments.uploads, isEmpty);
      expect(files.files, isEmpty);
      await client.dispose();
    },
  );
  test('concurrent staging reserves capacity and corrupt metadata never starts a request', () async {
    final f = Fixture();
    var manager = f.start();
    await manager.restore();
    f.journal.files.writeGate = Completer();
    final tasks = List.generate(
      10,
      (_) => manager.uploadDurably('conv_test', fixtures.source()),
    );
    await expectLater(
      manager.uploadDurably('conv_test', fixtures.source()),
      throwsA(isA<ProtodeskChatException>()),
    );
    f.journal.files.writeGate!.complete();
    await Future.wait(tasks);
    await manager.close();
    f.journal.record!['items'][0]['sizeBytes'] = 17 * 1024 * 1024;
    manager = f.start();
    await expectLater(
      manager.restore(),
      throwsA(isA<ProtodeskChatException>()),
    );
    expect(f.calls, isEmpty);
    await manager.close();
  });
  test(
    'ready file deletion failure blocks sends until cleanup retry succeeds',
    () async {
      final f = Fixture()..online = true;
      final manager = f.start();
      await manager.restore();
      manager.setActive(true);
      f.journal.files.failDelete = true;
      final item = await manager.uploadDurably('conv_test', fixtures.source());
      await item.settled;
      expect(manager.storageBlocked, isTrue);
      expect(f.journal.files.files, isNotEmpty);
      await expectLater(
        manager.send('conv_test', 'caption', [item]),
        throwsA(isA<ProtodeskChatException>()),
      );
      f.journal.files.failDelete = false;
      await manager.retryPersistence();
      expect(item.state, ChatUploadState.ready);
      expect(f.journal.files.files, isEmpty);
      await manager.send('conv_test', 'caption', [item]);
      expect(f.sends, hasLength(1));
      await manager.close();
    },
  );
  test('temporarily unavailable native storage preserves recoverable journal and body', () async {
    final files = PrivateFiles(), storage = SecureMemory();
    Future<ProtodeskChatClient> start() => initializeChat(
      ChatClientOptions(
        publicChatAppId: appId,
        baseUrl: Uri.parse('https://api.example.test'),
        transport: FakeTransport(),
        storage: storage,
        identityKey: 'account',
        identityTokenProvider: () async => 'token',
        attachmentPersistence:
            ChatAttachmentPersistencePolicy.managedPrivateCopy,
        attachmentFileStore: files,
        attachmentStorageOrigins: {Uri.parse('https://storage.example.test')},
      ),
    );
    var client = await start();
    final item = await client.attachments.uploadDurably(
      'conv_test',
      fixtures.source(),
    );
    await client.dispose();
    files.available = false;
    await expectLater(start(), throwsA(isA<ProtodeskChatException>()));
    expect(files.files, hasLength(1));
    expect(
      storage.values.keys.where((k) => k.endsWith('.attachments')),
      hasLength(1),
    );
    files.available = true;
    client = await start();
    expect(client.attachments.uploads.single.id, item.id);
    await client.dispose();
  });
  test('failed discard deletion is surfaced and explicit cleanup removes the orphan', () async {
    final f = Fixture();
    final manager = f.start();
    await manager.restore();
    final item = await manager.uploadDurably('conv_test', fixtures.source());
    f.journal.files.failDelete = true;
    await expectLater(
      manager.cancel(item),
      throwsA(isA<ProtodeskChatException>()),
    );
    expect(manager.storageBlocked, isTrue);
    expect(f.journal.files.files, isNotEmpty);
    f.journal.files.failDelete = false;
    await manager.retryPersistence();
    expect(manager.storageBlocked, isFalse);
    expect(f.journal.files.files, isEmpty);
    await manager.close();
  });
}
