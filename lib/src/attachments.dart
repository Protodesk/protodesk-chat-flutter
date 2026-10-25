import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'attachment_storage.dart';

import 'models.dart';

/// Hosts adapt their native picker to this contract. Return null on dismissal.
/// Read at most 16 MiB; never pass a persistent path or permission-bearing URI.
typedef ChatAttachmentPicker = Future<ChatAttachmentSource?> Function();

final class ChatAttachmentSource {
  ChatAttachmentSource({
    required this.filename,
    required this.contentType,
    required Uint8List bytes,
  }) : _bytes = Uint8List.fromList(bytes).asUnmodifiableView() {
    if (_bytes.isEmpty ||
        _bytes.length > 16 * 1024 * 1024 ||
        filename.isEmpty ||
        utf8.encode(filename).length > 255 ||
        RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(filename) ||
        !(_types[contentType]?.contains(
              filename.split('.').last.toLowerCase(),
            ) ??
            false)) {
      throw const ProtodeskChatException('sdk.attachment_source_unavailable');
    }
  }
  final String filename, contentType;
  final Uint8List _bytes;
  int get sizeBytes => _bytes.length;
  Uint8List get bytes => _bytes;
  static const _types = {
    'image/jpeg': ['jpg', 'jpeg'],
    'image/png': ['png'],
    'image/webp': ['webp'],
    'image/gif': ['gif'],
    'audio/mpeg': ['mp3'],
    'audio/ogg': ['ogg', 'oga'],
    'audio/wav': ['wav'],
    'audio/mp4': ['m4a'],
    'audio/webm': ['webm'],
    'video/mp4': ['mp4'],
    'video/webm': ['webm'],
    'video/quicktime': ['mov'],
    'application/pdf': ['pdf'],
    'text/plain': ['txt'],
    'text/csv': ['csv'],
  };
}

/// Cancels one transfer, including a connection that finishes opening late.
final class ChatTransferCancellation {
  bool _cancelled = false;
  void Function()? _abort;
  bool get isCancelled => _cancelled;
  void cancel() {
    _cancelled = true;
    _abort?.call();
  }

  void check() {
    if (_cancelled) {
      throw const ProtodeskChatException('chat.operation_cancelled');
    }
  }
}

/// Trusted host/test adapter. Receives signed URLs, never API credentials.
abstract interface class ChatAttachmentTransport {
  Future<void> upload(
    Uri url,
    String contentType,
    Uint8List bytes,
    ChatTransferCancellation cancellation,
    void Function(int) onProgress,
  );
  Future<Uint8List> download(
    Uri url,
    int maxBytes,
    ChatTransferCancellation cancellation,
  );
}

final class NativeChatAttachmentTransport implements ChatAttachmentTransport {
  Future<Uint8List> _transfer(
    String method,
    Uri url,
    int limit,
    ChatTransferCancellation cancellation, {
    String? contentType,
    Uint8List? body,
    void Function(int)? progress,
  }) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    cancellation._abort = () => http.close(force: true);
    try {
      return await (() async {
        cancellation.check();
        final request = await http.openUrl(method, url);
        cancellation.check();
        request.followRedirects = false;
        if (body != null) {
          request.headers.set(HttpHeaders.contentTypeHeader, contentType!);
          request.contentLength = body.length;
          for (var offset = 0; offset < body.length; offset += 64 * 1024) {
            cancellation.check();
            final end = (offset + 64 * 1024).clamp(0, body.length);
            request.add(Uint8List.sublistView(body, offset, end));
            await request.flush();
            progress!(
              end,
            ); // Bytes handed to the HTTP transport, not validation.
          }
        }
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw ProtodeskChatException(
            'sdk.attachment_transfer_failed',
            status: response.statusCode,
            retryable: response.statusCode == 429 || response.statusCode >= 500,
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          cancellation.check();
          if (bytes.length + chunk.length > limit) {
            throw const ProtodeskChatException(
              'sdk.attachment_response_too_large',
            );
          }
          bytes.add(chunk);
        }
        cancellation.check();
        return bytes.takeBytes();
      })().timeout(const Duration(minutes: 2));
    } on ProtodeskChatException {
      rethrow;
    } catch (_) {
      cancellation.check();
      throw const ProtodeskChatException(
        'sdk.attachment_transfer_failed',
        retryable: true,
      );
    } finally {
      cancellation._abort = null;
      http.close(force: true);
    }
  }

  @override
  Future<void> upload(
    Uri url,
    String contentType,
    Uint8List bytes,
    ChatTransferCancellation cancellation,
    void Function(int) onProgress,
  ) async {
    await _transfer(
      'PUT',
      url,
      64 * 1024,
      cancellation,
      contentType: contentType,
      body: bytes,
      progress: onProgress,
    );
  }

  @override
  Future<Uint8List> download(
    Uri url,
    int maxBytes,
    ChatTransferCancellation cancellation,
  ) => _transfer('GET', url, maxBytes, cancellation);
}

enum ChatUploadState {
  queued,
  retryWait,
  initiating,
  uploading,
  processing,
  ready,
  failed,
  canceled,
}

final class ChatAttachmentUpload {
  ChatAttachmentUpload._(
    this.id,
    this.conversationId,
    ChatAttachmentSource source,
    this.createdAt,
  ) : _source = source,
      filename = source.filename,
      contentType = source.contentType,
      sizeBytes = source.sizeBytes;
  ChatAttachmentUpload._restored(
    this.id,
    this.conversationId,
    this.filename,
    this.contentType,
    this.sizeBytes,
    this.createdAt,
  );
  final String id, conversationId, filename, contentType;
  final int sizeBytes;
  final DateTime createdAt;
  DateTime get expiresAt => createdAt.add(const Duration(hours: 24));
  ChatAttachmentSource? _source;
  ChatAttachmentSource? get source => _source;
  ChatUploadState _state = ChatUploadState.initiating;
  ChatUploadState get state => _state;
  int _sent = 0;
  int get sentBytes => _sent;
  ChatAttachment? _attachment;
  ChatAttachment? get attachment => _attachment;
  ProtodeskChatException? _error;
  ProtodeskChatException? get error => _error;
  String? _uploadId, _attachmentId, _digest, _handle;
  DateTime? _remoteExpiry, _retryAt;
  int _remoteGeneration = 0, _attempts = 0;
  int get attempt => _attempts;
  DateTime? get retryAt => _retryAt;
  bool _staged = true, _committed = true;
  bool _uploaded = false, _running = false, _putAttempted = false;
  ChatTransferCancellation _cancel = ChatTransferCancellation();
  Future<void>? _pending;
  Future<void> get settled => _pending ?? Future.value();
}

/// Internal identity-bound journal wiring; host apps configure client options.
final class AttachmentPersistence {
  AttachmentPersistence({
    required this.files,
    required this.scope,
    required this.partition,
    required this.load,
    required this.save,
    required this.remove,
  });
  final ChatAttachmentFileStore files;
  final String scope, partition;
  final Future<Map<String, dynamic>?> Function() load;
  final Future<void> Function(Map<String, dynamic>) save;
  final Future<void> Function() remove;
}

final class ChatAttachmentDraft {
  ChatAttachmentDraft(
    this.id,
    this.conversationId,
    this.text,
    List<String> uploads,
  ) : uploadIds = List.unmodifiable(uploads);
  final String id, conversationId, text;
  final List<String> uploadIds;
}

typedef AttachmentRequest = Future<Map<String, dynamic>> Function(
  String method,
  String path,
  Map<String, dynamic>? body,
  String? key,
);

/// Foreground attachment transfers with optional protected-file recovery.
/// Capabilities stay in memory. Call suspend on backgrounding; managed operations
/// resume with bounded retries only after an explicit foreground activation.
final class ChatAttachments {
  ChatAttachments({
    required this._request,
    required this._available,
    required this._operationId,
    required Set<Uri> storageOrigins,
    ChatAttachmentTransport? transport,
    this._persistence,
    this._send,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _origins = Set.unmodifiable(storageOrigins),
       _transport = transport ?? NativeChatAttachmentTransport() {
    validateStorageOrigins(_origins);
  }
  static void validateStorageOrigins(Set<Uri> origins) {
    for (final uri in origins) {
      if (!_safeOrigin(uri) ||
          !['', '/'].contains(uri.path) ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw ArgumentError(
          'Attachment storage requires exact HTTPS origins (HTTP only on loopback).',
        );
      }
    }
  }

  final AttachmentPersistence? _persistence;
  final Future<ChatMessage> Function(String, String, String, List<String>)?
  _send;
  final DateTime Function() _now;
  bool get isPersistent => _persistence != null;
  bool _restored = false, _active = false, _storageBlocked = false;
  bool get storageBlocked => _storageBlocked;
  ProtodeskChatException? _storageError;
  ProtodeskChatException? get storageError => _storageError;
  Future<void> _writes = Future.value();
  final _preparing = <Future<void>>{};
  Timer? _timer;
  final _drafts = <ChatAttachmentDraft>[];
  final _sending = <String>{};
  List<ChatAttachmentDraft> get pendingDrafts => List.unmodifiable(_drafts);
  List<ChatAttachmentUpload> pendingUploads(String conversationId) => uploads
      .where((u) => u.conversationId == conversationId)
      .toList(growable: false);
  final AttachmentRequest _request;
  final bool Function() _available;
  final String Function() _operationId;
  final Set<Uri> _origins;
  final ChatAttachmentTransport _transport;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  final _items = <ChatAttachmentUpload>[];
  final _downloads = <ChatTransferCancellation>{};
  List<ChatAttachmentUpload> get uploads => List.unmodifiable(_items);

  /// Includes private-copy staging and uncertain sends, not just visible uploads.
  bool get hasPendingWork =>
      _items.isNotEmpty ||
      _drafts.isNotEmpty ||
      _preparing.isNotEmpty ||
      _sending.isNotEmpty;

  /// Used only for best-effort cancellation with the captured old session.
  List<String> get pendingRemoteUploadIds => _items
      .where((u) => u._uploadId != null && u.attachment == null)
      .map((u) => u._uploadId!)
      .toSet()
      .toList(growable: false);
  bool _closed = false;
  int _generation = 0;
  static bool _safeOrigin(Uri u) =>
      u.host.isNotEmpty &&
      u.userInfo.isEmpty &&
      (u.scheme == 'https' ||
          (u.scheme == 'http' &&
              ['localhost', '127.0.0.1', '::1'].contains(u.host)));
  Uri _url(Map<String, dynamic> json) {
    final uri = Uri.tryParse(json['url'] as String? ?? '');
    final expiry = DateTime.tryParse(json['expiresAt'] as String? ?? '');
    if (uri == null ||
        !_safeOrigin(uri) ||
        uri.hasFragment ||
        !_origins.any((origin) => origin.origin == uri.origin) ||
        expiry == null ||
        !expiry.isAfter(_now())) {
      throw const ProtodeskChatException('sdk.attachment_capability_invalid');
    }
    return uri;
  }

  void _emit() {
    if (!_closed) _changes.add(null);
  }

  void _checkAvailable() {
    if (_closed || !_available()) {
      throw const ProtodeskChatException('sdk.attachment_offline_disabled');
    }
    if (_origins.isEmpty) {
      throw const ProtodeskChatException('sdk.attachment_storage_unconfigured');
    }
  }

  ChatAttachmentUpload upload(
    String conversationId,
    ChatAttachmentSource source,
  ) {
    if (isPersistent) {
      throw const ProtodeskChatException(
        'sdk.attachment_durable_enqueue_required',
      );
    }
    _checkAvailable();
    if (conversationId.isEmpty) {
      throw const ProtodeskChatException('chat.attachment_invalid');
    }
    if (_items.length >= 10 ||
        _items.fold<int>(0, (n, u) => n + (u.source?.sizeBytes ?? 0)) +
                source.sizeBytes >
            64 * 1024 * 1024 ||
        _items.where((u) => u._running).length + _downloads.length >= 3) {
      throw const ProtodeskChatException('sdk.attachment_queue_full');
    }
    final item = ChatAttachmentUpload._(
      _operationId(),
      conversationId,
      source,
      _now(),
    );
    _items.add(item);
    item._pending = _run(item);
    return item;
  }

  Future<void> retry(ChatAttachmentUpload item) async {
    if (isPersistent) {
      if (!_restored ||
          _closed ||
          _storageBlocked ||
          !_items.contains(item) ||
          item._running ||
          item.error?.retryable != true) {
        throw const ProtodeskChatException('sdk.attachment_retry_unavailable');
      }
      item._attempts = 0;
      item._state = ChatUploadState.queued;
      item._cancel = ChatTransferCancellation();
      await _persist();
      _wake();
      return;
    }
    _checkAvailable();
    if (!_items.contains(item) ||
        item._running ||
        item.state != ChatUploadState.failed ||
        item.error?.retryable != true ||
        _items.where((u) => u._running).length + _downloads.length >= 3) {
      throw const ProtodeskChatException('sdk.attachment_retry_unavailable');
    }
    item._cancel = ChatTransferCancellation();
    return item._pending = _run(item);
  }

  String _key(ChatAttachmentUpload item, String phase) => isPersistent
      ? sha256
            .convert(utf8.encode('${item.id}:${item._remoteGeneration}:$phase'))
            .toString()
      : phase == 'init'
      ? item.id
      : '${item.id}-complete';

  Future<void> _run(ChatAttachmentUpload item) async {
    final generation = _generation;
    void check() {
      item._cancel.check();
      if (_closed ||
          generation != _generation ||
          !_items.contains(item) ||
          (isPersistent && (_storageBlocked || !_active || !_available()))) {
        throw const ProtodeskChatException('chat.operation_cancelled');
      }
    }

    item._running = true;
    item._error = null;
    try {
      check();
      if (isPersistent) {
        item._attempts++;
        await _persist();
        check();
      }
      if (item._source == null && item._handle != null) {
        final p = _persistence!;
        Uint8List bytes;
        try {
          bytes = await p.files.read(p.scope, p.partition, item._handle!);
        } catch (_) {
          throw const ProtodeskChatException(
            'sdk.attachment_source_unavailable',
          );
        }
        check();
        if (bytes.length != item.sizeBytes ||
            sha256.convert(bytes).toString() != item._digest) {
          throw const ProtodeskChatException(
            'sdk.attachment_source_unavailable',
          );
        }
        item._source = ChatAttachmentSource(
          filename: item.filename,
          contentType: item.contentType,
          bytes: bytes,
        );
      }
      // A process may die after PUT reached storage but before its response.
      // Probe completion before obtaining another capability or repeating PUT.
      if (isPersistent && item._uploadId != null && item._putAttempted) {
        try {
          await _complete(item, check);
          return;
        } on ProtodeskChatException catch (e) {
          if (e.status != 409 || e.code != 'chat.attachment_invalid') rethrow;
          check();
          if (item._remoteExpiry != null &&
              !item._remoteExpiry!.isAfter(_now())) {
            item._remoteGeneration++;
            item._uploadId = null;
            item._attachmentId = null;
            item._uploaded = false;
            item._putAttempted = false;
            await _persist();
            check();
          } else if (item._uploaded) {
            throw const ProtodeskChatException(
              'chat.attachment_unavailable',
              retryable: true,
              retryAfter: Duration(seconds: 5),
            );
          }
        }
      } else if (isPersistent &&
          item._remoteExpiry != null &&
          !item._remoteExpiry!.isAfter(_now())) {
        item._remoteGeneration++;
        item._uploadId = null;
        item._attachmentId = null;
        item._uploaded = false;
        item._putAttempted = false;
        await _persist();
        check();
      }
      final source = item.source;
      if (!item._uploaded) {
        if (source == null) {
          throw const ProtodeskChatException(
            'sdk.attachment_source_unavailable',
          );
        }
        item._state = ChatUploadState.initiating;
        item._sent = 0;
        _emit();
        if (isPersistent && item._remoteExpiry == null) {
          // Conservative expiry bound for an initiation whose response is lost.
          item._remoteExpiry = _now().add(const Duration(minutes: 15));
          await _persist();
          check();
        }
        final init = await _request('POST', '/v1/chat/attachments/uploads', {
          'conversationId': item.conversationId,
          'filename': item.filename,
          'contentType': item.contentType,
          'sizeBytes': item.sizeBytes,
        }, _key(item, 'init'));
        item._uploadId = init['uploadId'] as String;
        item._attachmentId = init['attachmentId'] as String;
        check();
        final headers = Map<String, dynamic>.from(init['headers'] as Map);
        if (init['method'] != 'PUT' ||
            headers.length != 1 ||
            headers['Content-Type'] != item.contentType) {
          throw const ProtodeskChatException(
            'sdk.attachment_capability_invalid',
          );
        }
        final url = _url(init);
        item._remoteExpiry = DateTime.parse(init['expiresAt'] as String);
        item._putAttempted = true;
        item._state = ChatUploadState.uploading;
        if (isPersistent) await _persist();
        check();
        _emit();
        await _transport.upload(
          url,
          source.contentType,
          source.bytes,
          item._cancel,
          (sent) {
            if (!item._cancel.isCancelled && generation == _generation) {
              item._sent = max(item._sent, sent.clamp(0, source.sizeBytes));
              _emit();
            }
          },
        );
        check();
        item._uploaded = true;
        if (isPersistent) await _persist();
        check();
      }
      await _complete(item, check);
    } catch (error) {
      if (generation == _generation &&
          _items.contains(item) &&
          item.state != ChatUploadState.canceled) {
        var e = error is ProtodeskChatException
            ? error
            : const ProtodeskChatException('sdk.attachment_invalid_response');
        if (isPersistent &&
            item.state == ChatUploadState.initiating &&
            e.status == 409 &&
            e.code == 'chat.attachment_invalid') {
          e = const ProtodeskChatException(
            'chat.attachment_unavailable',
            retryable: true,
            retryAfter: Duration(seconds: 5),
          );
        }
        if (isPersistent &&
            e.code == 'sdk.attachment_transfer_failed' &&
            e.status == 403) {
          e = const ProtodeskChatException(
            'sdk.attachment_transfer_failed',
            retryable: true,
          );
        }
        if (isPersistent && item._cancel.isCancelled) {
          item._state = ChatUploadState.queued;
        } else if (item._error?.code != 'sdk.attachment_interrupted') {
          item._error = e;
          item._state = ChatUploadState.failed;
          if (isPersistent &&
              e.retryable &&
              item._attempts < 6 &&
              !_storageBlocked) {
            item._state = ChatUploadState.retryWait;
            final jitter = Duration(
              milliseconds:
                  Random().nextInt(min(30000, 1000 * (1 << item._attempts))) +
                  250,
            );
            item._retryAt = _now().add(
              e.retryAfter != null && e.retryAfter! > jitter
                  ? e.retryAfter!
                  : jitter,
            );
          }
        }
        if (isPersistent && !_storageBlocked) {
          try {
            await _persist();
          } catch (_) {
            /* _persist blocks further work. */
          }
        }
      }
    } finally {
      item._running = false;
      if (isPersistent) item._source = null;
      _emit();
      _wake();
    }
  }

  Future<void> _complete(
    ChatAttachmentUpload item,
    void Function() check,
  ) async {
    item._state = ChatUploadState.processing;
    _emit();
    check();
    final result = await _request(
      'POST',
      '/v1/chat/attachments/uploads/${Uri.encodeComponent(item._uploadId!)}/complete',
      {},
      _key(item, 'complete'),
    );
    check();
    final attachment = ChatAttachment.fromJson(result);
    if (attachment.status != 'ready' || attachment.id != item._attachmentId) {
      throw const ProtodeskChatException('chat.attachment_invalid');
    }
    item._attachment = attachment;
    item._state = ChatUploadState.ready;
    item._retryAt = null;
    if (isPersistent) {
      await _persist();
      check();
      // Journal ready first. A crash before deletion is cleaned by restore's retain.
      try {
        await _deleteBody(item);
      } catch (_) {
        _storageBlocked = true;
        _storageError = const ProtodeskChatException(
          'sdk.attachment_cleanup_failed',
        );
        _emit();
        throw _storageError!;
      }
      item._source = null;
    }
  }

  Future<void> cancel(ChatAttachmentUpload item) async {
    if (!_items.contains(item)) return;
    final generation = _generation;
    item._cancel.cancel();
    item._state = ChatUploadState.canceled;
    item._source = null;
    _items.remove(item);
    _drafts.removeWhere((d) => d.uploadIds.contains(item.id));
    _emit();
    if (isPersistent) {
      // Deletion runs even if the journal is inaccessible. A stale record fails
      // source verification after restart and can never upload a different body.
      try {
        await _persist();
      } finally {
        await _deleteBody(item);
      }
      unawaited(
        item.settled.then((_) async {
          if (!_closed &&
              generation == _generation &&
              item._uploadId != null &&
              item.attachment == null &&
              _available()) {
            try {
              await _request(
                'DELETE',
                '/v1/chat/attachments/uploads/${Uri.encodeComponent(item._uploadId!)}',
                null,
                null,
              );
            } catch (_) {}
          }
        }),
      );
    } else {
      await item.settled;
      if (!_closed &&
          generation == _generation &&
          item._uploadId != null &&
          item.attachment == null) {
        await _request(
          'DELETE',
          '/v1/chat/attachments/uploads/${Uri.encodeComponent(item._uploadId!)}',
          null,
          null,
        );
      }
    }
    _wake();
  }

  Future<void> _deleteBody(ChatAttachmentUpload item) async {
    final p = _persistence;
    if (p != null && item._handle != null) {
      try {
        await p.files.delete(p.scope, p.partition, item._handle!);
      } catch (_) {
        _storageBlocked = true;
        _storageError = const ProtodeskChatException(
          'sdk.attachment_cleanup_failed',
        );
        _emit();
        throw _storageError!;
      }
    }
  }

  /// Await removal after the attachment is claimed by a message.
  Future<void> release(ChatAttachmentUpload item) async {
    if (item.state != ChatUploadState.ready) return;
    _items.remove(item);
    item._source = null;
    _emit();
    if (isPersistent) {
      try {
        await _persist();
      } finally {
        await _deleteBody(item);
      }
    }
  }

  Future<Uint8List> download(ChatAttachment attachment) async {
    _checkAvailable();
    if (attachment.status != 'ready' ||
        attachment.sizeBytes <= 0 ||
        attachment.sizeBytes > 16 * 1024 * 1024) {
      throw const ProtodeskChatException('chat.attachment_invalid');
    }
    if (_downloads.length + _items.where((u) => u._running).length >= 3) {
      throw const ProtodeskChatException('sdk.attachment_queue_full');
    }
    final generation = _generation;
    final cancel = ChatTransferCancellation();
    _downloads.add(cancel);
    try {
      final result = await _request(
        'GET',
        '/v1/chat/attachments/${Uri.encodeComponent(attachment.id)}/download',
        null,
        null,
      );
      cancel.check();
      final bytes = await _transport.download(
        _url(result),
        attachment.sizeBytes,
        cancel,
      );
      cancel.check();
      if (generation != _generation || bytes.length != attachment.sizeBytes) {
        throw const ProtodeskChatException('sdk.attachment_invalid_response');
      }
      return bytes;
    } finally {
      _downloads.remove(cancel);
      _wake();
    }
  }

  void setActive(bool value) {
    if (!value) {
      suspend();
      return;
    }
    _active = true;
    _wake();
  }

  void suspend() {
    _active = false;
    _timer?.cancel();
    for (final item in _items) {
      if (item._running) {
        item._cancel.cancel();
        item._state = isPersistent
            ? ChatUploadState.queued
            : ChatUploadState.failed;
        item._error = const ProtodeskChatException(
          'sdk.attachment_interrupted',
          retryable: true,
        );
      }
    }
    for (final cancel in _downloads) {
      cancel.cancel();
    }
    _emit();
    if (isPersistent) _scheduleExpiry();
  }

  void clear() {
    ++_generation;
    _active = false;
    _timer?.cancel();
    for (final item in _items) {
      item._cancel.cancel();
      item._source = null;
      item._attachment = null;
      item._state = ChatUploadState.canceled;
    }
    for (final cancel in _downloads) {
      cancel.cancel();
    }
    _items.clear();
    _drafts.clear();
    _emit();
  }

  /// Invalidates local work synchronously; awaits deletion before account reuse.
  Future<void> purge() async {
    clear();
    final p = _persistence;
    if (p == null) return;
    await Future.wait(_preparing.toList());
    await _writes;
    try {
      await p.remove();
    } finally {
      await p.files.purge(p.scope, p.partition);
    }
  }

  Future<void> close() async {
    suspend();
    _closed = true;
    _timer?.cancel();
    // Do not wait for network. Existing write-ahead markers describe interruption.
    await Future.wait(_preparing.toList());
    await _writes;
    clear();
    await _changes.close();
  }

  Future<void> _persist({bool recover = false}) {
    if (!isPersistent) return Future.value();
    final generation = _generation;
    final snapshot = _snapshot();
    final result = _writes.then((_) async {
      if (_closed || generation != _generation) {
        throw const ProtodeskChatException('chat.operation_cancelled');
      }
      if (_storageBlocked && !recover) {
        throw const ProtodeskChatException(
          'sdk.attachment_persistence_unavailable',
        );
      }
      try {
        await _persistence!.save(snapshot);
      } catch (_) {
        _storageBlocked = true;
        _storageError = const ProtodeskChatException(
          'sdk.attachment_persistence_unavailable',
        );
        _emit();
        throw _storageError!;
      }
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> retryPersistence() async {
    await Future.wait(_preparing.toList());
    for (final item in _items) {
      if (item.error?.code == 'sdk.attachment_persistence_unavailable' ||
          item.error?.code == 'sdk.attachment_cleanup_failed') {
        item._state = item.attachment != null
            ? ChatUploadState.ready
            : ChatUploadState.queued;
        item._error = null;
      }
    }
    await _persist(recover: true);
    for (final item in _items.where((u) => u.state == ChatUploadState.ready)) {
      await _deleteBody(item);
    }
    if (_persistence case final p?) {
      try {
        await p.files.retain(
          p.scope,
          p.partition,
          _items
              .where((u) => u.state != ChatUploadState.ready)
              .map((u) => u._handle!)
              .toSet(),
        );
      } catch (_) {
        _storageBlocked = true;
        _storageError = const ProtodeskChatException(
          'sdk.attachment_cleanup_failed',
        );
        _emit();
        throw _storageError!;
      }
    }
    _storageBlocked = false;
    _storageError = null;
    _wake();
    _emit();
  }

  Map<String, dynamic> _snapshot() => {
    'attachmentVersion': 1,
    'items': _items
        .where((u) => u._staged)
        .map(
          (u) => {
            'id': u.id,
            'conversationId': u.conversationId,
            'filename': u.filename,
            'contentType': u.contentType,
            'sizeBytes': u.sizeBytes,
            'createdAt': u.createdAt.toUtc().toIso8601String(),
            'handle': u._handle,
            'digest': u._digest,
            'state': u.state.name,
            'attempts': u._attempts,
            'remoteGeneration': u._remoteGeneration,
            'uploadId': u._uploadId,
            'attachmentId': u._attachmentId,
            'remoteExpiry': u._remoteExpiry?.toUtc().toIso8601String(),
            'retryAt': u._retryAt?.toUtc().toIso8601String(),
            'putAttempted': u._putAttempted,
            'uploaded': u._uploaded,
            if (u.error != null)
              'error': {
                'code':
                    RegExp(r'^[a-z][a-z0-9_.]{0,100}$').hasMatch(u.error!.code)
                    ? u.error!.code
                    : 'sdk.attachment_failed',
                'retryable': u.error!.retryable,
              },
          },
        )
        .toList(),
    // Separate draft envelope: text and stable logical IDs, never capabilities.
    'drafts': _drafts
        .map(
          (d) => {
            'id': d.id,
            'conversationId': d.conversationId,
            'text': d.text,
            'uploads': d.uploadIds,
          },
        )
        .toList(),
  };
  Future<ChatAttachmentUpload> uploadDurably(
    String conversationId,
    ChatAttachmentSource source,
  ) {
    final task = _stage(conversationId, source);
    final settled = task.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _preparing.add(settled);
    unawaited(settled.then((_) => _preparing.remove(settled)));
    return task;
  }

  Future<ChatAttachmentUpload> _stage(
    String conversationId,
    ChatAttachmentSource source,
  ) async {
    if (!isPersistent) return upload(conversationId, source);
    if (!_restored || _closed || _storageBlocked) {
      throw const ProtodeskChatException(
        'sdk.attachment_persistence_unavailable',
      );
    }
    if (conversationId.isEmpty ||
        conversationId.length > 128 ||
        _origins.isEmpty) {
      throw const ProtodeskChatException('chat.attachment_invalid');
    }
    if (_drafts.any((d) => d.conversationId == conversationId)) {
      throw const ProtodeskChatException('sdk.attachment_draft_frozen');
    }
    if (_items.length >= 10 ||
        _items.fold<int>(0, (n, u) => n + u.sizeBytes) + source.sizeBytes >
            64 * 1024 * 1024) {
      throw const ProtodeskChatException('sdk.attachment_queue_full');
    }
    final generation = _generation, p = _persistence!;
    final item = ChatAttachmentUpload._(
      _operationId(),
      conversationId,
      source,
      _now(),
    );
    item._staged = false;
    item._committed = false;
    item._handle = item.id;
    item._digest = sha256.convert(source.bytes).toString();
    item._state = ChatUploadState.queued;
    _items.add(item); // Reserve capacity before the first await.
    try {
      await p.files.write(p.scope, p.partition, item._handle!, source.bytes);
      final saved = await p.files.read(p.scope, p.partition, item._handle!);
      if (saved.length != source.sizeBytes ||
          sha256.convert(saved).toString() != item._digest) {
        throw const ProtodeskChatException(
          'sdk.attachment_persistence_unavailable',
        );
      }
      if (_closed || generation != _generation) {
        throw const ProtodeskChatException('chat.operation_cancelled');
      }
      item._staged = true;
      await _persist();
      if (_closed || generation != _generation) {
        throw const ProtodeskChatException('chat.operation_cancelled');
      }
      item._committed = true;
      item._source = null;
      _emit();
      _wake();
      return item;
    } catch (error) {
      _items.remove(item);
      item._source = null;
      await _deleteBody(item);
      if (error is ProtodeskChatException) rethrow;
      throw const ProtodeskChatException(
        'sdk.attachment_persistence_unavailable',
      );
    }
  }

  /// Recover a missing private copy without changing the logical operation.
  /// The replacement must match the original metadata AND byte digest.
  Future<void> replaceSource(
    ChatAttachmentUpload item,
    ChatAttachmentSource source,
  ) {
    final task = _replaceSource(item, source);
    final settled = task.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _preparing.add(settled);
    unawaited(settled.then((_) => _preparing.remove(settled)));
    return task;
  }

  Future<void> _replaceSource(
    ChatAttachmentUpload item,
    ChatAttachmentSource source,
  ) async {
    if (!isPersistent ||
        _closed ||
        _storageBlocked ||
        !_items.contains(item) ||
        item._running ||
        item.error?.code != 'sdk.attachment_source_unavailable' ||
        source.filename != item.filename ||
        source.contentType != item.contentType ||
        source.sizeBytes != item.sizeBytes ||
        sha256.convert(source.bytes).toString() != item._digest) {
      throw const ProtodeskChatException('sdk.attachment_source_unavailable');
    }
    final p = _persistence!, generation = _generation;
    await p.files.write(p.scope, p.partition, item._handle!, source.bytes);
    final bytes = await p.files.read(p.scope, p.partition, item._handle!);
    if (sha256.convert(bytes).toString() != item._digest) {
      throw const ProtodeskChatException('sdk.attachment_source_unavailable');
    }
    if (_closed || generation != _generation || !_items.contains(item)) {
      await _deleteBody(item);
      throw const ProtodeskChatException('chat.operation_cancelled');
    }
    item._state = ChatUploadState.queued;
    item._error = null;
    item._attempts = 0;
    await _persist();
    _wake();
    _emit();
  }

  Future<void> restore() async {
    if (!isPersistent || _restored) return;
    final p = _persistence!, generation = _generation;
    if (!await p.files.isAvailable()) {
      throw const ProtodeskChatException(
        'sdk.attachment_persistence_unavailable',
      );
    }
    final value = await p.load();
    if (_closed || generation != _generation) {
      throw const ProtodeskChatException('chat.operation_cancelled');
    }
    try {
      if (value != null) {
        if (value['attachmentVersion'] != 1 ||
            value['items'] is! List ||
            (value['items'] as List).length > 10) {
          throw const FormatException();
        }
        final seen = <String>{};
        var total = 0;
        for (final raw in value['items'] as List) {
          final v = Map<String, dynamic>.from(raw as Map);
          final id = v['id'] as String;
          if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(id) || !seen.add(id)) {
            throw const FormatException();
          }
          final item = ChatAttachmentUpload._restored(
            id,
            v['conversationId'] as String,
            v['filename'] as String,
            v['contentType'] as String,
            v['sizeBytes'] as int,
            DateTime.parse(v['createdAt'] as String),
          );
          if (item.conversationId.isEmpty ||
              item.conversationId.length > 128 ||
              item.sizeBytes <= 0 ||
              item.sizeBytes > 16 * 1024 * 1024 ||
              item.createdAt.isAfter(_now().add(const Duration(minutes: 5)))) {
            throw const FormatException();
          }
          // Validate metadata without allocating a body-sized buffer.
          ChatAttachmentSource(
            filename: item.filename,
            contentType: item.contentType,
            bytes: Uint8List(1),
          );
          total += item.sizeBytes;
          if (total > 64 * 1024 * 1024) throw const FormatException();
          item._handle = v['handle'] as String;
          item._digest = v['digest'] as String;
          if (item._handle != id ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(item._digest!)) {
            throw const FormatException();
          }
          item._state = ChatUploadState.values.byName(v['state'] as String);
          item._attempts = v['attempts'] as int;
          item._remoteGeneration = v['remoteGeneration'] as int;
          if (item._attempts < 0 ||
              item._attempts > 6 ||
              item._remoteGeneration < 0 ||
              item._remoteGeneration > 1000) {
            throw const FormatException();
          }
          item._uploadId = v['uploadId'] as String?;
          item._attachmentId = v['attachmentId'] as String?;
          if ((item._uploadId == null) != (item._attachmentId == null)) {
            throw const FormatException();
          }
          for (final remoteId in [item._uploadId, item._attachmentId]) {
            if (remoteId != null &&
                (remoteId.isEmpty || remoteId.length > 128)) {
              throw const FormatException();
            }
          }
          item._remoteExpiry = v['remoteExpiry'] == null
              ? null
              : DateTime.parse(v['remoteExpiry'] as String);
          item._retryAt = v['retryAt'] == null
              ? null
              : DateTime.parse(v['retryAt'] as String);
          item._uploaded = v['uploaded'] as bool;
          item._putAttempted = v['putAttempted'] as bool;
          if (item._putAttempted &&
              (item._uploadId == null || item._remoteExpiry == null)) {
            throw const FormatException();
          }
          if (v['error'] != null) {
            final code = v['error']['code'] as String;
            if (!RegExp(r'^[a-z][a-z0-9_.]{0,100}$').hasMatch(code)) {
              throw const FormatException();
            }
            item._error = ProtodeskChatException(
              code,
              retryable: v['error']['retryable'] as bool,
            );
          }
          if (!item.expiresAt.isAfter(_now()) ||
              item.state == ChatUploadState.canceled) {
            continue;
          }
          if (item.state == ChatUploadState.ready) {
            if (item._attachmentId == null) throw const FormatException();
            item._attachment = ChatAttachment.fromJson({
              'id': item._attachmentId,
              'filename': item.filename,
              'contentType': item.contentType,
              'sizeBytes': item.sizeBytes,
              'status': 'ready',
            });
          } else {
            try {
              final bytes = await p.files.read(
                p.scope,
                p.partition,
                item._handle!,
              );
              if (bytes.length != item.sizeBytes ||
                  sha256.convert(bytes).toString() != item._digest) {
                throw const FormatException();
              }
            } catch (_) {
              item._state = ChatUploadState.failed;
              item._error = const ProtodeskChatException(
                'sdk.attachment_source_unavailable',
              );
            }
            if (item._attempts >= 6 && item.state != ChatUploadState.failed) {
              item._state = ChatUploadState.failed;
              item._error = const ProtodeskChatException(
                'sdk.attachment_retry_exhausted',
                retryable: true,
              );
            }
            if (![
              ChatUploadState.failed,
              ChatUploadState.retryWait,
            ].contains(item.state)) {
              item._state = item._attempts >= 6
                  ? ChatUploadState.failed
                  : ChatUploadState.queued;
              if (item._attempts >= 6) {
                item._error = const ProtodeskChatException(
                  'sdk.attachment_retry_exhausted',
                  retryable: true,
                );
              }
            }
          }
          _items.add(item);
        }
        final drafts = value['drafts'] as List;
        if (drafts.length > 10) throw const FormatException();
        for (final d in drafts) {
          final draft = ChatAttachmentDraft(
            d['id'] as String,
            d['conversationId'] as String,
            d['text'] as String,
            List<String>.from(d['uploads'] as List),
          );
          if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(draft.id) ||
              utf8.encode(draft.text).length > 16 * 1024 ||
              draft.uploadIds.isEmpty ||
              draft.uploadIds.length > 10 ||
              draft.uploadIds.toSet().length != draft.uploadIds.length ||
              _drafts.any((d) => d.conversationId == draft.conversationId)) {
            throw const FormatException();
          }
          // Expiration discards the entire draft, never a partial attachment send.
          if (draft.uploadIds.every(
            (id) => _items.any(
              (u) =>
                  u.id == id &&
                  u.conversationId == draft.conversationId &&
                  u.state == ChatUploadState.ready,
            ),
          )) {
            _drafts.add(draft);
          }
        }
      }
      if (_closed || generation != _generation) {
        throw const ProtodeskChatException('chat.operation_cancelled');
      }
      await _persist();
      await p.files.retain(
        p.scope,
        p.partition,
        _items
            .where((u) => u.state != ChatUploadState.ready)
            .map((u) => u._handle!)
            .toSet(),
      );
      _restored = true;
      _scheduleExpiry();
      _emit();
    } on ProtodeskChatException {
      rethrow;
    } catch (_) {
      throw const ProtodeskChatException('sdk.attachment_journal_corrupt');
    }
  }

  void _scheduleExpiry() {
    if (_closed || !isPersistent || _items.isEmpty) return;
    final next = _items
        .map((u) => u.expiresAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    _timer?.cancel();
    _timer = Timer(
      next.difference(_now()).isNegative
          ? Duration.zero
          : next.difference(_now()),
      () {
        unawaited(
          _expire().then(
            (_) => _wake(),
            onError: (Object _) {
              _emit();
            },
          ),
        );
      },
    );
  }

  Future<void> _expire() async {
    final expired = _items.where((u) => !u.expiresAt.isAfter(_now())).toList();
    for (final item in expired) {
      await cancel(item);
    }
  }

  void _wake() {
    if (_closed || !isPersistent || !_restored) return;
    _timer?.cancel();
    _scheduleExpiry();
    if (!_active || !_available() || _storageBlocked) return;
    for (final item in _items.toList()) {
      if (_items.where((u) => u._running).length + _downloads.length >= 3) {
        break;
      }
      if (!item._committed ||
          item._attempts >= 6 ||
          item._running ||
          !item.expiresAt.isAfter(_now()) ||
          ![
            ChatUploadState.queued,
            ChatUploadState.retryWait,
          ].contains(item.state)) {
        continue;
      }
      if (item._retryAt != null && item._retryAt!.isAfter(_now())) continue;
      item._cancel = ChatTransferCancellation();
      item._pending = _run(item);
    }
    final deadlines = _items
        .where(
          (u) =>
              !u._running &&
              u.state == ChatUploadState.retryWait &&
              u._retryAt != null,
        )
        .map((u) => u._retryAt!)
        .where((d) => d.isAfter(_now()))
        .toList();
    if (deadlines.isNotEmpty) {
      final retry = deadlines.reduce((a, b) => a.isBefore(b) ? a : b);
      final expiry = _items
          .map((u) => u.expiresAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      if (retry.isBefore(expiry)) {
        _timer?.cancel();
        _timer = Timer(retry.difference(_now()), _wake);
      }
    }
  }

  /// Freeze the complete attachment message before POST. Retry after restart uses
  /// the same derived message UUID and ordered IDs; it never reuploads ready files.
  Future<ChatMessage> send(
    String conversationId,
    String text,
    List<ChatAttachmentUpload> items,
  ) async {
    if (_send == null ||
        _sending.contains(conversationId) ||
        _storageBlocked ||
        _closed ||
        !_available()) {
      throw const ProtodeskChatException('sdk.attachment_send_unavailable');
    }
    if (items.isEmpty ||
        items.length > 10 ||
        items.toSet().length != items.length ||
        utf8.encode(text).length > 16 * 1024 ||
        items.any(
          (u) =>
              !_items.contains(u) ||
              u.conversationId != conversationId ||
              u.state != ChatUploadState.ready ||
              !u.expiresAt.isAfter(_now()),
        )) {
      throw const ProtodeskChatException('chat.attachment_invalid');
    }
    var draft = _drafts
        .where((d) => d.conversationId == conversationId)
        .firstOrNull;
    final ids = items.map((u) => u.id).toList();
    if (draft != null &&
        (draft.text != text ||
            jsonEncode(draft.uploadIds) != jsonEncode(ids))) {
      throw const ProtodeskChatException('sdk.attachment_draft_frozen');
    }
    draft ??= ChatAttachmentDraft(_operationId(), conversationId, text, ids);
    _sending.add(conversationId);
    final generation = _generation;
    try {
      if (!_drafts.contains(draft)) {
        _drafts.add(draft);
        await _persist();
      }
      if (_closed || generation != _generation) {
        throw const ProtodeskChatException('chat.operation_cancelled');
      }
      final hex = sha256
          .convert(utf8.encode('attachment-message:${draft.id}'))
          .toString();
      final messageId =
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}-a${hex.substring(17, 20)}-${hex.substring(20, 32)}';
      if (_storageBlocked || !_available() || (isPersistent && !_active)) {
        throw const ProtodeskChatException('sdk.attachment_send_unavailable');
      }
      final result = await _send(
        conversationId,
        messageId,
        text,
        items.map((u) => u.attachment!.id).toList(),
      );
      if (_closed || generation != _generation) {
        throw const ProtodeskChatException('chat.operation_cancelled');
      }
      // Keep the retry authority until removal is durably committed.
      _items.removeWhere(items.contains);
      _drafts.remove(draft);
      try {
        await _persist();
      } catch (_) {
        _items.addAll(items);
        _drafts.add(draft);
        rethrow;
      }
      for (final item in items) {
        item._source = null;
      }
      _emit();
      return result;
    } finally {
      _sending.remove(conversationId);
    }
  }
}
