import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat_example/host_identity.dart';

class Headers implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Response extends Stream<List<int>> implements HttpClientResponse {
  Response(this.body, this.statusCode);
  final String body;
  @override
  final int statusCode;
  @override
  listen(
    onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Request implements HttpClientRequest {
  Request(this.response);
  final Response response;
  @override
  final Headers headers = Headers();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Client implements HttpClient {
  final responses = <Response>[];
  final methods = <String>[];
  final requests = <Request>[];
  bool closed = false;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    methods.add(method);
    final request = Request(responses.removeAt(0));
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'HTTPS configuration rejects credentials, fragments, and non-origin paths',
    () {
      for (final value in [
        'http://host.test',
        'https://user:secret@host.test',
        'https://host.test/#secret',
        'https://host.test/path',
      ]) {
        expect(
          () => requireHttps(value, originOnly: true),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'host handshake and every token request authenticate without redirects',
    () async {
      final client = Client()
        ..responses.addAll([
          Response('{"identityKey":"account"}', 200),
          Response('{"identityKey":"account","token":"one"}', 200),
          Response('{"identityKey":"account","token":"two"}', 200),
          Response('{"identityKey":"other","token":"wrong"}', 200),
        ]);
      await HttpOverrides.runZoned(() async {
        final identity = HttpHostIdentity(
          Uri.parse('https://host.test/chat'),
          'session',
        );
        await identity.connect();
        expect(identity.identityKey, 'account');
        expect(await identity.freshToken(), 'one');
        expect(await identity.freshToken(), 'two');
        await expectLater(identity.freshToken(), throwsStateError);
        expect(client.closed, isTrue);
        expect(client.methods, ['GET', 'POST', 'POST', 'POST']);
        for (final request in client.requests) {
          expect(request.followRedirects, isFalse);
          expect(
            request.headers.values[HttpHeaders.authorizationHeader],
            'Bearer session',
          );
        }
        await expectLater(identity.freshToken(), throwsStateError);
        expect(client.requests, hasLength(4));
      }, createHttpClient: (_) => client);
    },
  );
  for (final response in [
    Response('{}', 401),
    Response('{}', 302),
    Response('[]', 200),
    Response('x' * 65537, 200),
  ]) {
    test(
      'rejects failed, redirected, malformed or oversized host response ${response.statusCode}/${response.body.length}',
      () async {
        final client = Client()..responses.add(response);
        await HttpOverrides.runZoned(() async {
          final identity = HttpHostIdentity(
            Uri.parse('https://host.test/chat'),
            'session',
          );
          await expectLater(identity.connect(), throwsA(anything));
          expect(client.closed, isTrue);
        }, createHttpClient: (_) => client);
      },
    );
  }
}
