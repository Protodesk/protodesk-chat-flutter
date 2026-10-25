import 'dart:async';
import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

/// Host initializes Firebase and requests permission before attaching.
/// Forward onMessageOpenedApp/getInitialMessage to navigation separately, early
/// in startup. Those app-global handlers must not be tied to registration.
final class FcmChatAdapter {
  FcmChatAdapter(this.messaging, this.binding, {required this.onError});
  final FirebaseMessaging messaging;
  final ChatPushRegistrationBinding binding; // provider: fcm (Android or iOS)
  final void Function(Object) onError;
  StreamSubscription<String>? _tokens;
  bool _optedIn = false, _closed = false;
  int _revision = 0;

  Future<void> start({required bool optedIn}) async {
    if (_closed || _tokens != null)
      throw StateError('Adapter already started/closed');
    _tokens = messaging.onTokenRefresh.listen((token) {
      unawaited(_refresh(token).catchError(onError));
    }, onError: onError);
    await setOptedIn(optedIn);
  }

  Future<void> setOptedIn(bool value) {
    _optedIn = value;
    return refresh();
  }

  /// Call on app resume too: OS settings may have changed outside the app.
  Future<void> refresh() => _refresh(null);
  Future<void> _refresh(String? rotatedToken) async {
    final revision = ++_revision;
    final settings = await messaging.getNotificationSettings();
    if (_closed || revision != _revision) return;
    final allowed =
        _optedIn &&
        (settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional);
    if (!allowed) {
      await binding.update(permissionGranted: false);
      return;
    }
    // Firebase requires the APNs token before requesting FCM on Apple devices.
    // The host should call refresh after APNs registration if getToken is not ready.
    if (Platform.isIOS && await messaging.getAPNSToken() == null) return;
    if (_closed || revision != _revision) return;
    final token = rotatedToken ?? await messaging.getToken();
    if (_closed || revision != _revision) return;
    await binding.update(token: token, permissionGranted: true);
  }

  Future<void> dispose() async {
    _closed = true;
    ++_revision;
    await _tokens?.cancel();
    await binding.dispose();
  }
}
