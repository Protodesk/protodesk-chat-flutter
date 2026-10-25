import 'dart:async';
import 'dart:convert';

import 'package:protodesk_chat/protodesk_chat.dart';

const appId = 'chat_test_abcdefghijklmnopqrstuvwxyz';
Map<String, dynamic> session({bool expired = false, String token = 'access'}) =>
    {
      'accessToken': token,
      'refreshToken': 'refresh-$token',
      'accessExpiresAt': DateTime.now()
          .add(Duration(hours: expired ? -1 : 1))
          .toUtc()
          .toIso8601String(),
    };
Map<String, dynamic> conversation() => {
  'id': 'conv_test',
  'subject': 'Support',
  'status': 'open',
  'unreadCount': 0,
  'context': {
    'provenance': 'client_unverified',
    'screen': 'order_details',
    'metadata': {'entryPoint': 'help_button'},
  },
  'createdAt': '2026-10-25T00:00:00Z',
  'updatedAt': '2026-10-25T00:00:00Z',
};
Map<String, dynamic> message({
  String text = 'Hello',
  String id = 'msg_test',
  String? clientId,
}) => {
  'id': id,
  'conversationId': 'conv_test',
  'clientMessageId': clientId,
  'body': text,
  'sender': 'endUser',
  'status': 'delivered',
  'createdAt': '2026-10-25T00:00:00Z',
  'updatedAt': '2026-10-25T00:00:00Z',
};

final class Call {
  Call(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Map<String, dynamic>? body;
}

class FakeTransport implements ChatTransport {
  final calls = <Call>[];
  final sockets = <FakeSocket>[];
  final socketUris = <Uri>[];
  Future<ChatResponse> Function(Call)? handler;
  final messages = <Map<String, dynamic>>[];
  // Server contact state; POST saves follow the backend's empty-only rule.
  Map<String, dynamic> contact = {
    'email': '',
    'dismissed': false,
    'canRequest': false,
  };
  bool closed = false;
  @override
  Future<ChatResponse> request(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    final call = Call(method, uri, headers, body);
    calls.add(call);
    if (handler != null) return handler!(call);
    return respond(call);
  }

  ChatResponse respond(Call call) {
    final path = call.uri.path;
    if (path.contains('/sessions') && call.method == 'POST')
      return ChatResponse(201, session());
    if (path.endsWith('/bootstrap'))
      return const ChatResponse(200, {
        'unreadCount': 0,
        'capabilities': {'typing': true},
      });
    if (path.endsWith('/realtime/ticket'))
      return ChatResponse(201, {'ticket': 'ticket-${calls.length}'});
    if (path.endsWith('/messages')) {
      if (call.method == 'POST') {
        final id = call.body!['clientMessageId'] as String;
        final existing = messages.where((m) => m['clientMessageId'] == id);
        if (existing.isNotEmpty) return ChatResponse(201, existing.first);
        final m = message(text: call.body!['body'] as String, clientId: id);
        messages.add(m);
        return ChatResponse(201, m);
      }
      return ChatResponse(200, {
        'data': messages,
        'hasMore': false,
        'nextCursor': null,
      });
    }
    if (path.endsWith('/contact')) {
      if (call.method == 'POST') {
        final email = call.body!['email'] as String?;
        contact = {
          'email': email ?? contact['email'],
          'dismissed': email == null,
          'canRequest': false,
        };
      }
      return ChatResponse(200, Map.of(contact));
    }
    if (path.endsWith('/conversations/conv_test'))
      return ChatResponse(200, conversation());
    if (path.endsWith('/conversations'))
      return call.method == 'POST'
          ? ChatResponse(201, conversation())
          : ChatResponse(200, {
              'data': [conversation()],
              'hasMore': false,
              'nextCursor': null,
            });
    return const ChatResponse(204, {});
  }

  @override
  Future<ChatSocket> connect(Uri uri) async {
    socketUris.add(uri);
    final socket = FakeSocket();
    sockets.add(socket);
    return socket;
  }

  @override
  void close() {
    closed = true;
  }
}

class FakeSocket implements ChatSocket {
  final controller = StreamController<Object?>();
  final sent = <Map<String, dynamic>>[];
  int? code;
  @override
  int? get closeCode => code;
  @override
  Stream<Object?> get frames => controller.stream;
  @override
  void send(String frame) {
    sent.add(jsonDecode(frame) as Map<String, dynamic>);
  }

  void emit(String type, [Map<String, dynamic> data = const {}]) {
    controller.add(jsonEncode({'type': type, 'protocolVersion': 1, ...data}));
  }

  @override
  Future<void> close() async {
    if (!controller.isClosed) unawaited(controller.close());
  }
}

Future<ProtodeskChatClient> makeClient(
  FakeTransport transport, {
  ChatIdentityTokenProvider? provider,
  ChatSendQueueOptions queueOptions = const ChatSendQueueOptions(),
  ChatCreateConversationContext? initialContext,
}) => initializeChat(
  ChatClientOptions(
    publicChatAppId: appId,
    baseUrl: Uri.parse('https://api.example.test'),
    transport: transport,
    identityTokenProvider: provider,
    sendQueueOptions: queueOptions,
    initialContext: initialContext,
  ),
);
Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Timed out waiting for test condition');
}
