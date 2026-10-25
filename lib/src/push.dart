import 'models.dart';
import 'version.dart';

/// Provider SDKs and notification permission prompts remain host-owned.
enum ChatPushProvider { fcm, apns, onesignal }

/// A handle bound to one client identity. Capture this in provider callbacks;
/// acquire a new handle after login, identity merge, or account switching.
final class ChatPushTargets {
  ChatPushTargets({
    required this._check,
    required this._request,
    required this._newId,
    required this._platform,
    this._loadTargetId,
    this._saveTargetId,
  });

  final void Function() _check;
  final Future<Map<String, dynamic>> Function(
    String,
    String,
    Map<String, dynamic>?,
    String?,
  )
  _request;
  final String Function() _newId;
  final String _platform;
  final Future<String?> Function()? _loadTargetId;
  final Future<void> Function(String?)? _saveTargetId;
  bool _loaded = false;
  Future<void> _load() async {
    if (_loaded) return;
    final id = await _loadTargetId?.call();
    _check();
    _targetId = id;
    _loaded = true;
  }

  String? _targetId;
  bool _busy = false;

  /// Routing metadata only, restored lazily by register/unregister.
  /// Raw provider tokens are never retained by this handle.
  String? get targetId {
    _check();
    return _targetId;
  }

  /// Register initially, or refresh the existing target after provider rotation.
  /// Call only after the host has obtained notification permission and opt-in.
  /// Retry an uncertain request with the same key and identical arguments.
  Future<String> register({
    required ChatPushProvider provider,
    required String target,
    required String installationId,
    required bool permissionGranted,
    String appVersion = '',
    String locale = '',
    String? idempotencyKey,
  }) async {
    _check();
    if (!permissionGranted) {
      throw const ProtodeskChatException('chat.push_permission_required');
    }
    if (target.isEmpty ||
        installationId.isEmpty ||
        (_platform != 'android' && _platform != 'ios') ||
        (provider == ChatPushProvider.apns && _platform != 'ios')) {
      throw const ProtodeskChatException('chat.push_target_invalid');
    }
    if (_busy) throw const ProtodeskChatException('chat.push_busy');
    _busy = true;
    try {
      await _load();
      final id = _targetId;
      final result = await _request(
        id == null ? 'POST' : 'PUT',
        '/v1/chat/push-targets${id == null ? '' : '/${Uri.encodeComponent(id)}'}',
        {
          'sdkInstallationId': installationId,
          'platform': _platform,
          'provider': provider.name,
          'targetKind': provider == ChatPushProvider.onesignal
              ? 'onesignal_subscription_id'
              : 'native_device_token',
          'target': target,
          'appVersion': appVersion,
          'sdkVersion': chatSdkVersion,
          'locale': locale,
        },
        idempotencyKey ?? _newId(),
      );
      _check();
      final returnedId = result['id'];
      if (returnedId is! String ||
          returnedId.isEmpty ||
          result['status'] != 'active') {
        throw const ProtodeskChatException('chat.invalid_response');
      }
      await _saveTargetId?.call(returnedId);
      _check();
      _targetId = returnedId;
      return returnedId;
    } on ProtodeskChatException catch (error) {
      if (error.status == 404 && _targetId != null) await _forget();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Future<void> _forget() async {
    _check();
    await _saveTargetId?.call(null);
    _check();
    _targetId = null;
  }

  /// Stop the provider listener first. If registration is still in flight,
  /// await it (including its failure), then unregister. No work is queued.
  /// An uncertain initial registration can be retried with its original key,
  /// or revoked by logging out the session.
  Future<void> unregister() async {
    _check();
    if (_busy) throw const ProtodeskChatException('chat.push_busy');
    _busy = true;
    try {
      await _load();
      final id = _targetId;
      if (id == null) return;
      await _request(
        'DELETE',
        '/v1/chat/push-targets/${Uri.encodeComponent(id)}',
        null,
        null,
      );
      _check();
      await _forget();
    } on ProtodeskChatException catch (error) {
      if (error.status != 404) rethrow;
      await _forget();
    } finally {
      _busy = false;
    }
  }
}
