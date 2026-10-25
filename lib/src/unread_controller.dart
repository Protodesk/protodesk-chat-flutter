import 'dart:async';

import 'client.dart';
import 'models.dart';

/// Customer-wide unread badge. Events invalidate rather than increment totals.
/// Own/dispose alongside a visible badge. Read reports also invalidate totals.
final class ChatUnreadController {
  ChatUnreadController(this.client) {
    _subscriptions.add(client.readReports.listen((_) => _invalidate()));
    _subscriptions.add(
      client.events.listen((event) {
        if (event.type == 'message.created' ||
            event.type == 'conversation.read' ||
            event.type.startsWith('conversation.')) {
          _invalidate();
        }
      }),
    );
    _subscriptions.add(
      client.connectionStates.listen((state) {
        if (state == ChatConnectionState.connected) _invalidate();
      }),
    );
    _subscriptions.add(
      client.states.listen((state) {
        ++_revision;
        _count = null;
        _stale = true;
        _error = null;
        _timer?.cancel();
        _timer = null;
        _notify();
        if (state == ChatClientState.ready) _invalidate();
      }),
    );
    _invalidate();
  }
  final ProtodeskChatClient client;
  final _subscriptions = <StreamSubscription>[];
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  int? get count => _count;
  bool get isStale => _stale;
  ProtodeskChatException? get error => _error;
  int? _count;
  bool _stale = true, _disposed = false;
  int _revision = 0;
  Timer? _timer;
  Future<void>? _pending;
  ProtodeskChatException? _error;
  void _notify() {
    if (!_disposed) _changes.add(null);
  }

  void _invalidate() {
    if (_disposed) return;
    ++_revision;
    _stale = true;
    _notify();
    // One bounded request per burst, not one request per event.
    _timer ??= Timer(const Duration(milliseconds: 500), () {
      _timer = null;
      unawaited(refresh());
    });
  }

  Future<void> refresh() {
    if (_disposed || client.state != ChatClientState.ready) {
      return Future.value();
    }
    _timer?.cancel();
    _timer = null;
    return _pending ??= _refresh().whenComplete(() => _pending = null);
  }

  Future<void> _refresh() async {
    final revision = _revision;
    try {
      final result = await client.getUnreadCount();
      if (_disposed || revision != _revision) return;
      _count = result;
      _stale = false;
      _error = null;
    } catch (error) {
      if (_disposed || revision != _revision) return;
      _stale = true;
      _error = error is ProtodeskChatException
          ? error
          : const ProtodeskChatException('chat.unread_unavailable');
    } finally {
      _notify();
      if (!_disposed &&
          revision != _revision &&
          client.state == ChatClientState.ready) {
        _timer?.cancel();
        _timer = Timer(const Duration(milliseconds: 500), () {
          _timer = null;
          unawaited(refresh());
        });
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _changes.close();
  }
}
