import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'models.dart';

enum ChatSendState { queued, sending, failed }

final class ChatSendQueueOptions {
  const ChatSendQueueOptions({
    this.maxMessages = 50,
    this.maxBytes = 262144,
    this.maxAge = const Duration(hours: 24),
    this.maxAttempts = 5,
    this.baseRetryDelay = const Duration(seconds: 1),
  });
  final int maxMessages, maxBytes, maxAttempts;
  final Duration maxAge, baseRetryDelay;
}

final class ChatQueuedMessage {
  const ChatQueuedMessage({
    required this.clientMessageId,
    required this.conversationId,
    required this.text,
    required this.createdAt,
    required this.state,
    required this.attempts,
    this.error,
    this.retryAt,
  });
  final String clientMessageId, conversationId, text;
  final DateTime createdAt;
  final ChatSendState state;
  final int attempts;
  final ProtodeskChatException? error;
  final DateTime? retryAt;
}

/// Client-owned text outbox with optional atomic secure persistence.
/// Use enqueueDurably when persistence is enabled; the client owns its lifecycle.
final class ChatSendQueue {
  ChatSendQueue({
    required this.options,
    required this.send,
    required this.newId,
    required this.isReady,
    this.persist,
  }) {
    if (options.maxMessages < 1 ||
        options.maxMessages > 100 ||
        options.maxBytes < 1 ||
        options.maxBytes > 1048576 ||
        options.maxAttempts < 1 ||
        options.maxAttempts > 8 ||
        options.maxAge <= Duration.zero ||
        options.maxAge > const Duration(hours: 24) ||
        options.baseRetryDelay <= Duration.zero)
      throw ArgumentError('Invalid send queue limits.');
  }
  final Future<void> Function(Map<String, dynamic>)? persist;
  Future<void> _writes = Future.value();
  bool _storageBlocked = false;
  bool get isPersistent => persist != null;
  bool get storageBlocked => _storageBlocked;
  final ChatSendQueueOptions options;
  final Future<ChatMessage> Function(
    String conversationId,
    String id,
    String text,
  )
  send;
  final String Function() newId;
  final bool Function() isReady;
  final _items = <_Pending>[];
  final _changes = StreamController<void>.broadcast();
  final _accepted = StreamController<ChatMessage>.broadcast();
  Timer? _timer;
  bool _active = true, _running = false, _closed = false;
  int _epoch = 0;
  ProtodeskChatException? lastError;
  Stream<void> get changes => _changes.stream;
  Stream<ChatMessage> get accepted => _accepted.stream;
  List<ChatQueuedMessage> get messages =>
      List.unmodifiable(_items.map((p) => p.snapshot));

  String enqueue({required String conversationId, required String text}) {
    if (isPersistent)
      throw const ProtodeskChatException('chat.durable_enqueue_required');
    final item = _enqueue(conversationId, text);
    _kick();
    return item.id;
  }

  Future<String> enqueueDurably({
    required String conversationId,
    required String text,
  }) async {
    if (_storageBlocked)
      throw const ProtodeskChatException('chat.storage_unavailable');
    final epoch = _epoch;
    final item = _enqueue(conversationId, text);
    try {
      await _persist();
      if (_closed || epoch != _epoch)
        throw const ProtodeskChatException('chat.operation_cancelled');
      _kick();
      return item.id;
    } catch (_) {
      _items.remove(item);
      _notify();
      rethrow;
    }
  }

  _Pending _enqueue(String conversationId, String text) {
    if (_closed || !isReady())
      throw const ProtodeskChatException('chat.session_required');
    _expire();
    final bytes = utf8.encode(text).length;
    if (conversationId.isEmpty ||
        conversationId.length > 128 ||
        text.trim().isEmpty ||
        bytes > 16384) {
      throw const ProtodeskChatException('chat.message_invalid');
    }
    if (_items.length >= options.maxMessages ||
        _items.fold<int>(0, (sum, p) => sum + p.bytes) + bytes >
            options.maxBytes) {
      throw const ProtodeskChatException('chat.send_queue_full');
    }
    final item = _Pending(
      newId(),
      conversationId,
      text,
      bytes,
      maxAge: options.maxAge,
    );
    _items.add(item);
    lastError = null;
    _notify();
    return item;
  }

  /// Explicit retries keep the exact original body and operation ID. Retry-After
  /// remains a minimum even for user-triggered retries.
  Future<void> retry(String id) async {
    if (_closed || !isReady()) return;
    _expire();
    final p = _items.where((p) => p.id == id).firstOrNull;
    if (p == null || p.state == ChatSendState.sending) return;
    if (p.error != null && !p.error!.retryable) return;
    p.attempts = 0;
    p.state = ChatSendState.queued;
    p.retryAt = p.serverRetryAt;
    p.error = null;
    _notify();
    if (isPersistent) await _persist();
    _kick();
  }

  /// Removes only an idle local item. An attempted request may already have been
  /// accepted remotely; discard never deletes a server message.
  Future<void> discard(String id) async {
    _items.removeWhere((p) => p.id == id && p.state != ChatSendState.sending);
    _notify();
    if (isPersistent) await _persist();
    _kick();
  }

  /// Called with customer-scoped canonical REST/history/realtime messages.
  Future<void> acknowledge(ChatMessage message) async {
    if (_closed || !isReady()) return;
    final p = _items
        .where(
          (p) =>
              p.id == message.clientMessageId &&
              p.conversationId == message.conversationId,
        )
        .firstOrNull;
    if (p == null) return;
    _items.remove(p);
    final epoch = _epoch;
    try {
      if (isPersistent) await _persist();
      if (_closed || epoch != _epoch || !isReady()) return;
      _accepted.add(message);
      _notify();
      _kick();
    } catch (_) {
      // Server acceptance is known even when removal cannot be saved. Surface
      // storage failure and stop retries; a restart reuses the same operation ID.
      if (!_closed && epoch == _epoch && isReady()) {
        _accepted.add(message);
        _notify();
      }
    }
  }

  void setActive(bool active) {
    _active = active;
    _timer?.cancel();
    _kick();
  }

  void clear() {
    ++_epoch;
    _timer?.cancel();
    _timer = null;
    _items.clear();
    lastError = null;
    _notify();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _active = false;
    _timer?.cancel();
    // Finish previously accepted writes while the client's identity is valid.
    await _writes;
    clear();
    await _changes.close();
    await _accepted.close();
  }

  Map<String, dynamic> _record() => {
    'queueVersion': 1,
    'items': _items.map((p) => p.toJson()).toList(),
  };

  Future<void> _persist({bool recover = false}) {
    if (persist == null) return Future.value();
    final value = _record(), epoch = _epoch;
    final result = _writes.then((_) async {
      if (epoch != _epoch)
        throw const ProtodeskChatException('chat.operation_cancelled');
      if (_storageBlocked && !recover)
        throw const ProtodeskChatException('chat.storage_unavailable');
      await persist!(value);
    });
    _writes = result.then<void>(
      (_) {},
      onError: (Object error) {
        if (epoch != _epoch || _closed) return;
        _storageBlocked = true;
        _timer?.cancel();
        lastError = error is ProtodeskChatException
            ? error
            : const ProtodeskChatException('chat.storage_unavailable');
        _notify();
      },
    );
    return result;
  }

  void _saveSoon() {
    unawaited(_persist().catchError((Object _) {}));
  }

  /// After storage is repaired, durably adopt the current state before resuming.
  Future<void> retryPersistence() async {
    if (_closed || !isReady())
      throw const ProtodeskChatException('chat.session_required');
    await _persist(recover: true);
    _storageBlocked = false;
    lastError = null;
    _notify();
    _kick();
  }

  /// Internal restore after authentication, before the client becomes ready.
  Future<void> restore(Map<String, dynamic>? record) async {
    _active = false;
    if (record == null) return;
    try {
      if (record['queueVersion'] != 1 ||
          record['items'] is! List ||
          (record['items'] as List).length > 100)
        throw const FormatException();
      final restored = <_Pending>[];
      final ids = <String>{};
      final now = DateTime.now();
      for (final raw in record['items'] as List) {
        final p = _Pending.fromJson(raw as Map<String, dynamic>, options, now);
        if (!ids.add(p.id)) throw const FormatException();
        if (now.isBefore(p.expires)) restored.add(p);
      }
      if (restored.length > options.maxMessages ||
          restored.fold<int>(0, (n, p) => n + p.bytes) > options.maxBytes)
        throw const FormatException();
      _items.addAll(restored);
    } catch (_) {
      throw const ProtodeskChatException('chat.storage_corrupt');
    }
    // Persist pruning and interrupted-attempt recovery before any retry.
    await _persist();
    _schedule();
  }

  void _notify() {
    if (!_closed) _changes.add(null);
  }

  void _expire() {
    final now = DateTime.now();
    final count = _items.length;
    _items.removeWhere((p) => !now.isBefore(p.expires));
    if (_items.length != count) {
      lastError = const ProtodeskChatException('chat.send_queue_expired');
      _saveSoon();
      _notify();
    }
  }

  void _kick() {
    if (_closed) return;
    _expire();
    _timer?.cancel();
    _timer = null;
    if (_storageBlocked) {
      _schedule();
      return;
    }
    if (!_running && _active && isReady()) {
      final head = _items
          .where((p) => p.state == ChatSendState.queued)
          .firstOrNull;
      if (head != null &&
          (head.retryAt == null || !head.retryAt!.isAfter(DateTime.now()))) {
        _running = true;
        unawaited(_drain());
        return;
      }
    }
    _schedule();
  }

  void _schedule() {
    if (_closed || _items.isEmpty) return;
    final now = DateTime.now();
    var next = _items.first.expires;
    for (final p in _items) {
      final expiry = p.expires;
      if (expiry.isBefore(next)) next = expiry;
    }
    final head = _items
        .where((p) => p.state == ChatSendState.queued)
        .firstOrNull;
    if (!_storageBlocked &&
        !_running &&
        _active &&
        isReady() &&
        head?.retryAt != null &&
        head!.retryAt!.isBefore(next))
      next = head.retryAt!;
    _timer = Timer(
      next.isAfter(now) ? next.difference(now) : Duration.zero,
      _kick,
    );
  }

  Future<void> _drain() async {
    final epoch = _epoch;
    try {
      while (!_closed &&
          !_storageBlocked &&
          epoch == _epoch &&
          _active &&
          isReady()) {
        _expire();
        final p = _items
            .where((p) => p.state == ChatSendState.queued)
            .firstOrNull;
        if (p == null ||
            (p.retryAt != null && p.retryAt!.isAfter(DateTime.now())))
          break;
        p.state = ChatSendState.sending;
        p.attempts++;
        p.error = null;
        _notify();
        _schedule();
        try {
          if (isPersistent)
            await _persist(); // Attempt marker before transmission.
          if (_closed || epoch != _epoch || !_items.contains(p)) continue;
          if (_storageBlocked || !_active || !isReady()) {
            p.state = ChatSendState.queued;
            _saveSoon();
            break;
          }
          final message = await send(p.conversationId, p.id, p.text);
          if (_closed || epoch != _epoch || !_items.contains(p)) continue;
          if (message.clientMessageId != p.id ||
              message.conversationId != p.conversationId) {
            throw const ProtodeskChatException('chat.invalid_send_response');
          }
          await acknowledge(message);
        } catch (error) {
          if (_closed || epoch != _epoch || !_items.contains(p)) continue;
          final safe = _storageBlocked
              ? const ProtodeskChatException(
                  'chat.storage_unavailable',
                  retryable: true,
                )
              : error is ProtodeskChatException
              ? error
              : const ProtodeskChatException('chat.send_failed');
          p.error = safe;
          if (safe.retryAfter != null)
            p.serverRetryAt = DateTime.now().add(safe.retryAfter!);
          if (!safe.retryable || p.attempts >= options.maxAttempts) {
            p.state = ChatSendState.failed;
            p.retryAt = null;
          } else {
            p.state = ChatSendState.queued;
            final ceiling = min(
              30000,
              options.baseRetryDelay.inMilliseconds *
                  (1 << min(p.attempts - 1, 6)),
            );
            p.retryAt = DateTime.now().add(
              Duration(milliseconds: 1 + Random().nextInt(max(1, ceiling))),
            );
            if (p.serverRetryAt != null && p.serverRetryAt!.isAfter(p.retryAt!))
              p.retryAt = p.serverRetryAt;
          }
          _saveSoon();
          _notify();
          if (_storageBlocked || p.state == ChatSendState.queued) break;
        }
      }
    } finally {
      _running = false;
      _kick();
    }
  }
}

final class _Pending {
  _Pending(
    this.id,
    this.conversationId,
    this.text,
    this.bytes, {
    required Duration maxAge,
    DateTime? createdAt,
    DateTime? expiresAt,
  }) : created = createdAt ?? DateTime.now() {
    expires = expiresAt ?? created.add(maxAge);
  }
  factory _Pending.fromJson(
    Map<String, dynamic> value,
    ChatSendQueueOptions options,
    DateTime now,
  ) {
    final id = value['id'] as String,
        conversation = value['conversationId'] as String,
        text = value['text'] as String;
    final created = DateTime.parse(value['createdAt'] as String);
    var expires = DateTime.parse(value['expiresAt'] as String);
    final attempts = value['attempts'] as int;
    if (!RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ).hasMatch(id) ||
        conversation.isEmpty ||
        conversation.length > 128 ||
        text.trim().isEmpty ||
        utf8.encode(text).length > 16384 ||
        attempts < 0 ||
        attempts > 8 ||
        created.isAfter(now.add(const Duration(minutes: 5))) ||
        !expires.isAfter(created) ||
        expires.isAfter(created.add(const Duration(hours: 24))))
      throw const FormatException();
    if (expires.isAfter(created.add(options.maxAge)))
      expires = created.add(options.maxAge);
    final p = _Pending(
      id,
      conversation,
      text,
      utf8.encode(text).length,
      maxAge: options.maxAge,
      createdAt: created,
      expiresAt: expires,
    );
    p.state = ChatSendState.values.byName(value['state'] as String);
    p.attempts = attempts;
    p.retryAt = value['retryAt'] == null
        ? null
        : DateTime.parse(value['retryAt'] as String);
    p.serverRetryAt = value['serverRetryAt'] == null
        ? null
        : DateTime.parse(value['serverRetryAt'] as String);
    if (value['error'] != null) {
      final error = value['error'] as Map;
      final code = error['code'] as String;
      if (!RegExp(r'^chat\.[a-z0-9_]+$').hasMatch(code))
        throw const FormatException();
      p.error = ProtodeskChatException(
        code,
        retryable: error['retryable'] as bool,
      );
    }
    if (p.state == ChatSendState.sending ||
        (p.state == ChatSendState.queued && attempts >= options.maxAttempts)) {
      p.state = attempts >= options.maxAttempts
          ? ChatSendState.failed
          : ChatSendState.queued;
      p.error = const ProtodeskChatException(
        'chat.send_interrupted',
        retryable: true,
      );
    }
    if (p.serverRetryAt != null &&
        (p.retryAt == null || p.retryAt!.isBefore(p.serverRetryAt!)))
      p.retryAt = p.serverRetryAt;
    return p;
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'text': text,
    'createdAt': created.toUtc().toIso8601String(),
    'expiresAt': expires.toUtc().toIso8601String(),
    'state': state.name,
    'attempts': attempts,
    'retryAt': retryAt?.toUtc().toIso8601String(),
    'serverRetryAt': serverRetryAt?.toUtc().toIso8601String(),
    if (error != null)
      'error': {'code': error!.code, 'retryable': error!.retryable},
  };
  final String id, conversationId, text;
  final int bytes;
  final DateTime created;
  late final DateTime expires;
  ChatSendState state = ChatSendState.queued;
  int attempts = 0;
  ProtodeskChatException? error;
  DateTime? retryAt, serverRetryAt;
  ChatQueuedMessage get snapshot => ChatQueuedMessage(
    clientMessageId: id,
    conversationId: conversationId,
    text: text,
    createdAt: created,
    state: state,
    attempts: attempts,
    error: error,
    retryAt: retryAt,
  );
}
