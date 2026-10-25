import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/fake_transport.dart';

class SecureMemory implements ChatStorageAdapter {
  final values = <String, String>{};
  bool failWrite = false, failRead = false;
  @override
  bool get isPlatformSecure => true;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('private keychain error');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('private keychain error');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  Map<String, dynamic> get only =>
      jsonDecode(values.values.single) as Map<String, dynamic>;
}

Map<String, dynamic> anonymous({
  int generation = 1,
  String? secret = 'proof-1',
  bool ack = true,
}) => {
  ...session(),
  'anonymousIdentity': {
    'generation': generation,
    'acknowledgementRequired': ack,
    if (secret != null) 'resumeSecret': secret,
  },
};
Future<ProtodeskChatClient> stored(
  SecureMemory storage,
  FakeTransport transport, {
  bool create = false,
  bool recover = false,
  String? account,
  ChatIdentityTokenProvider? provider,
}) => initializeChat(
  ChatClientOptions(
    publicChatAppId: appId,
    baseUrl: Uri.parse('https://api.example.test'),
    storage: storage,
    transport: transport,
    allowNewAnonymousIdentity: create,
    recoverLostAnonymousIdentity: recover,
    identityKey: account,
    identityTokenProvider: provider,
  ),
);
Matcher code(String value) =>
    isA<ProtodeskChatException>().having((e) => e.code, 'code', value);
void main() {
  test(
    'silent platform write loss fails read-back before any session is created',
    () async {
      final storage = DiscardingStorage(), transport = FakeTransport();
      await expectLater(
        stored(storage, transport, create: true),
        throwsA(code('chat.storage_unavailable')),
      );
      expect(transport.calls, isEmpty);
    },
  );

  test('explicit recovery can replace a server-revoked proof after reset-marker loss', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    var revoked = false;
    transport.handler = (call) async {
      if (call.method == 'DELETE' && revoked)
        return const ChatResponse(401, {
          'error': {'code': 'chat.session_revoked'},
        });
      if (call.uri.path.endsWith('/anonymous')) {
        if (revoked && call.body?['resumeSecret'] != null)
          return const ChatResponse(401, {
            'error': {'code': 'chat.anonymous_resume_invalid'},
          });
        return ChatResponse(201, anonymous());
      }
      return transport.respond(call);
    };
    await (await stored(storage, transport, create: true)).dispose();
    final id = storage.only['installationId'];
    revoked = true;
    await expectLater(
      stored(storage, transport),
      throwsA(code('chat.anonymous_resume_invalid')),
    );
    await (await stored(storage, transport, recover: true)).dispose();
    expect(storage.only['installationId'], isNot(id));
  });

  test(
    'logout wins over a delayed refresh write and dispose waits for clearing',
    () async {
      final storage = BlockingStorage(), transport = FakeTransport();
      transport.handler = (call) async {
        if (call.uri.path == '/v1/chat/sessions')
          return ChatResponse(201, session(expired: true));
        if (call.uri.path.endsWith('/refresh'))
          return ChatResponse(200, session(token: 'rotated'));
        return transport.respond(call);
      };
      final client = await stored(
        storage,
        transport,
        account: 'alice',
        provider: () async => 'token',
      );
      final read = client.listConversations();
      final cancelled = expectLater(
        read,
        throwsA(code('chat.operation_cancelled')),
      );
      await storage.entered.future;
      final logout = client.logout();
      final disposing = client.dispose();
      storage.release.complete();
      await Future.wait([logout, disposing, cancelled]);
      expect(storage.only['session'], null);
      expect(storage.values.values.single.contains('rotated'), false);
    },
  );

  test(
    'logout waits for a late verified exchange and revokes it before returning',
    () async {
      final storage = SecureMemory(), transport = FakeTransport();
      final exchange = Completer<ChatResponse>();
      transport.handler = (call) async {
        if (call.uri.path == '/v1/chat/sessions' &&
            call.body?['identityToken'] == 'second')
          return exchange.future;
        return transport.respond(call);
      };
      final client = await stored(
        storage,
        transport,
        account: 'alice',
        provider: () async => 'first',
      );
      final changing = client.identify(
        () async => 'second',
        identityKey: 'bob',
      );
      final cancelled = expectLater(
        changing,
        throwsA(code('chat.operation_cancelled')),
      );
      await until(
        () => transport.calls.any((c) => c.body?['identityToken'] == 'second'),
      );
      var loggedOut = false;
      final logout = client.logout().then((_) => loggedOut = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(loggedOut, false);
      exchange.complete(ChatResponse(201, session(token: 'late-issued')));
      await logout;
      await cancelled;
      expect(
        transport.calls.any(
          (c) =>
              c.method == 'DELETE' &&
              c.headers['Authorization'] == 'Bearer late-issued',
        ),
        true,
      );
      expect(
        storage.values.values.any((v) => v.contains('late-issued')),
        false,
      );
      await client.dispose();
    },
  );
  test(
    'reset clears visible access even when storing the reset marker fails',
    () async {
      final storage = SecureMemory(), transport = FakeTransport();
      transport.handler = (call) async => call.uri.path.endsWith('/anonymous')
          ? ChatResponse(201, anonymous())
          : transport.respond(call);
      final client = await stored(storage, transport, create: true);
      storage.failWrite = true;
      await expectLater(
        client.resetAnonymousIdentity(),
        throwsA(code('chat.storage_unavailable')),
      );
      expect(client.state, ChatClientState.signedOut);
      expect(client.connectionState, ChatConnectionState.disconnected);
      await expectLater(
        client.listConversations(),
        throwsA(code('chat.session_required')),
      );
      await client.dispose();
    },
  );
  test('lost proof with usable stored access resets the server binding before replacement', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    transport.handler = (call) async => call.uri.path.endsWith('/anonymous')
        ? ChatResponse(201, anonymous())
        : transport.respond(call);
    await (await stored(storage, transport, create: true)).dispose();
    final record = storage.only;
    final id = record['installationId'];
    record.remove('secret');
    record.remove('generation');
    storage.values[storage.values.keys.single] = jsonEncode(record);
    final start = transport.calls.length;
    await (await stored(storage, transport, recover: true)).dispose();
    expect(transport.calls[start].method, 'DELETE');
    expect(transport.calls[start].uri.path, '/v1/chat/anonymous-identity');
    expect(storage.only['installationId'], isNot(id));
  });
  test('lost rotation response resumes with predecessor rather than creating an identity', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    var stage = 0;
    transport.handler = (call) async {
      if (call.uri.path.endsWith('/anonymous')) {
        if (stage == 1)
          throw const ProtodeskChatException(
            'chat.network_unavailable',
            retryable: true,
          );
        if (stage == 2) {
          expect(call.body!['resumeSecret'], 'proof-1');
          expect(call.body!['resumeSecretGeneration'], 1);
        }
        return ChatResponse(
          201,
          anonymous(
            generation: stage == 2 ? 3 : 1,
            secret: stage == 2 ? 'proof-3' : 'proof-1',
          ),
        );
      }
      return transport.respond(call);
    };
    await (await stored(storage, transport, create: true)).dispose();
    final id = storage.only['installationId'];
    stage = 1;
    await expectLater(
      stored(storage, transport),
      throwsA(code('chat.network_unavailable')),
    );
    expect(storage.only['secret'], 'proof-1');
    stage = 2;
    await (await stored(storage, transport)).dispose();
    expect(storage.only['generation'], 3);
    expect(storage.only['installationId'], id);
  });
  test(
    'corrupt records require explicit recovery and never become API payloads',
    () async {
      final storage = SecureMemory(), transport = FakeTransport();
      transport.handler = (call) async => call.uri.path.endsWith('/anonymous')
          ? ChatResponse(201, anonymous())
          : transport.respond(call);
      await (await stored(storage, transport, create: true)).dispose();
      storage.values[storage.values.keys.single] = 'private-corrupt-value';
      final calls = transport.calls.length;
      await expectLater(
        stored(storage, transport),
        throwsA(code('chat.storage_corrupt')),
      );
      expect(transport.calls.length, calls);
      await (await stored(storage, transport, recover: true)).dispose();
      expect(storage.only['secret'], 'proof-1');
    },
  );
  test(
    'logout attempts server revocation even when durable token clearing fails',
    () async {
      final storage = SecureMemory(), transport = FakeTransport();
      final client = await stored(
        storage,
        transport,
        account: 'alice',
        provider: () async => 'token',
      );
      storage.failWrite = true;
      await expectLater(
        client.logout(),
        throwsA(code('chat.storage_unavailable')),
      );
      expect(client.state, ChatClientState.signedOut);
      expect(transport.calls.any((c) => c.method == 'DELETE'), true);
      await client.dispose();
    },
  );

  test('creation needs consent, saves installation before POST and proof before ACK; restart resumes', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    await expectLater(
      stored(storage, transport),
      throwsA(code('chat.anonymous_identity_missing')),
    );
    expect(transport.calls, isEmpty);
    final next = FakeTransport();
    var resumes = 0, acknowledgements = 0;
    next.handler = (call) async {
      if (call.uri.path.endsWith('/anonymous')) {
        expect(storage.only['installationId'], call.body!['installationId']);
        if (resumes++ > 0) {
          expect(call.body!['resumeSecret'], 'proof-1');
          expect(call.body!['resumeSecretGeneration'], 1);
        }
        return ChatResponse(
          201,
          anonymous(secret: resumes == 1 ? 'proof-1' : null, ack: resumes == 1),
        );
      }
      if (call.uri.path.endsWith('/acknowledge')) {
        acknowledgements++;
        expect(storage.only['secret'], 'proof-1');
        expect(storage.only['generation'], 1);
        expect(storage.only['acknowledgementRequired'], true);
      }
      return next.respond(call);
    };
    final first = await stored(storage, next, create: true);
    final installation = storage.only['installationId'];
    await first.dispose();
    final second = await stored(storage, next);
    expect(resumes, 2);
    expect(acknowledgements, 1);
    expect(storage.only['installationId'], installation);
    await second.dispose();
  });
  test('lost ACK retains replacement; next resume does not need the secret echoed again', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    var stage = 0;
    transport.handler = (call) async {
      if (call.uri.path.endsWith('/anonymous')) {
        if (stage == 0) return ChatResponse(201, anonymous());
        expect(call.body!['resumeSecret'], stage == 1 ? 'proof-1' : 'proof-2');
        return ChatResponse(
          201,
          anonymous(generation: 2, secret: stage == 1 ? 'proof-2' : null),
        );
      }
      if (call.uri.path.endsWith('/acknowledge') && stage == 1)
        throw const ProtodeskChatException(
          'chat.network_unavailable',
          retryable: true,
        );
      return transport.respond(call);
    };
    await (await stored(storage, transport, create: true)).dispose();
    stage = 1;
    await expectLater(
      stored(storage, transport),
      throwsA(code('chat.network_unavailable')),
    );
    expect(storage.only['secret'], 'proof-2');
    expect(storage.only['acknowledgementRequired'], true);
    stage = 2;
    await (await stored(storage, transport)).dispose();
    expect(storage.only['acknowledgementRequired'], false);
  });
  test(
    'lower generations cannot overwrite a stored proof or be acknowledged',
    () async {
      final storage = SecureMemory(), transport = FakeTransport();
      var generation = 2;
      transport.handler = (call) async => call.uri.path.endsWith('/anonymous')
          ? ChatResponse(
              201,
              anonymous(generation: generation, secret: 'proof-$generation'),
            )
          : transport.respond(call);
      await (await stored(storage, transport, create: true)).dispose();
      final before = storage.values.values.single;
      final acks = transport.calls
          .where((c) => c.uri.path.endsWith('/acknowledge'))
          .length;
      generation = 1;
      await expectLater(
        stored(storage, transport),
        throwsA(code('chat.anonymous_generation_invalid')),
      );
      expect(storage.values.values.single, before);
      expect(
        transport.calls
            .where((c) => c.uri.path.endsWith('/acknowledge'))
            .length,
        acks,
      );
    },
  );
  test('failed replacement write never acknowledges it and leaves the predecessor recoverable', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    var rotate = false;
    transport.handler = (call) async {
      if (call.uri.path.endsWith('/anonymous')) {
        if (rotate) {
          expect(call.body!['resumeSecret'], 'proof-1');
          storage.failWrite = true;
        }
        return ChatResponse(
          201,
          anonymous(
            generation: rotate ? 2 : 1,
            secret: rotate ? 'proof-2' : 'proof-1',
          ),
        );
      }
      return transport.respond(call);
    };
    await (await stored(storage, transport, create: true)).dispose();
    rotate = true;
    final acks = transport.calls
        .where((c) => c.uri.path.endsWith('/acknowledge'))
        .length;
    await expectLater(
      stored(storage, transport),
      throwsA(code('chat.storage_unavailable')),
    );
    expect(storage.only['secret'], 'proof-1');
    expect(
      transport.calls.where((c) => c.uri.path.endsWith('/acknowledge')).length,
      acks,
    );
  });
  test(
    'lost first response requires explicit recovery with a new installation',
    () async {
      final storage = SecureMemory(), transport = FakeTransport();
      var lose = true;
      transport.handler = (call) async {
        if (call.uri.path.endsWith('/anonymous')) {
          if (lose)
            throw const ProtodeskChatException(
              'chat.network_unavailable',
              retryable: true,
            );
          return ChatResponse(201, anonymous());
        }
        return transport.respond(call);
      };
      await expectLater(
        stored(storage, transport, create: true),
        throwsA(code('chat.network_unavailable')),
      );
      final abandoned = storage.only['installationId'];
      lose = false;
      await expectLater(
        stored(storage, transport),
        throwsA(code('chat.anonymous_recovery_required')),
      );
      expect(transport.calls.length, 1);
      await (await stored(storage, transport, recover: true)).dispose();
      expect(storage.only['installationId'], isNot(abandoned));
    },
  );
  test('reset waits for server success; next initialization uses a new installation', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    var failReset = true;
    transport.handler = (call) async {
      if (call.uri.path.endsWith('/anonymous'))
        return ChatResponse(201, anonymous());
      if (call.method == 'DELETE' &&
          call.uri.path.endsWith('/anonymous-identity') &&
          failReset) {
        return const ChatResponse(503, {
          'error': {'code': 'chat.dependency_unavailable'},
        });
      }
      return transport.respond(call);
    };
    final client = await stored(storage, transport, create: true);
    final id = storage.only['installationId'];
    await expectLater(
      client.resetAnonymousIdentity(),
      throwsA(code('chat.dependency_unavailable')),
    );
    expect(storage.only['installationId'], id);
    expect(client.state, ChatClientState.ready);
    failReset = false;
    await client.resetAnonymousIdentity();
    expect(storage.only['secret'], null);
    expect(client.state, ChatClientState.signedOut);
    await client.dispose();
    await (await stored(storage, transport)).dispose();
    expect(storage.only['installationId'], isNot(id));
  });
  test('logout clears tokens but preserves anonymous identity until explicit reset', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    transport.handler = (call) async => call.uri.path.endsWith('/anonymous')
        ? ChatResponse(201, anonymous())
        : transport.respond(call);
    final client = await stored(storage, transport, create: true);
    await client.logout();
    expect(storage.only['session'], null);
    expect(storage.only['secret'], 'proof-1');
    await client.dispose();
  });
  test('verified sessions restore only their host account and fence refresh before transmission', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    var minted = 0, refreshed = 0;
    transport.handler = (call) async {
      if (call.uri.path.endsWith('/refresh')) {
        refreshed++;
        expect(storage.only['session'], null);
        expect(storage.only['refreshPending'], true);
        return ChatResponse(200, session(token: 'rotated'));
      }
      return transport.respond(call);
    };
    Future<String> provider() async {
      minted++;
      return 'host-token';
    }

    await (await stored(
      storage,
      transport,
      account: 'alice',
      provider: provider,
    )).dispose();
    await (await stored(
      storage,
      transport,
      account: 'alice',
      provider: provider,
    )).dispose();
    expect(minted, 1);
    expect(refreshed, 1);
    await (await stored(
      storage,
      transport,
      account: 'bob',
      provider: provider,
    )).dispose();
    expect(minted, 2);
    expect(refreshed, 1);
    expect(storage.values.length, 2);
  });
  test('ambiguous refresh is never loaded from disk again', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    var attempts = 0, minted = 0;
    transport.handler = (call) async {
      if (call.uri.path.endsWith('/refresh')) {
        attempts++;
        throw const ProtodeskChatException(
          'chat.network_unavailable',
          retryable: true,
        );
      }
      return transport.respond(call);
    };
    Future<String> provider() async {
      minted++;
      return 'host-token';
    }

    await (await stored(
      storage,
      transport,
      account: 'alice',
      provider: provider,
    )).dispose();
    await expectLater(
      stored(storage, transport, account: 'alice', provider: provider),
      throwsA(code('chat.network_unavailable')),
    );
    expect(storage.only['session'], null);
    await (await stored(
      storage,
      transport,
      account: 'alice',
      provider: provider,
    )).dispose();
    expect(attempts, 1);
    expect(minted, 2);
  });
  test(
    'storage error does not fall back to plaintext or another identity',
    () async {
      final storage = SecureMemory()..failRead = true;
      final transport = FakeTransport();
      await expectLater(
        stored(storage, transport, create: true, recover: true),
        throwsA(code('chat.storage_unavailable')),
      );
      expect(transport.calls, isEmpty);
    },
  );
  test('another client cannot race the same secure partition', () async {
    final storage = SecureMemory(), transport = FakeTransport();
    transport.handler = (call) async => call.uri.path.endsWith('/anonymous')
        ? ChatResponse(201, anonymous())
        : transport.respond(call);
    final client = await stored(storage, transport, create: true);
    await expectLater(
      stored(storage, FakeTransport()),
      throwsA(code('chat.storage_in_use')),
    );
    await client.dispose();
    await (await stored(storage, transport)).dispose();
  });
}

class BlockingStorage extends SecureMemory {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write(String key, String value) async {
    if (value.contains('rotated')) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    await super.write(key, value);
  }
}

class DiscardingStorage extends SecureMemory {
  @override
  Future<void> write(String key, String value) async {}
}
