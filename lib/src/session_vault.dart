import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'storage.dart';

/// Serializes atomic record writes. The lease is a coordination guard, not a
/// global identity. Background isolates must hand work to the owning client.
final class SessionVault {
  SessionVault(this.storage, String origin, String appId)
    : scope = sha256.convert(utf8.encode('$origin\n$appId')).toString() {
    if (!storage.isPlatformSecure) {
      throw const ProtodeskChatException('chat.secure_storage_required');
    }
    if (!_leases.add(scope)) {
      throw const ProtodeskChatException('chat.storage_in_use');
    }
  }
  final ChatStorageAdapter storage;
  final String scope;
  static final _leases = <String>{};
  Future<void> _tail = Future.value();
  bool _closed = false;
  String key(String? identityKey) =>
      'protodesk.chat.v1.$scope.${identityKey == null ? 'anonymous' : sha256.convert(utf8.encode('verified\n$identityKey'))}';

  Future<T> _run<T>(Future<T> Function() operation) {
    if (_closed) {
      return Future.error(
        const ProtodeskChatException('chat.operation_cancelled'),
      );
    }
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, dynamic>?> read(String key, void Function() check) =>
      _run(() async {
        check();
        String? raw;
        try {
          raw = await storage.read(key);
        } catch (_) {
          throw const ProtodeskChatException('chat.storage_unavailable');
        }
        check();
        if (raw == null) return null;
        try {
          final value = jsonDecode(raw) as Map<String, dynamic>;
          if (value['version'] != 1 || value['scope'] != key) {
            throw const FormatException();
          }
          return value;
        } catch (_) {
          throw const ProtodeskChatException('chat.storage_corrupt');
        }
      });
  Future<void> write(
    String key,
    Map<String, dynamic> value,
    void Function() check,
  ) {
    final encoded = jsonEncode({...value, 'version': 1, 'scope': key});
    return _run(() async {
      check();
      try {
        await storage.write(key, encoded);
        // A successful platform-channel return is insufficient if the host's
        // Keychain entitlement/configuration silently prevented persistence.
        if (await storage.read(key) != encoded) {
          throw const ProtodeskChatException('chat.storage_unavailable');
        }
      } catch (_) {
        throw const ProtodeskChatException('chat.storage_unavailable');
      }
      check();
    });
  }

  Future<void> delete(String key) => _run(() async {
    try {
      await storage.delete(key);
      if (await storage.read(key) != null) throw StateError('delete failed');
    } catch (_) {
      throw const ProtodeskChatException('chat.storage_unavailable');
    }
  });

  Future<void> close() async {
    _closed = true;
    await _tail;
    _leases.remove(scope);
  }
}
