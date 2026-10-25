import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'attachment_storage.dart';

import 'models.dart';
import 'configuration.dart';
import 'help.dart';
import 'lifecycle.dart';
import 'diagnostics.dart';
import 'push.dart';
import 'push_navigation.dart';
import 'attachments.dart';
import 'send_queue.dart';
import 'history_reducer.dart';
import 'transport.dart';
import 'storage.dart';
import 'session_vault.dart';

final class ChatClientOptions {
  ChatClientOptions({
    required this.publicChatAppId,
    required this.baseUrl,
    this.identityTokenProvider,
    this.platform = 'android',
    this.transport,
    this.attachmentTransport,
    this.attachmentPersistence = ChatAttachmentPersistencePolicy.disabled,
    this.attachmentFileStore = const PlatformChatAttachmentFileStore(),
    this.attachmentStorageOrigins = const {},
    this.storage,
    this.persistSendQueue = false,
    this.sendQueueOptions = const ChatSendQueueOptions(),
    this.identityKey,
    this.allowNewAnonymousIdentity = false,
    this.recoverLostAnonymousIdentity = false,
    this.initialContext,
  }) {
    ChatAttachments.validateStorageOrigins(attachmentStorageOrigins);
    if (attachmentPersistence ==
            ChatAttachmentPersistencePolicy.managedPrivateCopy &&
        storage == null) {
      throw ArgumentError(
        'Managed attachment copies require secure session storage.',
      );
    }
    if (persistSendQueue && storage == null) {
      throw ArgumentError('Persistent sends require secure storage.');
    }
    if (storage != null &&
        (!storage!.isPlatformSecure ||
            (identityTokenProvider != null &&
                (identityKey == null || identityKey!.trim().isEmpty)))) {
      throw ArgumentError(
        'Secure storage and a stable host account identityKey are required for persisted verified sessions.',
      );
    }
    if (!RegExp(r'^chat_(test|live)_[a-z0-9]+$').hasMatch(publicChatAppId) ||
        !['android', 'ios'].contains(platform) ||
        baseUrl.userInfo.isNotEmpty ||
        baseUrl.host.isEmpty ||
        baseUrl.hasQuery ||
        baseUrl.hasFragment ||
        !['', '/'].contains(baseUrl.path) ||
        (baseUrl.scheme != 'https' &&
            !(baseUrl.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(baseUrl.host)))) {
      throw ArgumentError(
        'Use a public Chat App ID and HTTPS API origin (HTTP only on loopback).',
      );
    }
  }
  final String publicChatAppId, platform;
  final Uri baseUrl;
  final ChatIdentityTokenProvider? identityTokenProvider;
  final ChatTransport? transport;
  final ChatAttachmentTransport? attachmentTransport;
  final ChatAttachmentPersistencePolicy attachmentPersistence;
  final ChatAttachmentFileStore attachmentFileStore;

  /// Exact trusted storage origins. Empty disables attachment transfers.
  final Set<Uri> attachmentStorageOrigins;
  final ChatStorageAdapter? storage;
  final ChatSendQueueOptions sendQueueOptions;
  final bool persistSendQueue;

  /// Stable, opaque authenticated host account ID; never an email or token.
  final String? identityKey;

  /// Explicit consent to create an identity if this partition has never been stored.
  final bool allowNewAnonymousIdentity;

  /// Explicit recovery for lost proof. A usable access token is reset on the server first.
  final bool recoverLostAnonymousIdentity;

  /// Default unverified context for conversations created without their own.
  /// Validated when the options are created.
  final ChatCreateConversationContext? initialContext;
}

/// Starts sign-in without waiting, allowing early cold-start tap listeners.
/// Await client.ready and dispose the client if initialization fails.
ProtodeskChatClient startChat(ChatClientOptions options) =>
    ProtodeskChatClient._(options);

Future<ProtodeskChatClient> initializeChat(ChatClientOptions options) async {
  final client = startChat(options);
  try {
    await client.ready;
    return client;
  } catch (_) {
    await client.dispose();
    rethrow;
  }
}

/// Native client with optional device-secure credentials and history checkpoints.
final class ProtodeskChatClient {
  ProtodeskChatClient._(this.options)
    : _vault = options.storage == null
          ? null
          : SessionVault(
              options.storage!,
              options.baseUrl.origin,
              options.publicChatAppId,
            ),
      _identityKey = options.identityTokenProvider == null
          ? null
          : options.identityKey,
      _transport = options.transport ?? NativeChatTransport() {
    ready = _signIn(options.identityTokenProvider, _identityEpoch);
  }
  final ChatClientOptions options;
  final ChatTransport _transport;
  ChatSendQueue? _sendQueue;
  bool _queueActive = true, _disposing = false;
  ChatSendQueue get sendQueue {
    if (_sendQueue == null) {
      final epoch = _identityEpoch;
      final key = _vault == null ? null : '${_vault.key(_identityKey)}.outbox';
      final owner = _historyOwner;
      final queueEpoch = _record?['queueEpoch'];
      void checkQueueWrite() {
        if (epoch != _identityEpoch || _state == ChatClientState.disposed) {
          throw const ProtodeskChatException('chat.operation_cancelled');
        }
      }

      final queue = ChatSendQueue(
        persist: !options.persistSendQueue
            ? null
            : (value) async {
                checkQueueWrite();
                await _vault!.write(key!, {
                  ...value,
                  'owner': owner,
                  'queueEpoch': queueEpoch,
                }, checkQueueWrite);
              },
        options: options.sendQueueOptions,
        isReady: () => !_disposing && _state == ChatClientState.ready,
        newId: newOperationId,
        send: (conversation, id, text) => sendMessage(
          conversationId: conversation,
          clientMessageId: id,
          text: text,
        ),
      );
      queue.setActive(_queueActive);
      _sendQueue = queue;
    }
    return _sendQueue!;
  }

  final SessionVault? _vault;
  String? _identityKey;
  Map<String, dynamic>? _record;
  final _exchanges = <Future<Object?>>{};
  final _issuedTokens = <String, int>{};
  bool _recoveryConsumed = false;
  bool _merging = false;
  int _activeMutations = 0;
  Map<String, dynamic>? _mergeMarker;
  ChatIdentityMergeOutcome? get identityMergeOutcome =>
      switch (_record?['mergeOutcome']) {
        'confirmed' => ChatIdentityMergeOutcome.confirmed,
        'recoveredUnconfirmed' => ChatIdentityMergeOutcome.recoveredUnconfirmed,
        _ => null,
      };
  String _mergeTarget(String identityKey) =>
      _vault?.key(identityKey) ?? identityKey;

  /// Completes initial sign-in. For presentation use [waitUntilReady], which
  /// also rejects disposal or identity replacement while waiting.
  late final Future<void> ready;
  void Function(ChatClientState)? _lifecycleStateListener;
  late final _lifecycle = ChatLifecycle((listener) {
    _lifecycleStateListener = listener;
  });

  /// Lazy broadcast activity stream. No replay: subscribe before starting an
  /// operation to observe it. Use ready/state for an existing session snapshot.
  Stream<ChatLifecycleEvent> get sdkLifecycleEvents => _lifecycle.events;

  /// Await initial sign-in and validate the current session. For subsequent
  /// identity changes, await identify/continueAnonymously before calling this.
  Future<void> waitUntilReady() async {
    final epoch = _identityEpoch;
    await ready;
    _check(epoch);
    if (_state != ChatClientState.ready) {
      throw const ProtodeskChatException('chat.session_not_ready');
    }
  }

  /// Track a mounted custom chat surface. Call the returned idempotent closure
  /// when removed. ChatScreen handles this automatically. This is not visibility
  /// or read-receipt evidence and does not connect, log out, or dispose the client.
  void Function() trackChatPresentation() {
    _check(_identityEpoch);
    _lifecycle.emit(ChatLifecycleEvent.chatOpened);
    var closed = false;
    return () {
      if (closed) return;
      closed = true;
      _lifecycle.emit(ChatLifecycleEvent.chatClosed);
    };
  }

  final _states = StreamController<ChatClientState>.broadcast();
  final _connections = StreamController<ChatConnectionState>.broadcast();
  final _events = StreamController<ChatServerEvent>.broadcast();
  final _errors = StreamController<ProtodeskChatException>.broadcast();
  // Consumers reload authoritative history on ready, replay gaps and events.
  final _changes = StreamController<void>.broadcast();
  ChatClientState _state = ChatClientState.initializing;
  ChatConnectionState _connectionState = ChatConnectionState.disconnected;
  _Session? _session;
  Future<_Session>? _refreshing;
  ChatAttachments? _attachments;
  Future<void> _attachmentCleanup = Future.value();
  String get _attachmentKey => '${_vault!.key(_identityKey)}.attachments';
  bool get _persistAttachments =>
      options.attachmentPersistence ==
      ChatAttachmentPersistencePolicy.managedPrivateCopy;
  ChatAttachments get attachments {
    if (_attachments != null) return _attachments!;
    AttachmentPersistence? persistence;
    if (_persistAttachments) {
      final vault = _vault!, key = _attachmentKey, epoch = _identityEpoch;
      final owner = _historyOwner, queueEpoch = _record?['queueEpoch'];
      if (queueEpoch == null)
        throw const ProtodeskChatException(
          'sdk.attachment_persistence_unavailable',
        );
      final partition = sha256
          .convert(utf8.encode('$key:$owner:$queueEpoch'))
          .toString();
      void check() {
        if (epoch != _identityEpoch || _state == ChatClientState.disposed)
          throw const ProtodeskChatException('chat.operation_cancelled');
      }

      persistence = AttachmentPersistence(
        files: options.attachmentFileStore,
        scope: vault.scope,
        partition: partition,
        load: () async {
          final value = await vault.read(key, check);
          if (value != null &&
              (value['owner'] != owner || value['queueEpoch'] != queueEpoch)) {
            await vault.delete(key);
            return null;
          }
          return value;
        },
        save: (value) => vault.write(key, {
          ...value,
          'owner': owner,
          'queueEpoch': queueEpoch,
        }, check),
        remove: () => vault.delete(key),
      );
    }
    return _attachments = ChatAttachments(
      request: (method, path, body, key) =>
          _authorized(method, path, body: body, idempotencyKey: key),
      available: () =>
          !_disposing &&
          _state == ChatClientState.ready &&
          _connectionState == ChatConnectionState.connected,
      operationId: newOperationId,
      storageOrigins: options.attachmentStorageOrigins,
      transport: options.attachmentTransport,
      persistence: persistence,
      send: (conversation, id, text, ids) => sendMessage(
        conversationId: conversation,
        clientMessageId: id,
        text: text,
        attachmentIds: ids,
      ),
    );
  }

  Future<void> _restoreAttachments(int epoch) async {
    await _attachmentCleanup;
    if (!_persistAttachments) {
      // Opt-out removes old metadata and any native bodies for this app scope.
      if (_vault != null) {
        final previous = await _vault.read(_attachmentKey, () => _check(epoch));
        final available = await options.attachmentFileStore.isAvailable();
        if (previous != null && !available)
          throw const ProtodeskChatException(
            'sdk.attachment_persistence_unavailable',
          );
        if (available) {
          final empty = sha256.convert(utf8.encode('disabled')).toString();
          await options.attachmentFileStore.retain(_vault.scope, empty, {});
        }
        await _vault.delete(_attachmentKey);
      }
      return;
    }
    if (_record?['queueEpoch'] == null)
      await _save({...?_record, 'queueEpoch': newOperationId()}, epoch);
    await _attachments?.close();
    _attachments = null;
    await attachments.restore();
    _check(epoch);
  }

  int _identityEpoch = 0, _connectionEpoch = 0;
  ChatSocket? _socket;
  Future<void>? _connectionTask;
  Timer? _delayTimer;
  Completer<void>? _delayDone;
  String? _cursor;
  final _seen = <String>{};
  Map<String, dynamic>? _history;
  String? _watchedConversation;
  bool _checkpointLoaded = false;

  /// Last committed authoritative recent-history window. Older pages remain
  /// available through listConversations/listMessages and are not cached.
  ChatPage<ChatConversation>? get cachedConversations => _history == null
      ? null
      : _conversationPage(_history!['conversations'] as Map<String, dynamic>);
  String? get cachedConversationId => _history?['conversationId'] as String?;

  ChatPage<ChatMessage>? cachedMessages(String conversationId) =>
      _history?['conversationId'] == conversationId &&
          _history?['messages'] != null
      ? _messagePage(_history!['messages'] as Map<String, dynamic>)
      : null;

  ChatPage<ChatConversation> _conversationPage(Map<String, dynamic> json) =>
      ChatPage(
        List.unmodifiable(
          (json['data'] as List).map((v) => ChatConversation.fromJson(v)),
        ),
        hasMore: json['hasMore'] as bool,
        nextCursor: json['nextCursor'] as String?,
      );
  ChatPage<ChatMessage> _messagePage(Map<String, dynamic> json) => ChatPage(
    List.unmodifiable(
      (json['data'] as List).map((v) => ChatMessage.fromJson(v)),
    ),
    hasMore: json['hasMore'] as bool,
    nextCursor: json['nextCursor'] as String?,
  );

  String get _checkpointKey => '${_vault!.key(_identityKey)}.history';
  Object? get _historyOwner => _identityKey ?? _record?['installationId'];

  void _checkConnection(int generation, int identity) {
    if (!_active(generation, identity)) {
      throw const ProtodeskChatException('chat.operation_cancelled');
    }
  }

  Future<void> _restoreCheckpoint(int generation, int identity) async {
    if (_checkpointLoaded) return;
    final value = await _vault?.read(
      _checkpointKey,
      () => _checkConnection(generation, identity),
    );
    _checkConnection(generation, identity);
    if (value != null &&
        value['owner'] == _historyOwner &&
        value['history'] != null) {
      try {
        final history = value['history'] as Map<String, dynamic>;
        _conversationPage(history['conversations'] as Map<String, dynamic>);
        if (history['messages'] != null)
          _messagePage(history['messages'] as Map<String, dynamic>);
        final cursor = value['cursor'] as String?;
        final seen = (value['seen'] as List).cast<String>();
        final watched = history['conversationId'] as String?;
        _history = history;
        _cursor = cursor;
        _seen.addAll(seen.take(256));
        _watchedConversation ??= watched;
      } catch (_) {
        throw const ProtodeskChatException('chat.storage_corrupt');
      }
    }
    _checkpointLoaded = true;
  }

  Future<void> _commitHistory(
    Map<String, dynamic>? history,
    String? cursor,
    Set<String> seen,
    int generation,
    int identity,
  ) async {
    _checkConnection(generation, identity);
    // JSON round trip detaches transport-owned collections before persistence.
    final value = jsonDecode(
      jsonEncode({
        'owner': _historyOwner,
        'history': history,
        'cursor': cursor,
        'seen': seen.toList(),
      }),
    ) as Map<String, dynamic>;
    if (utf8.encode(jsonEncode(value)).length > 1048576) {
      throw const ProtodeskChatException('chat.history_checkpoint_too_large');
    }
    await _vault?.write(
      _checkpointKey,
      value,
      () => _checkConnection(generation, identity),
    );
    _checkConnection(generation, identity);
    _history = value['history'] as Map<String, dynamic>?;
    _cursor = cursor;
    _seen
      ..clear()
      ..addAll(seen);
  }

  Future<void> _reconcile(
    String? cursor,
    Set<String> seen,
    int generation,
    int identity,
  ) async {
    final conversations = await _authorized('GET', '/v1/chat/conversations');
    _checkConnection(generation, identity);
    _conversationPage(conversations); // Validate before committing a boundary.
    final watched = _watchedConversation;
    Map<String, dynamic>? messages;
    if (watched != null) {
      try {
        messages = await _authorized(
          'GET',
          '/v1/chat/conversations/${Uri.encodeComponent(watched)}/messages',
        );
        _messagePage(messages);
      } on ProtodeskChatException catch (error) {
        if (error.status != 404) rethrow;
        // Revoked/deleted conversations must not retain cached message bodies.
      }
    }
    await _commitHistory(
      {
        'conversations': conversations,
        'conversationId': watched,
        'messages': messages,
      },
      cursor,
      seen,
      generation,
      identity,
    );
    if (messages != null) {
      for (final row in messages['data'] as List) {
        _sendQueue?.acknowledge(ChatMessage.fromJson(row));
      }
    }
  }

  Future<void> _applyEvent(
    ChatServerEvent event,
    String cursor,
    Set<String> seen,
    int generation,
    int identity,
  ) async {
    Map<String, dynamic> next;
    if (event.type == 'conversation.read') {
      String conversationId;
      try {
        if (event.data['schemaVersion'] != 1) throw const FormatException();
        final read = event.data['readState'] as Map;
        conversationId = read['conversationId'] as String;
        if (conversationId.isEmpty ||
            (read['throughMessageId'] as String).isEmpty ||
            (read['unreadCount'] as int) < 0)
          throw const FormatException();
        DateTime.parse(read['readAt'] as String);
      } catch (_) {
        throw const ProtodeskChatException('chat.invalid_event');
      }
      next = jsonDecode(jsonEncode(_history)) as Map<String, dynamic>;
      final rows = next['conversations']['data'] as List;
      final index = rows.indexWhere((v) => v['id'] == conversationId);
      if (index >= 0) {
        try {
          final current = await _authorized(
            'GET',
            '/v1/chat/conversations/${Uri.encodeComponent(conversationId)}',
          );
          ChatConversation.fromJson(current);
          rows[index] = current;
        } on ProtodeskChatException catch (error) {
          if (error.status != 404) rethrow;
          rows.removeAt(index);
          if (next['conversationId'] == conversationId) next['messages'] = null;
        }
      }
    } else {
      next = reduceHistory(_history!, event);
      // Validate before issuing any seed request. A newly selected window needs
      // one authoritative seed; subsequent events reduce without network I/O.
      if (_history?['conversationId'] != _watchedConversation) {
        await _reconcile(_cursor, {..._seen}, generation, identity);
        next = reduceHistory(_history!, event);
      }
    }
    await _commitHistory(next, cursor, seen, generation, identity);
  }

  void _clearHistory() {
    _history = null;
    _watchedConversation = null;
    _checkpointLoaded = false;
  }

  ChatClientState get state => _state;

  /// The signed-in identity kind, or null while no session is ready.
  ChatIdentityKind? get identityKind => _state != ChatClientState.ready
      ? null
      : switch (_record?['kind']) {
          'anonymous' => ChatIdentityKind.anonymous,
          'verified' => ChatIdentityKind.verified,
          _ => null,
        };
  ChatConnectionState get connectionState => _connectionState;
  Stream<ChatClientState> get states => _states.stream;
  Stream<ChatConnectionState> get connectionStates => _connections.stream;
  Stream<ChatServerEvent> get events => _events.stream;
  Stream<ProtodeskChatException> get errors => _errors.stream;
  Stream<void> get changes => _changes.stream;

  /// UUID v4, accepted as both clientMessageId and Idempotency-Key.
  static String newOperationId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void _check(int epoch) {
    if (_disposing ||
        _state == ChatClientState.disposed ||
        epoch != _identityEpoch) {
      throw const ProtodeskChatException('chat.operation_cancelled');
    }
  }

  void _setState(ChatClientState value) {
    final previous = _state;
    _state = value;
    if (value != ChatClientState.ready) {
      _clearTyping();
      _typingEnabled = false;
      _sendQueue?.clear();
      if (value == ChatClientState.failed &&
          previous == ChatClientState.ready &&
          _attachments != null) {
        _attachmentCleanup = _attachments!.purge();
        unawaited(
          _attachmentCleanup.catchError((Object error) {
            if (!_errors.isClosed)
              _errors.add(
                const ProtodeskChatException('sdk.attachment_cleanup_failed'),
              );
          }),
        );
      } else {
        _attachments?.clear();
      }
    }
    _lifecycleStateListener?.call(value);
    _states.add(value);
  }

  void _setConnection(ChatConnectionState value) {
    if (value != ChatConnectionState.connected) _clearTyping();
    _connectionState = value;
    _attachments?.setActive(
      value == ChatConnectionState.connected && _queueActive,
    );
    _connections.add(value);
  }

  Map<String, dynamic> get _sdk => {
    'name': 'flutter',
    'version': '0.1.0-dev.1',
    'platform': options.platform,
  };

  Future<void> _save(Map<String, dynamic> value, int epoch) async {
    _check(epoch);
    final vault = _vault;
    if (vault != null)
      await vault.write(vault.key(_identityKey), value, () => _check(epoch));
    _check(epoch);
    _record = value;
  }

  Future<void> _loadRecord(int epoch) async {
    final vault = _vault;
    if (vault == null) return;
    try {
      _record = await vault.read(vault.key(_identityKey), () => _check(epoch));
    } on ProtodeskChatException catch (error) {
      if (_identityKey == null &&
          options.recoverLostAnonymousIdentity &&
          !_recoveryConsumed &&
          error.code == 'chat.storage_corrupt') {
        _record = null;
      } else {
        rethrow;
      }
    }
  }

  Future<Map<String, dynamic>> _exchangeSession(
    String path,
    int epoch, {
    required Map<String, dynamic> body,
    String? accessToken,
  }) {
    final exchange = () async {
      final response = await _request(
        'POST',
        path,
        body: body,
        accessToken: accessToken,
      );
      final token = response['accessToken'] as String;
      if (epoch != _identityEpoch || _state == ChatClientState.disposed) {
        await _request(
          'DELETE',
          '/v1/chat/sessions/current',
          accessToken: token,
        );
        _check(epoch);
      }
      _issuedTokens[token] = epoch;
      return response;
    }();
    final settled = exchange.then<Object?>(
      (_) => null,
      onError: (Object error) => error,
    );
    _exchanges.add(settled);
    unawaited(
      settled.then((_) {
        _exchanges.remove(settled);
      }),
    );
    return exchange;
  }

  Future<Map<String, dynamic>> _anonymousExchange(int epoch) async {
    var record = _record;
    if (record?['mergePending'] == true || record?['mergeComplete'] == true) {
      throw const ProtodeskChatException(
        'chat.identity_merge_recovery_required',
      );
    }
    final recovering =
        options.recoverLostAnonymousIdentity && !_recoveryConsumed;
    _recoveryConsumed = true;
    if (recovering && record != null && record['reset'] != true) {
      var reset = false;
      _Session? old;
      try {
        if (record['session'] is Map)
          old = _Session.fromJson(
            Map<String, dynamic>.from(record['session'] as Map),
          );
      } on FormatException {
        /* Explicit recovery of malformed saved credentials. */
      } on TypeError {
        /* Explicit recovery of malformed saved credentials. */
      }
      if (old != null && old.expires.isAfter(DateTime.now())) {
        try {
          await _request(
            'DELETE',
            '/v1/chat/anonymous-identity',
            accessToken: old.access,
          );
          _check(epoch);
          await _save({'kind': 'anonymous', 'reset': true}, epoch);
          record = _record;
          reset = true;
        } on ProtodeskChatException catch (error) {
          if (error.status != 401) rethrow;
        }
      }
      if (!reset) {
        if (record?['secret'] is String &&
            record?['generation'] is int &&
            (record!['generation'] as int) > 0) {
          // A revoked access token alone does not prove the identity was lost.
          // Probe via the ordinary durable resume path. Never abandon valid proof.
          try {
            await _anonymousExchange(epoch);
          } on ProtodeskChatException catch (error) {
            if (error.code != 'chat.anonymous_resume_invalid' ||
                error.status != 401)
              rethrow;
            record = null;
          }
          if (record != null)
            throw const ProtodeskChatException('chat.anonymous_reset_required');
        } else {
          record = null;
        }
      }
    }
    if (record == null || record['reset'] == true) {
      if (_vault != null &&
          record == null &&
          !options.allowNewAnonymousIdentity &&
          !recovering) {
        throw const ProtodeskChatException('chat.anonymous_identity_missing');
      }
      record = {'kind': 'anonymous', 'installationId': newOperationId()};
      // Persist the installation BEFORE creation. A lost first response must
      // surface recovery-required, never retry the old lookup ID without proof.
      await _save(record, epoch);
    } else {
      if (record['kind'] != 'anonymous' ||
          record['installationId'] is! String ||
          record['secret'] is! String ||
          (record['secret'] as String).isEmpty ||
          record['generation'] is! int ||
          (record['generation'] as int) < 1) {
        throw const ProtodeskChatException('chat.anonymous_recovery_required');
      }
    }
    final response = await _exchangeSession(
      '/v1/chat/sessions/anonymous',
      epoch,
      body: {
        'publicChatAppId': options.publicChatAppId,
        'installationId': record['installationId'],
        'sdk': _sdk,
        if (record['secret'] != null) 'resumeSecret': record['secret'],
        if (record['generation'] != null)
          'resumeSecretGeneration': record['generation'],
      },
    );
    _check(epoch);
    final proof = response['anonymousIdentity'];
    if (proof is! Map) {
      if (_vault != null)
        throw const ProtodeskChatException('chat.invalid_response');
      return response;
    }
    final generation = proof['generation'];
    final oldGeneration = record['generation'] as int? ?? 0;
    final secret = proof['resumeSecret'] ?? record['secret'];
    if (generation is! int ||
        generation < 1 ||
        generation < oldGeneration ||
        secret is! String ||
        secret.isEmpty ||
        proof['acknowledgementRequired'] is! bool ||
        (generation > oldGeneration && proof['resumeSecret'] == null) ||
        (generation == oldGeneration &&
            record['secret'] != null &&
            secret != record['secret'])) {
      throw const ProtodeskChatException('chat.anonymous_generation_invalid');
    }
    final session = _Session.fromJson(response);
    final updated = {
      ...record,
      'secret': secret,
      'generation': generation,
      'acknowledgementRequired': proof['acknowledgementRequired'],
      'session': session.toJson(),
      'refreshPending': false,
    };
    await _save(updated, epoch);
    if (proof['acknowledgementRequired'] == true) {
      await _request(
        'POST',
        '/v1/chat/anonymous-identity/resume-secret/acknowledge',
        accessToken: session.access,
        body: {'generation': generation},
      );
      _check(epoch);
      await _save({...updated, 'acknowledgementRequired': false}, epoch);
    }
    return response;
  }

  String get _outboxKey => '${_vault!.key(_identityKey)}.outbox';

  Future<void> _restoreSendQueue(int epoch) async {
    if (!options.persistSendQueue) {
      // Disabling persistence also removes a previously retained outbox.
      await _vault?.delete(_outboxKey);
      return;
    }
    if (_record?['queueEpoch'] == null) {
      await _save({...?_record, 'queueEpoch': newOperationId()}, epoch);
    }
    await _sendQueue?.close();
    _sendQueue = null;
    _queueActive = false;
    final value = await _vault!.read(_outboxKey, () => _check(epoch));
    _check(epoch);
    if (value != null &&
        (value['owner'] != _historyOwner ||
            value['queueEpoch'] != _record?['queueEpoch'])) {
      await _vault.delete(_outboxKey);
      return;
    }
    await sendQueue.restore(value);
    _check(epoch);
  }

  Future<void> _signIn(
    ChatIdentityTokenProvider? provider,
    int epoch, {
    Map<String, dynamic>? mergedResponse,
    bool forceExchange = false,
  }) async {
    try {
      await _loadRecord(epoch);
      _check(epoch);
      if (provider == null) {
        final response = await _anonymousExchange(epoch);
        _check(epoch);
        _session = _Session.fromJson(response);
      } else {
        final marker = _vault == null
            ? _mergeMarker
            : await _vault.read(_vault.key(null), () => _check(epoch));
        _check(epoch);
        final recoveringMerge =
            marker?['mergePending'] == true &&
            _identityKey != null &&
            marker?['mergeTarget'] == _mergeTarget(_identityKey!);
        if (recoveringMerge) _mergeMarker = marker;
        if (_record != null &&
            (_record!['kind'] != 'verified' ||
                (_record!['session'] != null && _record!['session'] is! Map))) {
          throw const ProtodeskChatException('chat.storage_corrupt');
        }
        final stored = _record?['session'];
        if (stored is Map &&
            !recoveringMerge &&
            !forceExchange &&
            mergedResponse == null) {
          final previous = _Session.fromJson(Map<String, dynamic>.from(stored));
          // Refresh on every restored verified session, even if access remains
          // unexpired: revoked sessions must not expose a restored ready state.
          if (previous.refreshExpires == null ||
              previous.refreshExpires!.isAfter(DateTime.now())) {
            _session = await _refresh(previous, epoch);
            _check(epoch);
            await _restoreSendQueue(epoch);
            await _restoreAttachments(epoch);
            _setState(ChatClientState.ready);
            return;
          }
        }
        final Map<String, dynamic> response;
        if (mergedResponse != null) {
          response = mergedResponse;
        } else {
          final token = await provider();
          _check(epoch);
          response = await _exchangeSession(
            '/v1/chat/sessions',
            epoch,
            body: {'identityToken': token, 'sdk': _sdk},
          );
        }
        _check(epoch);
        final session = _Session.fromJson(response);
        await _save({
          'kind': 'verified',
          'session': session.toJson(),
          if (mergedResponse == null &&
              !recoveringMerge &&
              _record?['mergeOutcome'] != null)
            'mergeOutcome': _record!['mergeOutcome'],
          if (mergedResponse != null || recoveringMerge)
            'mergeOutcome': mergedResponse != null
                ? 'confirmed'
                : 'recoveredUnconfirmed',
          if (_record?['queueEpoch'] != null)
            'queueEpoch': _record!['queueEpoch'],
        }, epoch);
        _session = session;
      }
      await _restoreSendQueue(epoch);
      await _restoreAttachments(epoch);
      if (provider != null &&
          _identityKey != null &&
          _mergeMarker?['mergePending'] == true &&
          _mergeMarker?['mergeTarget'] == _mergeTarget(_identityKey!)) {
        final tombstone = <String, dynamic>{
          // An uncertain recovery must not erase potentially still-valid proof.
          if (identityMergeOutcome ==
              ChatIdentityMergeOutcome.recoveredUnconfirmed)
            ...?_mergeMarker,
          'kind': 'anonymous',
          'session': null,
          'mergePending': false,
          'mergeComplete': true,
          'mergeTarget': _mergeTarget(_identityKey!),
        };
        if (_vault != null) {
          final key = _vault.key(null);
          await _vault.delete('$key.history');
          await _vault.delete('$key.outbox');
          await _vault.delete('$key.attachments');
          if (identityMergeOutcome == ChatIdentityMergeOutcome.confirmed) {
            final push = await _vault.read('$key.push', () => _check(epoch));
            if (push != null &&
                push['owner'] == _mergeMarker?['installationId']) {
              await _vault.write(_pushKey, {
                ...push,
                'owner': _historyOwner,
              }, () => _check(epoch));
            }
          }
          await _vault.delete('$key.push');
          await _vault.write(key, tombstone, () => _check(epoch));
        }
        _mergeMarker = tombstone;
      }
      _check(epoch);
      _issuedTokens.remove(_session?.access);
      _setState(ChatClientState.ready);
    } catch (error) {
      // Failed durable adoption must not leave an unowned issued session alive.
      final abandoned = _issuedTokens.entries
          .where((entry) => entry.value == epoch)
          .map((entry) => entry.key)
          .toList();
      for (final token in abandoned) {
        _issuedTokens.remove(token);
        try {
          await _request(
            'DELETE',
            '/v1/chat/sessions/current',
            accessToken: token,
          );
        } catch (_) {}
      }
      if (epoch == _identityEpoch && _state != ChatClientState.disposed)
        _setState(ChatClientState.failed);
      if (error is FormatException || error is TypeError)
        throw const ProtodeskChatException('chat.storage_corrupt');
      rethrow;
    }
  }

  void _requireMergeIdle() {
    if (_activeMutations != 0 ||
        _refreshing != null ||
        (_sendQueue?.messages.isNotEmpty ?? false) ||
        (_attachments?.hasPendingWork ?? false)) {
      throw const ProtodeskChatException('chat.identity_merge_pending_work');
    }
  }

  /// Explicitly transfer anonymous server history to the host's verified account.
  /// Pending sends/uploads must first finish or be explicitly discarded by the host.
  /// A lost response is never retried: recover with a fresh identity token instead.
  Future<ChatIdentityMergeOutcome> mergeAnonymousIdentity(
    ChatIdentityTokenProvider provider, {
    required String identityKey,
  }) async {
    if (identityKey.trim().isEmpty)
      throw ArgumentError('identityKey is required.');
    if (_merging)
      throw const ProtodeskChatException('chat.identity_merge_in_progress');
    if (_state != ChatClientState.ready || _record?['kind'] != 'anonymous') {
      throw const ProtodeskChatException('chat.anonymous_identity_required');
    }
    _requireMergeIdle();
    _merging = true;
    var epoch = _identityEpoch;
    _Session? previous;
    Map<String, dynamic>? previousRecord;
    var frozen = false, requested = false, markerAttempted = false;
    final reconnect = _connectionState != ChatConnectionState.disconnected;
    try {
      final bootstrap = await _authorized('GET', '/v1/chat/bootstrap');
      _check(epoch);
      if (bootstrap['capabilities'] is! Map ||
          bootstrap['capabilities']['identityMerge'] != true) {
        throw const ProtodeskChatException('chat.feature_unavailable');
      }
      previous = await _access(epoch);
      _check(epoch);
      _requireMergeIdle();
      previousRecord = Map<String, dynamic>.from(_record!);
      epoch = ++_identityEpoch;
      frozen = true;
      _session = null;
      _cursor = null;
      _seen.clear();
      _clearHistory();
      _setState(ChatClientState.initializing);
      await disconnect();
      await _sendQueue?.close();
      _sendQueue = null;
      await _attachments?.close();
      _attachments = null;
      _check(epoch);
      final token = await provider();
      _check(epoch);
      if (token.isEmpty)
        throw const ProtodeskChatException('chat.identity_token_invalid');
      final marker = {
        ...previousRecord,
        'session': null,
        'mergePending': true,
        'mergeTarget': _mergeTarget(identityKey),
      };
      markerAttempted = true;
      _mergeMarker = marker;
      await _save(marker, epoch);
      requested = true;
      final response = await _exchangeSession(
        '/v1/chat/identity/merge',
        epoch,
        accessToken: previous.access,
        body: {'identityToken': token, 'sdk': _sdk},
      );
      _check(epoch);
      _identityKey = identityKey;
      _record = null;
      await _signIn(provider, epoch, mergedResponse: response);
      if (reconnect) unawaited(connect());
      return ChatIdentityMergeOutcome.confirmed;
    } catch (error) {
      _check(epoch);
      final rejected =
          error is ProtodeskChatException &&
          ((error.status != null &&
                  [400, 403, 404, 409, 422, 429].contains(error.status)) ||
              (error.status == 401 &&
                  (error.code.startsWith('chat.identity_token_') ||
                      error.code == 'chat.session_expired')));
      if (frozen && (!requested || rejected)) {
        // No committed server merge: restore the original identity, not a new one.
        _identityKey = null;
        if (markerAttempted) {
          try {
            await _save(previousRecord!, epoch);
          } catch (_) {
            _session = null;
            _setState(ChatClientState.failed);
            rethrow;
          }
        }
        _record = previousRecord;
        _mergeMarker = null;
        _session = previous;
        await _restoreSendQueue(epoch);
        await _restoreAttachments(epoch);
        _check(epoch);
        _setState(ChatClientState.ready);
        if (reconnect) unawaited(connect());
      } else if (frozen) {
        _session = null;
        _setState(ChatClientState.failed);
        throw const ProtodeskChatException('chat.identity_merge_uncertain');
      }
      rethrow;
    } finally {
      _merging = false;
    }
  }

  /// Fresh verified exchange after an uncertain merge. Does not repeat the merge
  /// or claim that anonymous history was transferred. The provider must mint anew.
  Future<ChatIdentityMergeOutcome> recoverIdentityMerge(
    ChatIdentityTokenProvider provider, {
    required String identityKey,
  }) async {
    if (_merging)
      throw const ProtodeskChatException('chat.identity_merge_in_progress');
    if (identityKey.trim().isEmpty)
      throw ArgumentError('identityKey is required.');
    _requireMergeIdle();
    if (_state != ChatClientState.failed &&
        _state != ChatClientState.signedOut) {
      throw const ProtodeskChatException(
        'chat.identity_merge_recovery_required',
      );
    }
    _merging = true;
    try {
      var epoch = _identityEpoch;
      final marker = _vault == null
          ? _mergeMarker
          : await _vault.read(_vault.key(null), () => _check(epoch));
      _check(epoch);
      if (marker?['mergePending'] != true ||
          marker?['mergeTarget'] != _mergeTarget(identityKey)) {
        throw const ProtodeskChatException(
          'chat.identity_merge_recovery_required',
        );
      }
      epoch = ++_identityEpoch;
      _session = null;
      _cursor = null;
      _seen.clear();
      _clearHistory();
      _setState(ChatClientState.initializing);
      await disconnect();
      await _sendQueue?.close();
      _sendQueue = null;
      await _attachments?.close();
      _attachments = null;
      _check(epoch);
      _identityKey = identityKey;
      _record = null;
      _mergeMarker = marker;
      await _signIn(provider, epoch, forceExchange: true);
      return ChatIdentityMergeOutcome.recoveredUnconfirmed;
    } finally {
      _merging = false;
    }
  }

  /// Account switching first clears local state and revokes the previous session.
  /// No anonymous history merge is implied by identifying.
  Future<void> identify(
    ChatIdentityTokenProvider provider, {
    String? identityKey,
  }) async {
    if (_vault != null && (identityKey == null || identityKey.trim().isEmpty)) {
      throw ArgumentError(
        'identityKey must identify the authenticated host account.',
      );
    }
    final revocation = logout();
    final epoch = _identityEpoch;
    await revocation;
    _check(epoch);
    _identityKey = identityKey;
    _record = null;
    _setState(ChatClientState.initializing);
    await _signIn(provider, epoch);
  }

  Future<void> continueAnonymously() async {
    final revocation = logout();
    final epoch = _identityEpoch;
    await revocation;
    _check(epoch);
    if (_record?['kind'] == 'verified') _record = null;
    _identityKey = null;
    final marker = _vault == null
        ? _mergeMarker
        : await _vault.read(_vault.key(null), () => _check(epoch));
    if (marker?['mergeComplete'] == true) {
      await _save({'kind': 'anonymous', 'reset': true}, epoch);
      _mergeMarker = null;
    }
    _setState(ChatClientState.initializing);
    await _signIn(null, epoch);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? accessToken,
    String? idempotencyKey,
    Map<String, String> query = const {},
  }) async {
    final uri = options.baseUrl
        .resolve(path)
        .replace(queryParameters: query.isEmpty ? null : query);
    final response = await _transport.request(method, uri, {
      'Accept': 'application/json',
      if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    }, body);
    if (response.status < 200 || response.status >= 300) {
      final error = response.body['error'];
      // Only stable machine codes are exposed; never arbitrary server text.
      final rawCode = error is Map ? error['code'] : null;
      final code =
          rawCode is String &&
              RegExp(r'^[a-z][a-z0-9_.]{0,100}$').hasMatch(rawCode)
          ? rawCode
          : 'chat.request_failed';
      throw ProtodeskChatException(
        code,
        status: response.status,
        retryable: response.status == 429 || response.status >= 500,
        retryAfter: response.retryAfter,
      );
    }
    return response.body;
  }

  Future<_Session> _refresh(_Session previous, int epoch) async {
    try {
      // Durable write-ahead fencing: after a crash or uncertain response, this
      // token is never replayed from disk. Anonymous proof is kept separately.
      await _save({
        ...?_record,
        'session': null,
        'refreshPending': true,
      }, epoch);
      final data = await _request(
        'POST',
        '/v1/chat/sessions/refresh',
        body: {'refreshToken': previous.refresh},
      );
      _check(epoch);
      final next = _Session.fromJson(data);
      await _save({
        ...?_record,
        'session': next.toJson(),
        'refreshPending': false,
      }, epoch);
      _session = next;
      return next;
    } catch (_) {
      // An ambiguous refresh may have consumed its token. Never retry it.
      if (epoch == _identityEpoch && _state != ChatClientState.disposed) {
        _session = null;
        _setState(ChatClientState.failed);
        await disconnect();
      }
      rethrow;
    }
  }

  Future<_Session> _access(
    int epoch, {
    bool force = false,
    _Session? rejected,
  }) async {
    _check(epoch);
    final current = _session;
    if (current == null)
      throw const ProtodeskChatException('chat.session_required');
    if (rejected != null && !identical(current, rejected)) return current;
    if (!force &&
        current.expires.isAfter(
          DateTime.now().add(const Duration(seconds: 30)),
        ))
      return current;
    final pending = _refreshing;
    if (pending != null) return pending;
    final future = _refresh(current, epoch);
    _refreshing = future;
    try {
      return await future;
    } finally {
      if (identical(_refreshing, future)) _refreshing = null;
    }
  }

  Future<Map<String, dynamic>> _authorized(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? idempotencyKey,
    String? cursor,
    Map<String, String> query = const {},
  }) async {
    final mutation = method != 'GET';
    if (mutation) _activeMutations++;
    try {
      return await _authorizedRequest(
        method,
        path,
        body: body,
        idempotencyKey: idempotencyKey,
        query: {...query, 'cursor': ?cursor},
      );
    } finally {
      if (mutation) _activeMutations--;
    }
  }

  Future<Map<String, dynamic>> _authorizedRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? idempotencyKey,
    Map<String, String> query = const {},
  }) async {
    final epoch = _identityEpoch;
    var session = await _access(epoch);
    _check(epoch);
    try {
      final result = await _request(
        method,
        path,
        body: body,
        accessToken: session.access,
        idempotencyKey: idempotencyKey,
        query: query,
      );
      _check(epoch);
      return result;
    } on ProtodeskChatException catch (error) {
      _check(epoch);
      if (error.status != 401) rethrow;
      session = await _access(epoch, force: true, rejected: session);
      _check(epoch);
      final result = await _request(
        method,
        path,
        body: body,
        accessToken: session.access,
        idempotencyKey: idempotencyKey,
        query: query,
      );
      _check(epoch);
      return result;
    }
  }

  /// May be created during initial sign-in to accept one cold-start tap.
  /// Dispose and recreate after an identity transition; it never follows accounts.
  ChatPushNavigation createPushNavigation({
    required bool Function(ChatConversation) onNavigate,
    Duration pendingLifetime = const Duration(minutes: 2),
  }) {
    final epoch = _identityEpoch;
    _check(epoch);
    bool current() =>
        !_disposing &&
        _state != ChatClientState.disposed &&
        epoch == _identityEpoch;
    return ChatPushNavigation(
      publicChatAppId: options.publicChatAppId,
      isCurrent: current,
      isReady: () => _state == ChatClientState.ready,
      states: states,
      pendingLifetime: pendingLifetime,
      onNavigate: (conversation) {
        final accepted = onNavigate(conversation);
        if (accepted && current() && _state == ChatClientState.ready) {
          _lifecycle.emit(ChatLifecycleEvent.pushOpened);
        }
        return accepted;
      },
      resolve: (id) async {
        _check(epoch);
        final result = await _authorized(
          'GET',
          '/v1/chat/conversations/${Uri.encodeComponent(id)}',
        );
        _check(epoch);
        return ChatConversation.fromJson(result);
      },
      reportOpen: (id) async {
        _check(epoch);
        await _authorized(
          'POST',
          '/v1/chat/notifications/${Uri.encodeComponent(id)}/open',
          body: {},
        );
        _check(epoch);
      },
    );
  }

  String get _pushKey => '${_vault!.key(_identityKey)}.push';

  ChatPushTargets? _pushTargets;
  int? _pushTargetsEpoch;

  /// Obtain once per identity and capture in provider token callbacks.
  /// Handles are invalidated when the client advances its identity epoch.
  ChatPushTargets createPushTargets() {
    final epoch = _identityEpoch;
    void check() {
      _check(epoch);
      if (_state != ChatClientState.ready) {
        throw const ProtodeskChatException('chat.session_required');
      }
    }

    check();
    if (_pushTargetsEpoch == epoch && _pushTargets != null)
      return _pushTargets!;
    _pushTargetsEpoch = epoch;
    final vault = _vault;
    final key = vault == null ? null : _pushKey;
    final owner = _historyOwner;
    return _pushTargets = ChatPushTargets(
      check: check,
      newId: newOperationId,
      platform: options.platform,
      loadTargetId: () async {
        if (vault == null) return null;
        final data = await vault.read(key!, check);
        check();
        if (data == null || data['owner'] != owner) return null;
        final id = data['targetId'];
        if (id is! String || id.isEmpty || id.length > 128) {
          throw const ProtodeskChatException('chat.storage_corrupt');
        }
        return id;
      },
      saveTargetId: (id) async {
        if (vault == null) return;
        check();
        if (id == null) {
          await vault.delete(key!);
        } else {
          await vault.write(key!, {'owner': owner, 'targetId': id}, check);
        }
        check();
      },
      request: (method, path, body, key) {
        check();
        return _authorized(method, path, body: body, idempotencyKey: key);
      },
    );
  }

  /// Explicit authenticated snapshot. May refresh the session; never registers
  /// push, requests permissions, or reads/writes storage for diagnostic purposes.
  /// Native file availability is probed only when explicitly requested.
  Future<ChatSetupReport> inspectCapabilities({
    ChatHostChecks host = const ChatHostChecks(),
    bool probeAttachmentStore = false,
  }) async {
    final epoch = _identityEpoch;
    final setup = validateChatSetup(
      publicChatAppId: options.publicChatAppId,
      apiOrigin: options.baseUrl.toString(),
      platform: options.platform,
      verified: _record?['kind'] == 'verified',
      hasIdentityKey: _identityKey?.trim().isNotEmpty == true,
      storageConfigured: options.storage != null,
      storageIsSecure: options.storage?.isPlatformSecure == true,
      persistSendQueue: options.persistSendQueue,
      persistAttachments:
          options.attachmentPersistence ==
          ChatAttachmentPersistencePolicy.managedPrivateCopy,
      attachmentOrigins: options.attachmentStorageOrigins.map(
        (uri) => uri.toString(),
      ),
      host: host,
    );
    Map<Object?, Object?>? server;
    bool? fileStore;
    try {
      final data = await _authorized(
        'GET',
        '/v1/chat/bootstrap',
      ).timeout(const Duration(seconds: 10));
      if (data['capabilities'] is Map)
        server = Map<Object?, Object?>.from(data['capabilities']);
    } catch (_) {
      /* Never export transport errors or response bodies. */
    }
    if (probeAttachmentStore &&
        options.attachmentPersistence ==
            ChatAttachmentPersistencePolicy.managedPrivateCopy) {
      try {
        fileStore = await options.attachmentFileStore.isAvailable().timeout(
          const Duration(seconds: 3),
        );
      } catch (_) {
        fileStore = false;
      }
    }
    // Do not return a snapshot belonging to a signed-out or replaced account.
    _check(epoch);
    return buildChatCapabilityReport(
      setup: setup,
      server: server,
      storageConfigured: options.storage != null,
      attachmentsConfigured: options.attachmentStorageOrigins.isNotEmpty,
      persistAttachments:
          options.attachmentPersistence ==
          ChatAttachmentPersistencePolicy.managedPrivateCopy,
      attachmentStoreAvailable: fileStore,
      anonymous: _record?['kind'] == 'anonymous',
      host: host,
    );
  }

  /// Authoritative customer-wide total; never sum a paginated conversation list.
  Future<int> getUnreadCount() async {
    final epoch = _identityEpoch;
    final json = await _authorized('GET', '/v1/chat/bootstrap');
    _cacheConfiguration(json, epoch);
    final count = json['unreadCount'];
    if (count is! int || count < 0) {
      throw const ProtodeskChatException('chat.invalid_unread_count');
    }
    final capabilities = json['capabilities'];
    _typingEnabled = capabilities is Map && capabilities['typing'] == true;
    if (!_typingEnabled && _typingConversation != null)
      setTyping(_typingConversation!, false);
    return count;
  }

  /// Report only a canonical message the host has actually presented/read.
  /// The server keeps the cursor monotonic, including across devices/retries.
  Future<ChatReadState> markRead({
    required String conversationId,
    required String throughMessageId,
  }) async {
    if (conversationId.isEmpty ||
        throughMessageId.isEmpty ||
        !throughMessageId.startsWith('msg_')) {
      throw const ProtodeskChatException('chat.read_state_invalid');
    }
    final json = await _authorized(
      'POST',
      '/v1/chat/conversations/${Uri.encodeComponent(conversationId)}/read',
      body: {'throughMessageId': throughMessageId},
    );
    try {
      final result = ChatReadState.fromJson(json);
      if (result.conversationId != conversationId ||
          result.unreadCount < 0 ||
          result.throughMessageId.isEmpty)
        throw const FormatException();
      _readReports.add(result);
      return result;
    } catch (_) {
      throw const ProtodeskChatException('chat.invalid_read_state');
    }
  }

  /// Ephemeral, best-effort and never queued. Call from actual composer edits.
  /// Refreshes are throttled to three seconds and stop after five seconds idle.
  void setTyping(String conversationId, bool typing) {
    if (conversationId.isEmpty ||
        (!typing && _typingConversation != conversationId))
      return;
    if (typing && !_typingEnabled) return;
    if (_state != ChatClientState.ready ||
        _connectionState != ChatConnectionState.connected ||
        _socket == null)
      return;
    if (_typingConversation != null && _typingConversation != conversationId) {
      _sendTyping(_typingConversation!, false);
      _typingSentAt = null;
    }
    _typingIdle?.cancel();
    if (!typing) {
      if (_typingConversation == conversationId)
        _sendTyping(conversationId, false);
      _typingConversation = null;
      _typingSentAt = null;
      return;
    }
    if (conversationId.isEmpty) return;
    _typingConversation = conversationId;
    final now = DateTime.now();
    if (_typingSentAt == null ||
        now.difference(_typingSentAt!) >= const Duration(seconds: 3)) {
      _sendTyping(conversationId, true);
      _typingSentAt = now;
    }
    _typingIdle = Timer(
      const Duration(seconds: 5),
      () => setTyping(conversationId, false),
    );
  }

  void _sendTyping(String conversationId, bool typing) {
    try {
      _socket?.send(
        jsonEncode({
          'type': 'typing.set',
          'protocolVersion': 1,
          'conversationId': conversationId,
          'typing': typing,
        }),
      );
    } catch (_) {
      /* Ephemeral signal: no durable retry or session failure. */
    }
  }

  final _readReports = StreamController<ChatReadState>.broadcast();
  Stream<ChatReadState> get readReports => _readReports.stream;
  bool _typingEnabled = false;
  bool get typingEnabled => _typingEnabled;
  String? _typingConversation;
  DateTime? _typingSentAt;
  Timer? _typingIdle;
  final _typingChanges = StreamController<ChatTypingState>.broadcast();
  Stream<ChatTypingState> get typingChanges => _typingChanges.stream;
  final _typingStates = <String, ChatTypingState>{};
  final _typingExpiry = <String, Timer>{};
  bool isTyping(String conversationId) => _typingStates.values.any(
    (state) => state.conversationId == conversationId && state.typing,
  );

  List<ChatTypingActor> typingAgents(String conversationId) =>
      List.unmodifiable(
        _typingStates.values
            .where(
              (state) =>
                  state.conversationId == conversationId &&
                  state.typing &&
                  state.actor.kind == 'agent',
            )
            .map((state) => state.actor),
      );

  void _receiveTyping(Map<String, dynamic> frame) {
    try {
      final value = ChatTypingState.fromJson(frame);
      final now = DateTime.now();
      if (value.conversationId.isEmpty ||
          value.expiresAt.isBefore(value.occurredAt) ||
          value.expiresAt.difference(value.occurredAt) >
              const Duration(seconds: 8) ||
          value.expiresAt.difference(now) > const Duration(seconds: 8))
        return;
      final previous = _typingStates[value.stateKey];
      if (previous != null && !value.occurredAt.isAfter(previous.occurredAt))
        return;
      if (!_typingStates.containsKey(value.stateKey) &&
          _typingStates.length >= 128)
        return;
      final active = value.typing && value.expiresAt.isAfter(now);
      final state = ChatTypingState(
        value.conversationId,
        active,
        value.occurredAt,
        value.expiresAt,
        actor: value.actor,
      );
      _typingStates[value.stateKey] = state;
      _typingExpiry.remove(value.stateKey)?.cancel();
      _typingChanges.add(state);
      // Retain stop timestamps briefly so reordered starts cannot resurrect them.
      _typingExpiry[value.stateKey] = Timer(const Duration(seconds: 8), () {
        _typingExpiry.remove(value.stateKey);
        _typingStates.remove(value.stateKey);
      });
      if (active) {
        _typingExpiry.remove(value.stateKey)?.cancel();
        _typingExpiry[value.stateKey] = Timer(
          value.expiresAt.difference(now),
          () {
            _typingStates[value.stateKey] = ChatTypingState(
              value.conversationId,
              false,
              value.occurredAt,
              value.expiresAt,
              actor: value.actor,
            );
            _typingChanges.add(_typingStates[value.stateKey]!);
            _typingExpiry[value.stateKey] = Timer(
              const Duration(seconds: 8),
              () {
                _typingExpiry.remove(value.stateKey);
                _typingStates.remove(value.stateKey);
              },
            );
          },
        );
      }
    } catch (_) {
      /* Invalid ephemeral frames cannot poison durable replay. */
    }
  }

  void _clearTyping() {
    _typingIdle?.cancel();
    _typingConversation = null;
    _typingSentAt = null;
    for (final timer in _typingExpiry.values) {
      timer.cancel();
    }
    _typingExpiry.clear();
    for (final state in _typingStates.values) {
      _typingChanges.add(
        ChatTypingState(
          state.conversationId,
          false,
          state.occurredAt,
          state.expiresAt,
          actor: state.actor,
        ),
      );
    }
    _typingStates.clear();
  }

  Future<ChatPage<ChatConversation>> listConversations({String? cursor}) async {
    final json = await _authorized(
      'GET',
      '/v1/chat/conversations',
      cursor: cursor,
    );
    return ChatPage(
      List.unmodifiable(
        (json['data'] as List).map((item) => ChatConversation.fromJson(item)),
      ),
      hasMore: json['hasMore'] as bool,
      nextCursor: json['nextCursor'] as String?,
    );
  }

  Future<ChatPage<ChatMessage>> listMessages(
    String conversationId, {
    String? cursor,
  }) async {
    if (_state != ChatClientState.ready) {
      throw const ProtodeskChatException('chat.session_required');
    }
    if (cursor == null) _watchedConversation = conversationId;
    final json = await _authorized(
      'GET',
      '/v1/chat/conversations/${Uri.encodeComponent(conversationId)}/messages',
      cursor: cursor,
    );
    final messages = (json['data'] as List)
        .map((item) => ChatMessage.fromJson(item))
        .toList();
    for (final message in messages) {
      _sendQueue?.acknowledge(message);
    }
    return ChatPage(
      List.unmodifiable(messages),
      hasMore: json['hasMore'] as bool,
      nextCursor: json['nextCursor'] as String?,
    );
  }

  ({int epoch, ChatAppConfiguration value})? _configuration;

  /// The configuration last read for the current identity, if any.
  ChatAppConfiguration? get cachedConfiguration =>
      _configuration?.epoch == _identityEpoch ? _configuration!.value : null;

  /// Public Chat App configuration for the current identity. Cached until the
  /// identity changes; pass [refresh] to reread it (unread reads also update it).
  Future<ChatAppConfiguration> getConfiguration({bool refresh = false}) async {
    if (_state != ChatClientState.ready) {
      throw const ProtodeskChatException('chat.session_required');
    }
    final cached = cachedConfiguration;
    if (cached != null && !refresh) return cached;
    final epoch = _identityEpoch;
    final json = await _authorized('GET', '/v1/chat/bootstrap');
    return _cacheConfiguration(json, epoch) ??
        (throw const ProtodeskChatException('chat.invalid_response'));
  }

  ChatAppConfiguration? _cacheConfiguration(
    Map<String, dynamic> json,
    int epoch,
  ) {
    try {
      final value = ChatAppConfiguration.fromBootstrap(json);
      if (epoch == _identityEpoch)
        _configuration = (epoch: epoch, value: value);
      return value;
    } on ProtodeskChatException {
      return null;
    }
  }

  /// Published Help Center for [locale] (or the server's resolved default).
  /// `chat.help_center_unavailable` means Help is off or has no content.
  Future<ChatHelpCenterManifest> getHelpCenter({String? locale}) async {
    _requireReady();
    return ChatHelpCenterManifest.fromJson(
      await _authorized(
        'GET',
        '/v1/chat/help-center',
        query: {'locale': ?_helpLocale(locale)},
      ),
    );
  }

  /// Search ([query], 2–120 characters) or list articles, optionally within
  /// [collectionId]. Results are customer-safe summaries.
  Future<ChatPage<ChatHelpArticleSummary>> listHelpArticles({
    String? query,
    String? collectionId,
    String? locale,
    String? cursor,
    int limit = 20,
  }) async {
    _requireReady();
    final search = query?.trim();
    if ((search != null && (search.length < 2 || search.length > 120)) ||
        (collectionId != null &&
            (collectionId.isEmpty || collectionId.length > 128)) ||
        limit < 1 ||
        limit > 50) {
      throw const ProtodeskChatException('chat.help_request_invalid');
    }
    return parseHelpArticlePage(
      await _authorized(
        'GET',
        '/v1/chat/help-center/articles',
        cursor: cursor,
        query: {
          'limit': '$limit',
          'query': ?search,
          'collectionId': ?collectionId,
          'locale': ?_helpLocale(locale),
        },
      ),
    );
  }

  Future<ChatHelpArticle> getHelpArticle(
    String articleId, {
    String? locale,
  }) async {
    _requireReady();
    if (articleId.isEmpty || articleId.length > 128) {
      throw const ProtodeskChatException('chat.help_request_invalid');
    }
    return ChatHelpArticle.fromJson(
      await _authorized(
        'GET',
        '/v1/chat/help-center/articles/${Uri.encodeComponent(articleId)}',
        query: {'locale': ?_helpLocale(locale)},
      ),
    );
  }

  static String? _helpLocale(String? locale) {
    if (locale == null || locale.isEmpty) return null;
    if (locale.length > 35 ||
        !RegExp(r'^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$').hasMatch(locale)) {
      throw const ProtodeskChatException('chat.help_request_invalid');
    }
    return locale;
  }

  void _requireReady() {
    if (_state != ChatClientState.ready) {
      throw const ProtodeskChatException('chat.session_required');
    }
  }

  /// One conversation under the current customer scope.
  Future<ChatConversation> getConversation(String conversationId) async {
    if (_state != ChatClientState.ready) {
      throw const ProtodeskChatException('chat.session_required');
    }
    return ChatConversation.fromJson(
      await _authorized(
        'GET',
        '/v1/chat/conversations/${Uri.encodeComponent(conversationId)}',
      ),
    );
  }

  /// [context] is unverified display context (default: options.initialContext).
  /// [externalObject] is rejected by servers without an ownership resolver.
  Future<ChatConversation> createConversation({
    required String idempotencyKey,
    String subject = '',
    Map<String, dynamic> preChat = const {},
    String? routingChoiceId,
    ChatCreateConversationContext? context,
    ChatExternalObjectReference? externalObject,
  }) async {
    final effectiveContext = context ?? options.initialContext;
    return ChatConversation.fromJson(
      await _authorized(
        'POST',
        '/v1/chat/conversations',
        idempotencyKey: idempotencyKey,
        body: {
          'subject': subject,
          'preChat': preChat,
          if (routingChoiceId != null) 'routingChoiceId': routingChoiceId,
          if (effectiveContext != null) 'context': effectiveContext.toJson(),
          if (externalObject != null) 'externalObject': externalObject.toJson(),
        },
      ),
    );
  }

  /// Optional follow-up email state for one conversation. Servers only offer
  /// it to anonymous visitors after a saved message; 403/404 mean unavailable.
  Future<ChatContact> getContact(String conversationId) async =>
      _contact('GET', conversationId);

  /// Saves a self-reported email. Not verification, sign-in or a merge.
  /// Reuse [operationId] when retrying the same email after an uncertain result.
  Future<ChatContact> shareContactEmail({
    required String conversationId,
    required String email,
    required String operationId,
  }) {
    final trimmed = email.trim();
    if (trimmed.length > 254 || !_contactEmail.hasMatch(trimmed)) {
      throw const ProtodeskChatException('chat.contact_invalid');
    }
    return _contact(
      'POST',
      conversationId,
      body: {'email': trimmed},
      operationId: operationId,
    );
  }

  /// Declines the request. A stale dismissal never erases a saved email.
  Future<ChatContact> dismissContactRequest({
    required String conversationId,
    required String operationId,
  }) => _contact(
    'POST',
    conversationId,
    body: {'dismissed': true},
    operationId: operationId,
  );

  static final _contactEmail = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  Future<ChatContact> _contact(
    String method,
    String conversationId, {
    Map<String, dynamic>? body,
    String? operationId,
  }) async {
    if (_state != ChatClientState.ready) {
      throw const ProtodeskChatException('chat.session_required');
    }
    if (conversationId.isEmpty || (body != null && operationId!.isEmpty)) {
      throw const ProtodeskChatException('chat.contact_invalid');
    }
    final json = await _authorized(
      method,
      '/v1/chat/conversations/${Uri.encodeComponent(conversationId)}/contact',
      body: body,
      idempotencyKey: operationId,
    );
    try {
      return ChatContact.fromJson(json);
    } catch (_) {
      throw const ProtodeskChatException('chat.invalid_response');
    }
  }

  Future<ChatMessage> sendMessage({
    required String conversationId,
    required String clientMessageId,
    required String text,
    List<String> attachmentIds = const [],
  }) async {
    final ids = List<String>.of(attachmentIds);
    if (ids.length > 10 ||
        ids.toSet().length != ids.length ||
        ids.any((id) => id.isEmpty)) {
      throw const ProtodeskChatException('chat.attachment_invalid');
    }
    return ChatMessage.fromJson(
      await _authorized(
        'POST',
        '/v1/chat/conversations/${Uri.encodeComponent(conversationId)}/messages',
        idempotencyKey: clientMessageId,
        body: {
          'clientMessageId': clientMessageId,
          'body': text,
          'attachmentIds': ids,
        },
      ),
    );
  }

  /// Starts one foreground reconnect loop. Observe connectionStates for readiness.
  Future<void> connect() async {
    if (_state != ChatClientState.ready)
      throw const ProtodeskChatException('chat.session_required');
    _queueActive = true;
    _sendQueue?.setActive(true);
    if (_connectionState != ChatConnectionState.disconnected) return;
    final generation = ++_connectionEpoch;
    _setConnection(ChatConnectionState.connecting);
    final identity = _identityEpoch;
    final previous = _connectionTask;
    final task = () async {
      // An invalidated ticket/handshake is allowed to finish and close before
      // another attempt starts, even during rapid background/foreground churn.
      if (previous != null) await previous;
      if (_active(generation, identity))
        await _runConnection(generation, identity);
    }();
    _connectionTask = task;
    unawaited(task);
  }

  bool _active(int generation, int identity) =>
      !_disposing &&
      generation == _connectionEpoch &&
      identity == _identityEpoch &&
      _state == ChatClientState.ready;
  Future<void> _delay(Duration duration) async {
    final done = Completer<void>();
    _delayDone = done;
    _delayTimer = Timer(duration, () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    if (identical(_delayDone, done)) {
      _delayTimer = null;
      _delayDone = null;
    }
  }

  // Keep consuming the transport while reconciliation awaits HTTP/storage, but
  // cap queued frames. Overflow closes the connection without advancing cursor.
  Stream<Object?> _boundedFrames(ChatSocket socket) async* {
    final queue = StreamController<Object?>();
    var pending = 0, stopped = false;
    final subscription = socket.frames.listen(
      (raw) {
        if (stopped) return;
        if (++pending > 128 ||
            raw is! String ||
            utf8.encode(raw).length > 262144) {
          stopped = true;
          queue.addError(
            const ProtodeskChatException(
              'chat.realtime_backpressure',
              retryable: true,
            ),
          );
          unawaited(socket.close());
        } else {
          queue.add(raw);
        }
      },
      onError: (Object error) {
        if (!stopped) queue.addError(error);
      },
      onDone: () {
        unawaited(queue.close());
      },
    );
    try {
      await for (final raw in queue.stream.timeout(
        const Duration(seconds: 75),
      )) {
        pending--;
        yield raw;
      }
    } finally {
      stopped = true;
      await subscription.cancel();
      unawaited(queue.close());
    }
  }

  Future<void> _runConnection(int generation, int identity) async {
    var attempt = 0;
    var serverDelay = Duration.zero;
    while (_active(generation, identity)) {
      ChatSocket? socket;
      DateTime? readyAt;
      var terminal = false;
      try {
        if (attempt > 0) {
          _setConnection(ChatConnectionState.reconnecting);
          final ceiling = min(30000, 500 * (1 << min(attempt - 1, 6)));
          await _delay(
            serverDelay + Duration(milliseconds: Random().nextInt(ceiling + 1)),
          );
          if (!_active(generation, identity)) break;
        }
        serverDelay = Duration.zero;
        await _restoreCheckpoint(generation, identity);
        final ticket = await _authorized('POST', '/v1/chat/realtime/ticket');
        if (!_active(generation, identity)) break;
        final uri = options.baseUrl
            .resolve('/v1/chat/realtime')
            .replace(
              scheme: options.baseUrl.scheme == 'https' ? 'wss' : 'ws',
              queryParameters: {'ticket': ticket['ticket'] as String},
            );
        socket = await _transport.connect(uri);
        if (!_active(generation, identity)) {
          await socket.close();
          break;
        }
        _socket = socket;
        socket.send(
          jsonEncode({
            'type': 'realtime.resume',
            'protocolVersion': 1,
            'cursor': _cursor,
          }),
        );
        frames:
        await for (final raw in _boundedFrames(socket)) {
          if (!_active(generation, identity)) break;
          if (raw is! String || utf8.encode(raw).length > 262144)
            throw const ProtodeskChatException('chat.invalid_frame');
          final frame = jsonDecode(raw) as Map<String, dynamic>;
          if (frame['protocolVersion'] != 1)
            throw const ProtodeskChatException('chat.protocol_unsupported');
          switch (frame['type']) {
            case 'realtime.ready':
              if (readyAt != null)
                throw const ProtodeskChatException('chat.invalid_frame');
              await _reconcile(
                frame['cursor'] as String?,
                {..._seen},
                generation,
                identity,
              );
              readyAt = DateTime.now();
              _setConnection(ChatConnectionState.connected);
              _changes.add(null);
            case 'realtime.event':
              if (readyAt == null)
                throw const ProtodeskChatException('chat.invalid_frame');
              final event = ChatServerEvent.fromJson(
                frame['event'] as Map<String, dynamic>,
              );
              final cursor = frame['cursor'] as String;
              final fresh = !_seen.contains(event.id);
              final seen = {..._seen, event.id};
              if (seen.length > 256) seen.remove(seen.first);
              // Reduce a detached copy, then atomically persist before publication.
              if (fresh) {
                await _applyEvent(event, cursor, seen, generation, identity);
                if (event.type == 'message.created') {
                  _sendQueue?.acknowledge(
                    ChatMessage.fromJson(
                      event.data['message'] as Map<String, dynamic>,
                    ),
                  );
                }
                _events.add(event);
                _changes.add(null);
              } else {
                await _commitHistory(
                  _history,
                  cursor,
                  seen,
                  generation,
                  identity,
                );
              }
            case 'realtime.resync_required':
              await _commitHistory(_history, null, {}, generation, identity);
              await socket.close();
              break frames;
            case 'realtime.drain':
              serverDelay = Duration(
                milliseconds: (frame['reconnectAfterMs'] as int? ?? 0).clamp(
                  0,
                  60000,
                ),
              );
              await socket.close();
              break frames;
            case 'typing.changed':
              _receiveTyping(frame);
              break;
            case 'realtime.heartbeat':
              break;
            default:
              throw const ProtodeskChatException('chat.protocol_unsupported');
          }
        }
        terminal = [1008, 4401, 4403].contains(socket.closeCode);
      } catch (error) {
        if (_active(generation, identity)) {
          final safe = error is ProtodeskChatException
              ? error
              : const ProtodeskChatException(
                  'chat.realtime_unavailable',
                  retryable: true,
                );
          _errors.add(safe);
          terminal = !safe.retryable;
          serverDelay = safe.retryAfter ?? serverDelay;
        }
      } finally {
        if (socket != null) await socket.close();
        if (identical(_socket, socket)) _socket = null;
      }
      if (!_active(generation, identity)) break;
      if (terminal) {
        _setConnection(ChatConnectionState.disconnected);
        break;
      }
      if (readyAt != null &&
          DateTime.now().difference(readyAt) >= const Duration(seconds: 30))
        attempt = 0;
      attempt++;
    }
  }

  Future<void> disconnect() async {
    if (_typingConversation != null) _sendTyping(_typingConversation!, false);
    _clearTyping();
    _attachments?.suspend();
    _queueActive = false;
    _sendQueue?.setActive(false);
    ++_connectionEpoch;
    _delayTimer?.cancel();
    if (_delayDone case final done? when !done.isCompleted) done.complete();
    final socket = _socket;
    _socket = null;
    if (_state != ChatClientState.disposed)
      _setConnection(ChatConnectionState.disconnected);
    if (socket != null) await socket.close();
  }

  /// Local isolation happens first even if remote revocation fails. A thrown
  /// error means remote logout is unconfirmed; it never restores local access.
  Future<void> logout() async {
    if (_state == ChatClientState.disposed)
      throw const ProtodeskChatException('chat.disposed');
    final previous = _session;
    final pendingUploads =
        _attachments?.pendingRemoteUploadIds ?? const <String>[];
    final attachmentClearing = _attachments?.purge() ?? Future<void>.value();
    ++_identityEpoch;
    _session = null;
    _refreshing = null;
    _cursor = null;
    _seen.clear();
    _clearHistory();
    _setState(ChatClientState.signedOut);
    final vault = _vault;
    final cleared = {
      'kind': _identityKey == null ? 'anonymous' : 'verified',
      ...?_record,
      'session': null,
      'refreshPending': false,
      'queueEpoch': newOperationId(),
    };
    _record = cleared;
    // This captured partition must clear even if dispose or identify follows.
    final queueClearing = vault == null
        ? Future<void>.value()
        : vault.delete(_outboxKey);
    final historyClearing = vault == null
        ? Future<void>.value()
        : vault.delete(_checkpointKey);
    final pushClearing = vault == null
        ? Future<void>.value()
        : vault.delete(_pushKey);
    final clearing = vault == null
        ? Future<void>.value()
        : vault.write(vault.key(_identityKey), cleared, () {});
    final exchanges = _exchanges.toList();
    final issued = _issuedTokens.keys.toSet();
    if (previous != null) issued.add(previous.access);
    _issuedTokens.clear();
    // Observe all failures; attempt remote revocation even when storage fails.
    final results = await Future.wait([
      attachmentClearing.then<Object?>((_) => null, onError: (Object e) => e),
      queueClearing.then<Object?>((_) => null, onError: (Object e) => e),
      historyClearing.then<Object?>((_) => null, onError: (Object e) => e),
      pushClearing.then<Object?>((_) => null, onError: (Object e) => e),
      clearing.then<Object?>((_) => null, onError: (Object e) => e),
      ...exchanges,
      (() async {
        await disconnect();
        if (previous != null) {
          await Future.wait(
            pendingUploads.map((id) async {
              try {
                await _request(
                  'DELETE',
                  '/v1/chat/attachments/uploads/${Uri.encodeComponent(id)}',
                  accessToken: previous.access,
                ).timeout(const Duration(seconds: 3));
              } catch (_) {
                /* Pending/scanning races use backend retention cleanup. */
              }
            }),
          );
        }
        for (final token in issued) {
          await _request(
            'DELETE',
            '/v1/chat/sessions/current',
            accessToken: token,
          );
        }
      })().then<Object?>((_) => null, onError: (Object e) => e),
    ]);
    for (final error in results) {
      if (error is ProtodeskChatException &&
          error.code == 'chat.operation_cancelled')
        continue;
      if (error != null) throw error;
    }
  }

  /// Revoke the anonymous binding before deleting its proof. A failed server
  /// reset retains credentials so the caller can retry. No new identity is created
  /// until continueAnonymously() or the next initialization.
  Future<void> resetAnonymousIdentity() async {
    if (_identityKey != null || _record?['kind'] != 'anonymous') {
      throw const ProtodeskChatException('chat.anonymous_identity_required');
    }
    final epoch = _identityEpoch;
    await _authorized('DELETE', '/v1/chat/anonymous-identity');
    _check(epoch);
    final attachmentClearing = _attachments?.purge() ?? Future<void>.value();
    ++_identityEpoch;
    _session = null;
    _refreshing = null;
    _cursor = null;
    _seen.clear();
    _clearHistory();
    _setState(ChatClientState.signedOut);
    try {
      await Future.wait([
        attachmentClearing,
        if (_vault != null) _vault.delete(_checkpointKey),
        if (_vault != null) _vault.delete(_outboxKey),
        if (_vault != null) _vault.delete(_pushKey),
        _save({'kind': 'anonymous', 'reset': true}, _identityEpoch),
      ]);
    } finally {
      await disconnect();
    }
  }

  /// Releases local resources. Call logout first when remote revocation is needed.
  Future<void> dispose() async {
    if (_state == ChatClientState.disposed || _disposing) return;
    _disposing = true;
    await _attachments?.close();
    await _attachmentCleanup.catchError((Object _) {});
    await _sendQueue?.close();
    ++_identityEpoch;
    _session = null;
    _clearHistory();
    _setState(ChatClientState.disposed);
    await disconnect();
    _transport.close();
    await _vault?.close();
    _lifecycle.dispose();
    await Future.wait([
      _states.close(),
      _connections.close(),
      _events.close(),
      _typingChanges.close(),
      _readReports.close(),
      _errors.close(),
      _changes.close(),
    ]);
  }
}

final class _Session {
  _Session.fromJson(Map<String, dynamic> json)
    : access = json['accessToken'] as String,
      refresh = json['refreshToken'] as String,
      expires = DateTime.parse(json['accessExpiresAt'] as String),
      refreshExpires = json['refreshExpiresAt'] == null
          ? null
          : DateTime.parse(json['refreshExpiresAt'] as String);
  final String access, refresh;
  final DateTime expires;
  final DateTime? refreshExpires;
  Map<String, dynamic> toJson() => {
    'accessToken': access,
    'refreshToken': refresh,
    'accessExpiresAt': expires.toUtc().toIso8601String(),
    if (refreshExpires != null)
      'refreshExpiresAt': refreshExpires!.toUtc().toIso8601String(),
  };
}
