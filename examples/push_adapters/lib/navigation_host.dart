import 'dart:async';
import 'package:flutter/material.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

/// Own alongside the client, recreate after identity changes. The host supplies
/// its existing navigator key and may adapt onNavigate to its declarative router.
final class ChatPushNavigationHost with WidgetsBindingObserver {
  ChatPushNavigationHost(ProtodeskChatClient client, this.navigatorKey) {
    navigation = client.createPushNavigation(
      onNavigate: (conversation) {
        final navigator = navigatorKey.currentState;
        if (navigator == null || !navigator.mounted) return false;
        unawaited(
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                client: client,
                initialConversationId: conversation.id,
              ),
            ),
          ),
        );
        return true;
      },
    );
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => refreshReadiness());
  }
  final GlobalKey<NavigatorState> navigatorKey;
  late final ChatPushNavigation navigation;
  bool _disposed = false;

  /// Also call when the host mounts/replaces its navigator or changes scenes.
  void refreshReadiness() {
    if (_disposed) return;
    navigation.setReadiness(
      active:
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      navigatorReady: navigatorKey.currentState?.mounted == true,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      refreshReadiness();
  Future<void> dispose() async {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    await navigation.dispose();
  }
}
