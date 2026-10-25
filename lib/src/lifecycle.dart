import 'dart:async';

import 'models.dart';

/// Local SDK activity, separate from canonical server events. No credentials,
/// message content, identity keys, or notification payloads are included.
enum ChatLifecycleEvent { sessionReady, chatOpened, chatClosed, pushOpened }

/// Internal multiplexer. Installs a state callback only while observed.
final class ChatLifecycle {
  ChatLifecycle(this._setListener) {
    _controller = StreamController<ChatLifecycleEvent>.broadcast(
      onListen: () {
        ChatClientState? previous;
        _setListener((state) {
          if (state == ChatClientState.ready && previous != state) {
            emit(ChatLifecycleEvent.sessionReady);
          }
          previous = state;
        });
      },
      onCancel: () => _setListener(null),
    );
  }
  final void Function(void Function(ChatClientState)? listener) _setListener;
  late final StreamController<ChatLifecycleEvent> _controller;
  Stream<ChatLifecycleEvent> get events => _controller.stream;
  void emit(ChatLifecycleEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }

  void dispose() {
    _setListener(null);
    // Paused host observers must not hold client disposal open.
    unawaited(_controller.close());
  }
}
