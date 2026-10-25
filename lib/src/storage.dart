import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Implementations must atomically replace a single key, persist it before
/// write completes, and throw on inaccessible/corrupt storage. No plaintext or
/// silent-reset fallback. Use one client per origin/app in the foreground isolate.
abstract interface class ChatStorageAdapter {
  bool get isPlatformSecure;
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Device-local Keychain / Android Keystore-backed storage. The host must exclude
/// Android secure-storage files from backup and device transfer (see README).
/// No automatic Android reset-on-error: unreadable storage requires recovery.
final class PlatformChatStorage implements ChatStorageAdapter {
  const PlatformChatStorage();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: false,
      storageNamespace: 'protodesk_chat',
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
  );
  @override
  bool get isPlatformSecure => true;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
