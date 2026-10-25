import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

final class ChatResponse {
  const ChatResponse(this.status, this.body, {this.retryAfter});
  final int status;
  final Map<String, dynamic> body;
  final Duration? retryAfter;
}

abstract interface class ChatSocket {
  Stream<Object?> get frames;
  int? get closeCode;
  void send(String frame);
  Future<void> close();
}

/// The client owns and closes its transport. Inject one only for a trusted host
/// integration or tests: it receives session credentials.
abstract interface class ChatTransport {
  Future<ChatResponse> request(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  );
  Future<ChatSocket> connect(Uri uri);
  void close();
}

final class NativeChatTransport implements ChatTransport {
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  static const _timeout = Duration(seconds: 30);

  @override
  Future<ChatResponse> request(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    HttpClientRequest? request;
    try {
      return await (() async {
        request = await _http.openUrl(method, uri);
        request!.followRedirects = false;
        headers.forEach((key, value) => request!.headers.set(key, value));
        if (body != null) {
          request!.headers.contentType = ContentType.json;
          request!.write(jsonEncode(body));
        }
        final response = await request!.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 2 * 1024 * 1024) {
            request!.abort();
            throw const ProtodeskChatException('chat.response_too_large');
          }
        }
        final seconds = int.tryParse(
          response.headers.value('retry-after') ?? '',
        );
        final decoded = bytes.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(utf8.decode(bytes));
        return ChatResponse(
          response.statusCode,
          decoded as Map<String, dynamic>,
          retryAfter: seconds == null
              ? null
              : Duration(seconds: seconds.clamp(0, 3600)),
        );
      })().timeout(_timeout);
    } on ProtodeskChatException {
      rethrow;
    } on FormatException {
      throw const ProtodeskChatException('chat.invalid_response');
    } on TypeError {
      throw const ProtodeskChatException('chat.invalid_response');
    } catch (_) {
      request?.abort();
      throw const ProtodeskChatException(
        'chat.network_unavailable',
        retryable: true,
      );
    }
  }

  @override
  Future<ChatSocket> connect(Uri uri) async {
    try {
      // A late handshake must be closed if the connection deadline wins.
      final pending = WebSocket.connect(uri.toString());
      var expired = false;
      pending.then((socket) {
        if (expired) unawaited(socket.close());
      }, onError: (Object _) {});
      final socket = await pending.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          expired = true;
          throw const ProtodeskChatException(
            'chat.realtime_timeout',
            retryable: true,
          );
        },
      );
      socket.pingInterval = const Duration(seconds: 30);
      return _NativeSocket(socket);
    } catch (_) {
      throw const ProtodeskChatException(
        'chat.realtime_unavailable',
        retryable: true,
      );
    }
  }

  @override
  void close() => _http.close(force: true);
}

final class _NativeSocket implements ChatSocket {
  _NativeSocket(this.socket);
  final WebSocket socket;
  @override
  Stream<Object?> get frames => socket;
  @override
  int? get closeCode => socket.closeCode;
  @override
  void send(String frame) => socket.add(frame);
  @override
  Future<void> close() async {
    try {
      await socket.close().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    } catch (_) {
      // Closing a failed socket must not resurrect the reconnect loop.
    }
  }
}
