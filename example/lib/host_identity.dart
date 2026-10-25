import 'dart:async';
import 'dart:convert';
import 'dart:io';

Uri requireHttps(String value, {bool originOnly = false}) {
  final uri = Uri.parse(value);
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (originOnly &&
          (uri.hasQuery || (uri.path.isNotEmpty && uri.path != '/')))) {
    throw const FormatException('Expected an HTTPS endpoint or origin.');
  }
  return uri;
}

/// Replace with your existing authenticated host API client in a real app.
abstract interface class HostIdentity {
  String get identityKey;
  Future<void> connect();
  Future<String> freshToken();
  void close();
}

/// GET resolves the logged-in host account; POST mints a fresh, single-use token.
/// No redirects, credential persistence, response logging or automatic retries.
class HttpHostIdentity implements HostIdentity {
  HttpHostIdentity(Uri endpoint, String session)
    : _endpoint = requireHttps(endpoint.toString()),
      _session = session;
  final Uri _endpoint;
  String? _session;
  String? _identityKey;
  final _client = HttpClient();
  @override
  String get identityKey => _identityKey ?? (throw StateError('Not connected'));

  @override
  Future<void> connect() async {
    final data = await _request('GET');
    _identityKey = _requiredString(data, 'identityKey');
  }

  @override
  Future<String> freshToken() async {
    final expected = identityKey;
    final data = await _request('POST');
    if (_requiredString(data, 'identityKey') != expected) {
      close();
      throw StateError('Host account changed. Reopen chat after signing in.');
    }
    return _requiredString(data, 'token');
  }

  String _requiredString(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is! String || value.trim().isEmpty || value.length > 32768) {
      throw const FormatException('Invalid host identity response');
    }
    return value;
  }

  Future<Map<String, dynamic>> _request(String method) async {
    final session = _session;
    if (session == null) throw StateError('Host session closed');
    try {
      return await (() async {
        final request = await _client.openUrl(method, _endpoint);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $session');
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close();
        if (response.statusCode != 200) {
          throw const HttpException('Host identity request failed');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 65536) {
            throw const FormatException('Host identity response too large');
          }
          bytes.addAll(chunk);
        }
        if (_session == null) throw StateError('Host session closed');
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Invalid host identity response');
        }
        return value;
      })().timeout(const Duration(seconds: 15));
    } catch (_) {
      close();
      rethrow;
    }
  }

  @override
  void close() {
    _session = null;
    _client.close(force: true);
  }
}
