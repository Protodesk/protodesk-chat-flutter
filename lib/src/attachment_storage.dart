import 'package:flutter/services.dart';

import 'models.dart';

enum ChatAttachmentPersistencePolicy { disabled, managedPrivateCopy }

/// Trusted adapter. Bodies must be protected at rest, private to this app, and
/// excluded from backup. Scope/partition/handle are opaque SDK-generated IDs.
/// Writes must atomically replace, flush, and survive process death. Missing or
/// unreadable files must throw; never substitute an empty body or plaintext store.
abstract interface class ChatAttachmentFileStore {
  Future<bool> isAvailable();
  Future<void> write(
    String scope,
    String partition,
    String handle,
    Uint8List bytes,
  );
  Future<Uint8List> read(String scope, String partition, String handle);
  Future<void> delete(String scope, String partition, String handle);

  /// Delete orphan files and other identity partitions within this app scope.
  Future<void> retain(String scope, String partition, Set<String> handles);
  Future<void> purge(String scope, String partition);
}

/// Android: AES-GCM with a non-exportable Keystore key in noBackupFilesDir.
/// iOS: complete file protection and explicit backup exclusion. No fallback.
final class PlatformChatAttachmentFileStore implements ChatAttachmentFileStore {
  const PlatformChatAttachmentFileStore();
  static const _channel = MethodChannel('protodesk_chat/attachment_files');
  Future<T?> _call<T>(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (_) {
      throw const ProtodeskChatException(
        'sdk.attachment_persistence_unavailable',
      );
    }
  }

  Map<String, Object?> _args(
    String scope,
    String partition, [
    String? handle,
  ]) => {'scope': scope, 'partition': partition, 'handle': ?handle};
  @override
  Future<bool> isAvailable() async {
    try {
      return await _call<bool>('available') == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> write(
    String scope,
    String partition,
    String handle,
    Uint8List bytes,
  ) => _call<void>('write', {
    ..._args(scope, partition, handle),
    'bytes': bytes,
  });
  @override
  Future<Uint8List> read(String scope, String partition, String handle) async {
    final bytes = await _call<Uint8List>(
      'read',
      _args(scope, partition, handle),
    );
    if (bytes == null || bytes.isEmpty || bytes.length > 16 * 1024 * 1024) {
      throw const ProtodeskChatException('sdk.attachment_source_unavailable');
    }
    return bytes;
  }

  @override
  Future<void> delete(String scope, String partition, String handle) =>
      _call<void>('delete', _args(scope, partition, handle));
  @override
  Future<void> retain(String scope, String partition, Set<String> handles) =>
      _call<void>('retain', {
        ..._args(scope, partition),
        'handles': handles.toList(),
      });
  @override
  Future<void> purge(String scope, String partition) =>
      _call<void>('purge', _args(scope, partition));
}
