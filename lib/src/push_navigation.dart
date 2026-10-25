import 'dart:async';
import 'dart:convert';

import 'models.dart';

/// Versioned, untrusted navigation hint. Never contains message content or URLs.
final class ChatPushPayload {
  const ChatPushPayload._(
    this.publicChatAppId,
    this.conversationId,
    this.notificationIntentId,
  );
  final String publicChatAppId, conversationId, notificationIntentId;

  /// Accepts FCM data, APNs userInfo, or OneSignal additionalData.
  static ChatPushPayload? parse(
    Object? data, {
    required String publicChatAppId,
  }) {
    if (data is! Map) return null;
    Object? value = data['protodesk'];
    if (value is String) {
      if (value.length > 4096) return null;
      try {
        value = jsonDecode(value);
      } on FormatException {
        return null;
      }
    }
    if (value is! Map ||
        value.length > 16 ||
        value['schemaVersion'] is! int ||
        value['schemaVersion'] != 1 ||
        value['type'] != 'message.created' ||
        value['publicChatAppId'] != publicChatAppId) {
      return null;
    }
    final conversation = value['conversationId'];
    final intent = value['notificationIntentId'];
    if (conversation is! String ||
        intent is! String ||
        !RegExp(r'^conv_[a-z2-7]{26}$').hasMatch(conversation) ||
        !RegExp(r'^nti_[a-z2-7]{25}[aeimquy4]$').hasMatch(intent)) {
      return null;
    }
    return ChatPushPayload._(publicChatAppId, conversation, intent);
  }
}

bool isProtodeskPush(Object? data, {required String publicChatAppId}) =>
    ChatPushPayload.parse(data, publicChatAppId: publicChatAppId) != null;

/// One identity-scoped, memory-only pending tap. Host retains its global handlers.
/// Call [setReadiness] on lifecycle and navigator changes. The synchronous
/// [onNavigate] callback returns true only when the host accepts the route.
final class ChatPushNavigation {
  ChatPushNavigation({
    required this.publicChatAppId,
    required this._isCurrent,
    required this._isReady,
    required Stream<ChatClientState> states,
    required this._resolve,
    required this._reportOpen,
    required this.onNavigate,
    this.pendingLifetime = const Duration(minutes: 2),
  }) {
    if (pendingLifetime <= Duration.zero ||
        pendingLifetime > const Duration(minutes: 5)) {
      throw ArgumentError.value(pendingLifetime, 'pendingLifetime');
    }
    _subscription = states.listen((_) {
      if (!_isCurrent()) {
        _pending = null;
        _timer?.cancel();
      }
      _drain();
    });
  }
  final String publicChatAppId;
  final Duration pendingLifetime;
  final bool Function(ChatConversation conversation) onNavigate;
  final bool Function() _isCurrent, _isReady;
  final Future<ChatConversation> Function(String) _resolve;
  final Future<void> Function(String) _reportOpen;
  final _errors = StreamController<ProtodeskChatException>.broadcast();
  Stream<ProtodeskChatException> get errors => _errors.stream;
  late final StreamSubscription<ChatClientState> _subscription;
  final _seen = <String, DateTime>{};
  ChatPushPayload? _pending;
  DateTime? _expires;
  Timer? _timer;
  bool _active = false,
      _navigatorReady = false,
      _busy = false,
      _disposed = false;
  bool get hasPending =>
      !_disposed &&
      _isCurrent() &&
      _pending != null &&
      DateTime.now().isBefore(_expires!);

  /// Call only for an actual user tap, including a cold-start tap, not receipt.
  /// Returns false for unrelated, unsupported, malformed, or old-identity input.
  bool handlePushPayload(Object? data) {
    if (_disposed || !_isCurrent()) return false;
    final payload = ChatPushPayload.parse(
      data,
      publicChatAppId: publicChatAppId,
    );
    if (payload == null) return false;
    final now = DateTime.now();
    _seen.removeWhere(
      (_, at) => now.difference(at) >= const Duration(minutes: 5),
    );
    if (_seen.containsKey(payload.notificationIntentId)) return true;
    if (_seen.length >= 128) _seen.remove(_seen.keys.first);
    _seen[payload.notificationIntentId] = now;
    _pending = payload;
    _expires = now.add(pendingLifetime);
    _timer?.cancel();
    _timer = Timer(pendingLifetime, () {
      _pending = null;
    });
    _drain();
    return true;
  }

  void setReadiness({required bool active, required bool navigatorReady}) {
    _active = active;
    _navigatorReady = navigatorReady;
    _drain();
  }

  bool get _canNavigate =>
      hasPending && _active && _navigatorReady && _isReady();
  void _drain() {
    if (_busy || !_canNavigate) return;
    _busy = true;
    unawaited(_deliver());
  }

  Future<void> _deliver() async {
    final payload = _pending!;
    try {
      final conversation = await _resolve(payload.conversationId);
      if (!_canNavigate || !identical(payload, _pending)) return;
      if (conversation.id != payload.conversationId) {
        throw const ProtodeskChatException('chat.invalid_response');
      }
      // Consume before calling host code, which may synchronously log out.
      _pending = null;
      _timer?.cancel();
      if (onNavigate(conversation) &&
          !_disposed &&
          _isCurrent() &&
          _isReady()) {
        await _reportOpen(payload.notificationIntentId);
      }
    } catch (error) {
      if (!_disposed && _isCurrent()) {
        if (identical(payload, _pending)) _pending = null;
        _errors.add(
          error is ProtodeskChatException
              ? error
              : const ProtodeskChatException('chat.push_navigation_failed'),
        );
      }
    } finally {
      _busy = false;
      // A newer tap may have replaced the request while it was in flight.
      if (!identical(payload, _pending)) _drain();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pending = null;
    _seen.clear();
    _timer?.cancel();
    await _subscription.cancel();
    await _errors.close();
  }
}
