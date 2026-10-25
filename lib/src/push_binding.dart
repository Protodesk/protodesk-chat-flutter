import 'client.dart';
import 'models.dart';
import 'push.dart';

/// Serializes provider callbacks with one latest pending update. Identity-scoped.
/// Raw tokens exist only in memory until their operation completes or disposal.
final class ChatPushRegistrationBinding {
  ChatPushRegistrationBinding({
    required this.targets,
    required this.provider,
    required this.installationId,
    this.appVersion = '',
    this.locale = '',
  });
  final ChatPushTargets targets;
  final ChatPushProvider provider;
  final String installationId, appVersion, locale;
  _Update? _pending, _uncertain;
  Future<void>? _flight;
  bool _disposed = false;

  /// A null token with permission means the provider is not ready; it does not
  /// revoke. Permission/opt-in loss must pass permissionGranted:false.
  Future<void> update({String? token, required bool permissionGranted}) {
    if (_disposed) {
      return Future.error(
        const ProtodeskChatException('chat.operation_cancelled'),
      );
    }
    if (token != null && (token.isEmpty || token.length > 4096)) {
      return Future.error(
        const ProtodeskChatException('chat.push_target_invalid'),
      );
    }
    _pending = _Update(
      token,
      permissionGranted,
      ProtodeskChatClient.newOperationId(),
    );
    return _flight ??= _run().whenComplete(() => _flight = null);
  }

  Future<void> _register(_Update update) => targets
      .register(
        provider: provider,
        target: update.token!,
        installationId: installationId,
        permissionGranted: true,
        appVersion: appVersion,
        locale: locale,
        idempotencyKey: update.key,
      )
      .then((_) {});

  Future<void> _run() async {
    while (!_disposed && _pending != null) {
      // Recover an uncertain initial response before rotation or unregister so
      // the server target ID is known. A failure stops; no automatic retry loop.
      final uncertain = _uncertain;
      if (uncertain != null) {
        await _register(uncertain);
        _uncertain = null;
        if (_disposed) return;
      }
      final update = _pending!;
      _pending = null;
      if (!update.allowed) {
        await targets.unregister();
      } else if (update.token != null) {
        _uncertain = update;
        try {
          await _register(update);
          _uncertain = null;
        } on ProtodeskChatException catch (error) {
          // Definitive validation/policy rejections did not commit. Let a later
          // corrected token or opt-out proceed without replaying the rejection.
          final status = error.status;
          if (status != null &&
              status >= 400 &&
              status < 500 &&
              status != 408 &&
              status != 429) {
            _uncertain = null;
          }
          rethrow;
        }
      }
    }
  }

  /// Stops local callbacks; use client.logout for remote session revocation.
  Future<void> dispose() async {
    _disposed = true;
    _pending = null;
    try {
      await _flight;
    } finally {
      _uncertain = null;
    }
  }
}

final class _Update {
  const _Update(this.token, this.allowed, this.key);
  final String? token;
  final bool allowed;
  final String key;
}
