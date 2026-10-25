import 'dart:convert';

typedef ChatIdentityTokenProvider = Future<String> Function();

enum ChatClientState { initializing, ready, signedOut, failed, disposed }

enum ChatIdentityKind { anonymous, verified }

/// Recovery signs into the target but cannot prove whether a lost merge committed.
enum ChatIdentityMergeOutcome { confirmed, recoveredUnconfirmed }

enum ChatConnectionState { disconnected, connecting, connected, reconnecting }

final class ProtodeskChatException implements Exception {
  const ProtodeskChatException(
    this.code, {
    this.retryable = false,
    this.status,
    this.retryAfter,
  });
  final String code;
  final bool retryable;
  final int? status;
  final Duration? retryAfter;
  // Deliberately omit response bodies, URLs, credentials and transport exceptions.
  @override
  String toString() => 'ProtodeskChatException($code)';
}

final class ChatPage<T> {
  const ChatPage(this.data, {required this.hasMore, this.nextCursor});
  final List<T> data;
  final bool hasMore;
  final String? nextCursor;
}

final class ChatConversation {
  ChatConversation.fromJson(Map<String, dynamic> json)
    : _json = Map<String, dynamic>.unmodifiable(json),
      id = json['id'] as String,
      subject = json['subject'] as String,
      status = json['status'] as String,
      unreadCount = json['unreadCount'] as int,
      unreadCountIsStale = json['unreadCountIsStale'] as bool? ?? false,
      context = ChatConversationContext.parse(json['context']),
      updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
  final Map<String, dynamic> _json;
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(_json);
  final String id, subject, status;
  final int unreadCount;

  /// A message event invalidated this count without supplying a new total.
  /// Refresh conversations before displaying it as an authoritative badge.
  final bool unreadCountIsStale;

  /// Immutable business context recorded when the conversation was created.
  final ChatConversationContext context;

  /// Last activity, when the server provided a valid timestamp.
  final DateTime? updatedAt;
}

/// Who vouched for conversation context. Only server provenance is verified.
enum ChatContextProvenance {
  clientUnverified('client_unverified'),
  serverVerified('server_verified'),
  externalObjectVerified('external_object_verified'),

  /// A newer server value. Treated as unverified until the SDK knows it.
  unknown('');

  const ChatContextProvenance(this.wireValue);
  final String wireValue;

  bool get isVerified =>
      this == serverVerified || this == externalObjectVerified;

  static ChatContextProvenance parse(Object? value) => values.firstWhere(
    (provenance) => provenance != unknown && provenance.wireValue == value,
    orElse: () => unknown,
  );
}

/// Customer-safe context the server returned. Display only; never authority.
final class ChatConversationContext {
  ChatConversationContext._(this.provenance, this.screen, this.metadata);

  /// Missing or malformed context (older caches/servers) is empty and unverified.
  factory ChatConversationContext.parse(Object? value) {
    if (value is! Map) return empty;
    final screen = value['screen'];
    final metadata = value['metadata'];
    return ChatConversationContext._(
      ChatContextProvenance.parse(value['provenance']),
      screen is String && screen.trim().isNotEmpty ? screen : null,
      Map.unmodifiable({
        if (metadata is Map)
          for (final entry in metadata.entries)
            if (entry.key is String && _isMetadataScalar(entry.value))
              entry.key as String: entry.value,
      }),
    );
  }

  static final empty = ChatConversationContext._(
    ChatContextProvenance.clientUnverified,
    null,
    const {},
  );

  final ChatContextProvenance provenance;
  final String? screen;
  final Map<String, Object?> metadata;
  bool get isEmpty => screen == null && metadata.isEmpty;
}

/// Unverified context an app attaches when creating a conversation.
/// Limits mirror the server so invalid input fails before any request.
final class ChatCreateConversationContext {
  ChatCreateConversationContext({
    String? screen,
    Map<String, Object?> metadata = const {},
  }) : screen = screen?.trim(),
       metadata = Map.unmodifiable(metadata) {
    validate();
  }

  static final _key = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');
  static const _credentialFragments = [
    'token',
    'secret',
    'password',
    'authorization',
    'credential',
    'api_key',
    'apikey',
    'cookie',
    'private_key',
    'privatekey',
  ];

  final String? screen;
  final Map<String, Object?> metadata;

  /// Throws `chat.context_invalid`. Credential-like keys are rejected, never sent.
  void validate() {
    final screen = this.screen ?? '';
    final valid =
        screen.runes.length <= 128 &&
        metadata.length <= 24 &&
        metadata.entries.every((entry) {
          final normalized = entry.key
              .toLowerCase()
              .replaceAll('-', '_')
              .replaceAll('.', '_');
          final value = entry.value;
          return _key.hasMatch(entry.key) &&
              !_credentialFragments.any(normalized.contains) &&
              _isMetadataScalar(value) &&
              (value is! String || value.runes.length <= 1024);
        }) &&
        utf8.encode(jsonEncode(toJson())).length <= 4096;
    if (!valid) throw const ProtodeskChatException('chat.context_invalid');
  }

  Map<String, Object?> toJson() => {
    if (screen != null && screen!.isNotEmpty) 'screen': screen,
    'metadata': metadata,
  };
}

/// A lookup reference only. The server rejects it until it can prove ownership.
final class ChatExternalObjectReference {
  ChatExternalObjectReference({required this.type, required this.externalId}) {
    if (type.isEmpty ||
        type.length > 64 ||
        externalId.isEmpty ||
        externalId.length > 255) {
      throw const ProtodeskChatException('chat.external_object_invalid');
    }
  }
  final String type, externalId;
  Map<String, String> toJson() => {'type': type, 'externalId': externalId};
}

/// Optional, self-reported follow-up email for one conversation.
/// It is never identity proof and never changes the signed-in account.
final class ChatContact {
  ChatContact.fromJson(Map<String, dynamic> json)
    : email = json['email'] as String,
      dismissed = json['dismissed'] as bool,
      canRequest = json['canRequest'] as bool {
    if (json.length != 3) throw const FormatException('Unexpected contact');
  }
  final String email;
  final bool dismissed;

  /// True only while the server would accept a new email or dismissal.
  final bool canRequest;
  bool get hasEmail => email.isNotEmpty;
}

bool _isMetadataScalar(Object? value) =>
    value == null ||
    value is String ||
    value is bool ||
    value is int ||
    (value is double && value.isFinite);

final class ChatMessage {
  ChatMessage.fromJson(Map<String, dynamic> json)
    : _json = Map<String, dynamic>.unmodifiable(json),
      id = json['id'] as String,
      conversationId = json['conversationId'] as String,
      clientMessageId = json['clientMessageId'] as String?,
      text = json['body'] as String,
      sender = json['sender'] as String,
      status = json['status'] as String,
      createdAt = DateTime.parse(json['createdAt'] as String);
  final Map<String, dynamic> _json;
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(_json);
  final String id, conversationId, text, sender, status;
  List<ChatAttachment> get attachments => List.unmodifiable(
    (_json['attachments'] as List? ?? const []).map(
      (value) =>
          ChatAttachment.fromJson(Map<String, dynamic>.from(value as Map)),
    ),
  );
  final String? clientMessageId;
  final DateTime createdAt;
}

final class ChatServerEvent {
  ChatServerEvent.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      type = json['type'] as String,
      data = Map<String, dynamic>.unmodifiable(json['data'] as Map);
  final String id, type;
  final Map<String, dynamic> data;
}

final class ChatAttachment {
  ChatAttachment.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      filename = json['filename'] as String,
      contentType = json['contentType'] as String,
      sizeBytes = json['sizeBytes'] as int,
      status = json['status'] as String;
  final String id, filename, contentType, status;
  final int sizeBytes;
}

/// Server-authoritative read cursor and count at the time of the response.
final class ChatReadState {
  ChatReadState.fromJson(Map<String, dynamic> json)
    : conversationId = json['conversationId'] as String,
      throughMessageId = json['throughMessageId'] as String,
      readAt = DateTime.parse(json['readAt'] as String),
      unreadCount = json['unreadCount'] as int;
  final String conversationId, throughMessageId;
  final DateTime readAt;
  final int unreadCount;
}

/// Customer-safe typing actor. Legacy actor-less frames remain customer signals.
final class ChatTypingActor {
  const ChatTypingActor(this.kind, {this.id});
  final String kind;
  final String? id;
  static ChatTypingActor parse(Object? value) {
    if (value == null) return const ChatTypingActor('customer');
    if (value is! Map) throw const FormatException();
    if (value['kind'] == 'customer' && value['id'] == null)
      return const ChatTypingActor('customer');
    if (value['kind'] == 'agent' &&
        value['id'] is String &&
        RegExp(r'^actor_[a-f0-9]{64}$').hasMatch(value['id'] as String)) {
      return ChatTypingActor('agent', id: value['id'] as String);
    }
    throw const FormatException();
  }
}

final class ChatTypingState {
  const ChatTypingState(
    this.conversationId,
    this.typing,
    this.occurredAt,
    this.expiresAt, {
    this.actor = const ChatTypingActor('customer'),
  });
  ChatTypingState.fromJson(Map<String, dynamic> json)
    : conversationId = json['conversationId'] as String,
      typing = json['typing'] as bool,
      occurredAt = DateTime.parse(json['occurredAt'] as String),
      expiresAt = DateTime.parse(json['expiresAt'] as String),
      actor = ChatTypingActor.parse(json['actor']);
  final String conversationId;
  final bool typing;
  final DateTime occurredAt, expiresAt;
  final ChatTypingActor actor;
  String get stateKey => '$conversationId:${actor.kind}:${actor.id ?? ""}';
  ChatTypingState withTyping(bool value) => ChatTypingState(
    conversationId,
    value,
    occurredAt,
    expiresAt,
    actor: actor,
  );
}
