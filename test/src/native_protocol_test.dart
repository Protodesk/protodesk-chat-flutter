import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart'
    show appId, session, conversation, message, until;

void main() {
  for (final verified in [false, true]) {
    test(
      'native HTTP/WebSocket ${verified ? 'verified' : 'anonymous'} customer flow against a local protocol fixture',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <WebSocket>[];
        final messages = <Map<String, dynamic>>[];
        final usedTickets = <String>{};
        var tickets = 0, revoked = false;
        final served = server.listen((request) async {
          if (request.uri.path == '/v1/chat/realtime') {
            final ticket = request.uri.queryParameters['ticket'];
            expect(ticket, isNotNull);
            expect(usedTickets.add(ticket!), isTrue);
            expect(request.uri.queryParameters.keys, ['ticket']);
            final socket = await WebSocketTransformer.upgrade(request);
            sockets.add(socket);
            socket.listen((raw) {
              final frame = jsonDecode(raw as String) as Map<String, dynamic>;
              expect(frame['type'], 'realtime.resume');
              socket.add(
                jsonEncode({
                  'type': 'realtime.ready',
                  'protocolVersion': 1,
                  'cursor': frame['cursor'],
                }),
              );
            });
            return;
          }
          final raw = await utf8.decoder.bind(request).join();
          final body = raw.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(raw) as Map<String, dynamic>;
          Object response = {};
          if (request.uri.path ==
              (verified
                  ? '/v1/chat/sessions'
                  : '/v1/chat/sessions/anonymous')) {
            if (verified) {
              expect(body['identityToken'], 'host-issued-token');
            } else {
              expect(body['installationId'], isNotEmpty);
              expect(body.containsKey('identityToken'), isFalse);
            }
            response = session();
          } else {
            expect(request.headers.value('authorization'), 'Bearer access');
            if (request.uri.path.endsWith('/realtime/ticket')) {
              response = {'ticket': 'crt_local_${++tickets}'};
            } else if (request.method == 'DELETE') {
              revoked = true;
              request.response.statusCode = 204;
            } else if (request.uri.path.endsWith('/messages')) {
              if (request.method == 'POST') {
                expect(
                  request.headers.value('idempotency-key'),
                  body['clientMessageId'],
                );
                final m = message(
                  text: body['body'] as String,
                  clientId: body['clientMessageId'] as String,
                );
                messages.add(m);
                response = m;
                for (final socket in sockets) {
                  socket.add(
                    jsonEncode({
                      'type': 'realtime.event',
                      'protocolVersion': 1,
                      'cursor': 'cursor-1',
                      'event': {
                        'id': 'evt_1',
                        'type': 'message.created',
                        'data': {'schemaVersion': 1, 'message': m},
                      },
                    }),
                  );
                }
              } else {
                response = {
                  'data': messages,
                  'hasMore': false,
                  'nextCursor': null,
                };
              }
            } else if (request.uri.path.endsWith('/conversations')) {
              response = request.method == 'POST'
                  ? conversation()
                  : {
                      'data': [conversation()],
                      'hasMore': false,
                      'nextCursor': null,
                    };
            } else {
              request.response.statusCode = 404;
            }
          }
          request.response.headers.contentType = ContentType.json;
          if (request.response.statusCode != 204)
            request.response.write(jsonEncode(response));
          await request.response.close();
        });
        final client = await initializeChat(
          ChatClientOptions(
            publicChatAppId: appId,
            baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
            identityTokenProvider: verified
                ? () async => 'host-issued-token'
                : null,
          ),
        );
        try {
          final conversation = await client.createConversation(
            idempotencyKey: 'create-once',
          );
          await client.connect();
          await until(
            () => client.connectionState == ChatConnectionState.connected,
          );
          final event = client.events.first;
          await client.sendMessage(
            conversationId: conversation.id,
            clientMessageId: 'message-once',
            text: 'Hello wire',
          );
          expect(
            (await event.timeout(const Duration(seconds: 2))).type,
            'message.created',
          );
          expect(
            (await client.listMessages(conversation.id)).data.single.text,
            'Hello wire',
          );
          sockets.first.add(
            jsonEncode({
              'type': 'realtime.drain',
              'protocolVersion': 1,
              'reconnectAfterMs': 1,
            }),
          );
          await until(
            () =>
                tickets == 2 &&
                client.connectionState == ChatConnectionState.connected,
          );
          await client.logout();
          expect(revoked, isTrue);
          expect(client.state, ChatClientState.signedOut);
        } finally {
          await client.dispose();
          for (final socket in sockets) {
            await socket.close();
          }
          await served.cancel();
          await server.close(force: true);
        }
      },
    );
  }
}
