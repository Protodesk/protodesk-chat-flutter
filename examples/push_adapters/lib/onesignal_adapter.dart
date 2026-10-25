import 'dart:async';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

/// Host initializes OneSignal. Never calls login/logout/optIn on its behalf.
final class OneSignalChatAdapter {
  OneSignalChatAdapter(this.binding, {required this.onError});
  final ChatPushRegistrationBinding binding; // provider: onesignal
  final void Function(Object) onError;
  bool _optedIn = false, _closed = false, _started = false;
  void _subscription(OSPushSubscriptionChangedState _) => _changed();
  void _permission(bool _) => _changed();
  void _changed() {
    if (!_closed) unawaited(refresh().catchError(onError));
  }

  Future<void> start({required bool optedIn}) async {
    if (_started || _closed) throw StateError('Adapter already started/closed');
    _started = true;
    _optedIn = optedIn;
    OneSignal.User.pushSubscription.addObserver(_subscription);
    OneSignal.Notifications.addPermissionObserver(_permission);
    await refresh();
  }

  Future<void> setOptedIn(bool value) {
    _optedIn = value;
    return refresh();
  }

  Future<void> refresh() async {
    if (_closed) return;
    await binding.update(
      token: OneSignal.User.pushSubscription.id,
      permissionGranted:
          _optedIn &&
          OneSignal.Notifications.permission &&
          OneSignal.User.pushSubscription.optedIn == true,
    );
  }

  Future<void> dispose() async {
    _closed = true;
    OneSignal.User.pushSubscription.removeObserver(_subscription);
    OneSignal.Notifications.removePermissionObserver(_permission);
    await binding.dispose();
  }
}
