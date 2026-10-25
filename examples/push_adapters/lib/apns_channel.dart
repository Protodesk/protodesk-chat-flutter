import 'package:flutter/services.dart';
import 'package:protodesk_chat/protodesk_chat.dart';
import 'apns_adapter.dart';

/// One host-owned channel per app; attach early for cold-start taps. If identity
/// is not ready yet, attach navigation first and pass registration after login.
final class ApnsChatChannel {
  ApnsChatChannel({required this.navigation, required this.onError});
  final ChatPushNavigation navigation;
  final void Function(Object) onError;
  final _channel = const MethodChannel('host.protodesk/apns');
  ApnsChatAdapter? registration;
  bool optedIn = false, _closed = false;
  int _revision = 0;
  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (_closed) return;
      if (call.method == 'opened') navigation.handlePushPayload(call.arguments);
      if (call.method == 'registrationChanged') {
        try {
          await refresh();
        } catch (error) {
          onError(error);
        }
      }
    });
    await refresh();
    final initial = await _channel.invokeMethod<Object?>('takeInitialTap');
    if (!_closed) navigation.handlePushPayload(initial);
  }

  /// Call on resume and after setting registration or changing host opt-in.
  Future<void> refresh() async {
    final revision = ++_revision;
    final adapter = registration;
    final state = await _channel.invokeMapMethod<String, dynamic>('snapshot');
    if (_closed ||
        revision != _revision ||
        adapter == null ||
        adapter != registration)
      return;
    final allowed = optedIn && state?['allowed'] == true;
    if (!allowed) {
      await adapter.permissionRevoked();
      return;
    }
    final token = state?['token'];
    if (token is String)
      await adapter.didRegister(hexToken: token, allowed: true);
  }

  void dispose() {
    _closed = true;
    ++_revision;
    _channel.setMethodCallHandler(null);
  }
}
