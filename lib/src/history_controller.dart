import 'dart:async';

import 'client.dart';
import 'models.dart';
import 'history_reducer.dart';

/// In-memory, cursor-paginated history for a conversation list or one message
/// thread. The host owns disposal. Reconnect/refresh starts a new page chain:
/// retaining older pages across a replay gap could hide an unfilled middle gap.
final class ChatHistoryController {
  ChatHistoryController(this.client, {this.conversationId}) {
    _subscriptions.add(client.events.listen(_event));
    _subscriptions.add(client.sendQueue.changes.listen((_) => _notify()));
    _subscriptions.add(client.sendQueue.accepted.listen(includeMessage));
    _subscriptions.add(
      client.states.listen((state) {
        if (state != ChatClientState.ready) _reset();
      }),
    );
    _subscriptions.add(
      client.connectionStates.listen((state) {
        if (state == ChatConnectionState.connected) {
          final conversations = client.cachedConversations;
          final messages = conversationId == null
              ? null
              : client.cachedMessages(conversationId!);
          if (conversationId == null && conversations != null) {
            _snapshot(
              conversations.data.map((v) => v.toJson()).toList(),
              conversations.hasMore,
              conversations.nextCursor,
            );
          } else if (messages != null) {
            _snapshot(
              messages.data.map((v) => v.toJson()).toList(),
              messages.hasMore,
              messages.nextCursor,
            );
          } else {
            unawaited(refresh());
          }
        }
      }),
    );
  }
  final ProtodeskChatClient client;
  final String? conversationId;
  final _updates = StreamController<void>.broadcast();
  final _subscriptions = <StreamSubscription>[];
  Map<String, dynamic> _page = {
    'data': <dynamic>[],
    'hasMore': false,
    'nextCursor': null,
  };
  final _cursors = <String>{};
  final _duringLoad = <ChatServerEvent>[];
  Future<void>? _pending;
  int _generation = 0;
  bool _disposed = false, _loaded = false, _overflow = false;
  ProtodeskChatException? _error;

  Stream<void> get changes => _updates.stream;
  bool get isLoading => _pending != null;
  bool get hasMore => _page['hasMore'] as bool;
  String? get nextCursor => _page['nextCursor'] as String?;
  ProtodeskChatException? get error => _error;
  List<ChatConversation> get conversations => conversationId != null
      ? const []
      : List.unmodifiable(
          (_page['data'] as List).map((v) => ChatConversation.fromJson(v)),
        );

  /// Newest first, matching the backend's createdAt/id descending keyset order.
  List<ChatMessage> get messages {
    if (conversationId == null) return const [];
    final canonical = (_page['data'] as List)
        .map((v) => ChatMessage.fromJson(v))
        .toList();
    final confirmed = canonical.map((v) => v.clientMessageId).toSet();
    final pending = client.sendQueue.messages.where(
      (p) =>
          p.conversationId == conversationId &&
          !confirmed.contains(p.clientMessageId),
    );
    return List.unmodifiable([
      for (final p in pending.toList().reversed)
        ChatMessage.fromJson({
          'id': 'local_${p.clientMessageId}',
          'clientMessageId': p.clientMessageId,
          'conversationId': p.conversationId,
          'body': p.text,
          'sender': 'endUser',
          'status': p.state.name,
          'createdAt': p.createdAt.toUtc().toIso8601String(),
          'updatedAt': p.createdAt.toUtc().toIso8601String(),
        }),
      ...canonical,
    ]);
  }

  void _notify() {
    if (!_disposed) _updates.add(null);
  }

  void _reset() {
    ++_generation;
    _pending = null;
    _page = {'data': <dynamic>[], 'hasMore': false, 'nextCursor': null};
    _loaded = false;
    _error = null;
    _overflow = false;
    _cursors.clear();
    _duringLoad.clear();
    _notify();
  }

  /// Discards the old pagination chain and fetches its authoritative first page.
  /// Errors are exposed through error/changes, making retry safe for UI handlers.
  Future<void> refresh() {
    if (_disposed) return Future.value();
    _reset();
    return loadNext();
  }

  /// Single-flight. Failures retain the cursor, allowing the same page to retry.
  Future<void> loadNext() {
    if (_disposed) return Future.value();
    if (_pending != null) return _pending!;
    if (_loaded && !hasMore) return Future.value();
    final generation = _generation;
    final cursor = _loaded ? nextCursor : null;
    _error = null;
    _duringLoad.clear();
    _overflow = false;
    final task = _load(generation, cursor);
    _pending = task;
    _notify();
    return task;
  }

  /// Invalidated page chains must restart; transient errors retry in place.
  Future<void> retry() =>
      const {
        'chat.history_refresh_required',
        'chat.invalid_page_cursor',
        'chat.cursor_invalid',
        'request.invalid_cursor',
      }.contains(_error?.code)
      ? refresh()
      : loadNext();

  bool _active(int generation) =>
      !_disposed &&
      generation == _generation &&
      client.state == ChatClientState.ready;
  Future<void> _load(int generation, String? cursor) async {
    try {
      late List<Map<String, dynamic>> rows;
      late bool more;
      String? next;
      if (conversationId == null) {
        final page = await client.listConversations(cursor: cursor);
        rows = page.data.map((v) => v.toJson()).toList();
        more = page.hasMore;
        next = page.nextCursor;
      } else {
        final page = await client.listMessages(conversationId!, cursor: cursor);
        rows = page.data.map((v) => v.toJson()).toList();
        more = page.hasMore;
        next = page.nextCursor;
        if (rows.any((v) => v['conversationId'] != conversationId)) {
          throw const ProtodeskChatException('chat.invalid_page');
        }
      }
      if (!_active(generation)) return;
      if (_overflow) {
        throw const ProtodeskChatException(
          'chat.history_refresh_required',
          retryable: true,
        );
      }
      _validateCursor(more, next, cursor);
      // Older pages may overlap with rows updated by realtime while HTTP waited.
      final merged = <String, Map<String, dynamic>>{};
      for (final row in [...rows, if (_loaded) ...(_page['data'] as List)]) {
        final id = row['id'] as String;
        final previous = merged[id];
        if (previous == null || !_version(row).isBefore(_version(previous))) {
          merged[id] = Map<String, dynamic>.from(row);
        }
      }
      final result = merged.values.toList()..sort(_order);
      var nextPage = <String, dynamic>{
        'data': result,
        'hasMore': more,
        'nextCursor': more ? next : null,
      };
      for (final event in _duringLoad) {
        nextPage = _reduce(nextPage, event);
      }
      _page = nextPage;
      _loaded = true;
      if (cursor != null) _cursors.add(cursor);
    } catch (error) {
      if (_active(generation)) {
        _error = error is ProtodeskChatException
            ? error
            : const ProtodeskChatException('chat.invalid_page');
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _pending = null;
        _duringLoad.clear();
        _notify();
      }
    }
  }

  void _validateCursor(bool more, String? next, String? cursor) {
    if (more &&
        (next == null ||
            next.isEmpty ||
            next == cursor ||
            _cursors.contains(next))) {
      throw const ProtodeskChatException('chat.invalid_page_cursor');
    }
  }

  void _snapshot(List<Map<String, dynamic>> rows, bool more, String? cursor) {
    _reset();
    try {
      _validateCursor(more, cursor, null);
      _page = {'data': rows, 'hasMore': more, 'nextCursor': cursor};
      _loaded = true;
    } catch (_) {
      _error = const ProtodeskChatException('chat.invalid_page_cursor');
    }
    _notify();
  }

  Map<String, dynamic> _reduce(
    Map<String, dynamic> page,
    ChatServerEvent event,
  ) {
    if (event.type == 'conversation.read') {
      if (conversationId != null) return page;
      final id = (event.data['readState'] as Map)['conversationId'];
      final latest = client.cachedConversations?.data
          .where((v) => v.id == id)
          .firstOrNull;
      return {
        ...page,
        'data': [
          for (final row in page['data'] as List)
            if (row['id'] != id)
              row
            else if (latest != null)
              latest.toJson()
            else
              {...row as Map<String, dynamic>, 'unreadCountIsStale': true},
        ],
      };
    }
    final history = reduceHistory({
      'conversations': conversationId == null
          ? page
          : {'data': <dynamic>[], 'hasMore': false},
      'conversationId': conversationId,
      'messages': conversationId == null ? null : page,
    }, event);
    return history[conversationId == null ? 'conversations' : 'messages']
        as Map<String, dynamic>;
  }

  void _event(ChatServerEvent event) {
    if (_disposed || client.state != ChatClientState.ready) return;
    try {
      if (isLoading) {
        if (_duringLoad.length < 256) {
          _duringLoad.add(event);
        } else {
          _overflow = true;
        }
      }
      _page = _reduce(_page, event);
      _notify();
    } catch (_) {
      _error = const ProtodeskChatException(
        'chat.history_refresh_required',
        retryable: true,
      );
      _notify();
    }
  }

  /// Include a server-confirmed send response without refreshing older pages.
  void includeMessage(ChatMessage message) {
    if (_disposed ||
        client.state != ChatClientState.ready ||
        message.conversationId != conversationId) {
      return;
    }
    _event(
      ChatServerEvent.fromJson({
        'id': 'local-confirmed',
        'type': 'message.created',
        'data': {'schemaVersion': 1, 'message': message.toJson()},
      }),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _reset();
    _disposed = true;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await _updates.close();
  }
}

DateTime _version(Map row) =>
    DateTime.parse((row['updatedAt'] ?? row['createdAt']) as String);
int _order(Map a, Map b) {
  final time = DateTime.parse(b['createdAt'] as String)
      .compareTo(DateTime.parse(a['createdAt'] as String));
  return time != 0 ? time : (b['id'] as String).compareTo(a['id'] as String);
}
