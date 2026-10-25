import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

/// Attach early for cold start. Only taps, never foreground/background receipt.
/// Does not replace the app's other Firebase listeners or background handler.
final class FcmChatTaps {
  FcmChatTaps(this.navigation);
  final ChatPushNavigation navigation;
  StreamSubscription<RemoteMessage>? _subscription;
  bool _closed = false;
  Future<void> start(
    FirebaseMessaging messaging, {
    bool readInitialMessage = true,
  }) async {
    if (_closed || _subscription != null)
      throw StateError('Already started/closed');
    var liveTap = false;
    _subscription = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      liveTap = true;
      navigation.handlePushPayload(message.data);
    });
    if (!readInitialMessage) return;
    final initial = await messaging.getInitialMessage();
    if (!_closed && !liveTap && initial != null)
      navigation.handlePushPayload(initial.data);
  }

  Future<void> dispose() async {
    _closed = true;
    await _subscription?.cancel();
  }
}

/// Additive listener. Host retains responsibility for non-Chat click handling.
final class OneSignalChatTaps {
  OneSignalChatTaps(this.navigation);
  final ChatPushNavigation navigation;
  bool _started = false;
  void _click(OSNotificationClickEvent event) {
    if (event.result.actionId?.isNotEmpty == true) return;
    if (_started)
      navigation.handlePushPayload(event.notification.additionalData);
  }

  void start() {
    if (_started) throw StateError('Already started');
    _started = true;
    OneSignal.Notifications.addClickListener(_click);
  }

  void dispose() {
    _started = false;
    OneSignal.Notifications.removeClickListener(_click);
  }
}
