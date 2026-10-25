import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

import '../support/bootstrap.dart';
import '../support/fake_transport.dart';

Matcher throwsCode(String code) =>
    throwsA(isA<ProtodeskChatException>().having((e) => e.code, 'code', code));

class MemoryStorage implements ChatStorageAdapter {
  final values = <String, String>{};
  bool fail = false;
  @override
  bool get isPlatformSecure => true;
  @override
  Future<String?> read(String key) async {
    if (fail && key.contains('.help.')) throw StateError('locked');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (fail && key.contains('.help.')) throw StateError('locked');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

Map<String, dynamic> collection(
  String id, {
  String? parent,
  int position = 0,
}) => {
  'id': id,
  'parentId': parent,
  'slug': id,
  'name': 'Collection $id',
  'description': '',
  'position': position,
  'articleCount': 3,
};

Map<String, dynamic> summary(String id, {String locale = 'en'}) => {
  'id': id,
  'slug': 'slug-$id',
  'title': 'Article $id',
  'excerpt': 'About $id',
  'hasCustomExcerpt': false,
  'collection': {'id': 'c1', 'slug': 'c1', 'name': 'Getting started'},
  'locale': locale,
  'updatedAt': '2026-10-25T00:00:00Z',
  'position': 0,
};

Map<String, dynamic> manifest({
  String locale = 'en',
  List<String> locales = const ['en', 'id'],
}) => {
  'name': 'Help',
  'description': 'Find answers',
  'defaultLocale': 'en',
  'activeLocale': locale,
  'publicUrl': 'https://help.example.test/',
  'availableLocales': locales,
  'collections': [
    collection('c2', position: 2),
    collection('c1', position: 1),
    collection('c3', parent: 'c1'),
  ],
  'featuredArticles': [summary('a1', locale: locale)],
};

/// Serves bootstrap and Help routes; records Help calls.
class HelpServer {
  HelpServer(this.transport, {this.help = true}) {
    transport.handler = handle;
  }
  final FakeTransport transport;
  bool help;
  final pages = <String, List<Map<String, dynamic>>>{};
  Completer<void>? gate;
  int failArticles = 0;

  Iterable<Call> get calls =>
      transport.calls.where((c) => c.uri.path.contains('/help-center'));

  Future<ChatResponse> handle(Call call) async {
    final path = call.uri.path;
    final query = call.uri.queryParameters;
    // Persisted anonymous sessions need a resumable identity proof.
    if (path.endsWith('/anonymous')) {
      return ChatResponse(201, {
        ...session(),
        'anonymousIdentity': {
          'generation': 1,
          'acknowledgementRequired': false,
          'resumeSecret': 'proof-1',
        },
      });
    }
    if (path.endsWith('/bootstrap')) {
      return ChatResponse(200, bootstrap(help: help));
    }
    if (!path.contains('/help-center')) return transport.respond(call);
    await gate?.future;
    if (!help) {
      return const ChatResponse(404, {
        'error': {'code': 'chat.help_center_unavailable'},
      });
    }
    if (query['locale'] == 'zz-invalid-') {
      return const ChatResponse(400, {
        'error': {'code': 'chat.help_center_locale_invalid'},
      });
    }
    final locale = switch (query['locale']) {
      'id' => 'id',
      'fr' => 'en', // Unpublished: the server resolves another locale.
      _ => 'en',
    };
    if (path.endsWith('/help-center')) {
      return ChatResponse(200, manifest(locale: locale));
    }
    if (path.endsWith('/articles')) {
      final cursor = query['cursor'];
      final page = cursor == null ? 0 : int.parse(cursor);
      return ChatResponse(200, {
        'data': [
          summary('a${page * 2 + 1}', locale: locale),
          summary('a${page * 2 + 2}', locale: locale),
          if (page == 1)
            summary('a1', locale: locale), // Duplicate across pages.
        ],
        'hasMore': page == 0,
        'nextCursor': page == 0 ? '1' : null,
      });
    }
    if (failArticles > 0) {
      failArticles--;
      return const ChatResponse(503, {
        'error': {'code': 'chat.dependency_unavailable'},
      });
    }
    return ChatResponse(200, {
      ...summary(path.split('/').last, locale: locale),
      'bodyMarkdown': '# Title',
      'relatedArticles': [
        {'id': 'a2', 'slug': 'slug-a2', 'title': 'Article a2', 'excerpt': ''},
      ],
    });
  }
}

void main() {
  group('configuration', () {
    test('parses bootstrap and drops unsafe optional values', () {
      final config = ChatAppConfiguration.fromBootstrap(
        bootstrap(
          appearance: {'primaryColor': '#00A5D1'},
          preChatForm: {
            'enabled': true,
            'intro': 'Tell us about you',
            'fields': [
              {'id': 'name', 'type': 'text', 'label': 'Name', 'required': true},
              {
                'id': 'topic',
                'type': 'select',
                'label': 'Topic',
                'required': false,
                'options': ['Billing', 'Other'],
              },
              {'id': 'empty', 'type': 'select', 'label': 'No options'},
              {'id': 'future', 'type': 'date', 'label': 'Date'},
              {'id': 'bad id', 'type': 'text', 'label': 'Bad'},
            ],
          },
          widget: {
            'routingChoices': [
              {'id': 'sales', 'label': 'Sales'},
              {'id': '', 'label': 'Invalid'},
            ],
          },
        ),
      );
      expect(config.name, 'Protodesk');
      expect(config.headerTitle, 'Chat with us');
      expect(config.greeting, 'Hi! How can we help you?');
      expect(config.appearance.primaryColor, 0xff00a5d1);
      expect(config.appearance.colorScheme, ChatColorScheme.dark);
      expect(
        config.appearance.logoUrl,
        Uri.parse('https://cdn.example.test/logo.png'),
      );
      expect(config.links.map((l) => l.label), ['Status']);
      expect(config.preChatForm.fields.map((f) => f.id), ['name', 'topic']);
      expect(config.preChatForm.fields[1].options, ['Billing', 'Other']);
      expect(config.routingChoices.map((c) => c.id), ['sales']);
      expect(config.requiresConversationSetup, isTrue);
      expect(config.helpCenterAvailable, isTrue);
      expect(config.capabilities.anonymousIdentityReset, isFalse);
      expect(config.identity.kind, ChatIdentityKind.anonymous);
      expect(config.identity.locale, 'id');
    });

    test('a verified identity keeps its name and a safe avatar', () {
      ChatAppConfiguration parse(Object? avatar) =>
          ChatAppConfiguration.fromBootstrap(
            bootstrap(
              identity: {
                'kind': 'verified',
                'displayName': ' Maya ',
                'locale': 'en-US',
                'avatarUrl': avatar,
              },
              preChatForm: const {
                'enabled': true,
                'intro': 'Tell us about you.',
                'fields': [],
              },
            ),
          );
      final config = parse('https://cdn.example.test/maya.png');
      expect(config.identity.isVerified, isTrue);
      expect(config.identity.displayName, 'Maya');
      expect(
        config.identity.avatarUrl,
        Uri.parse('https://cdn.example.test/maya.png'),
      );
      expect(
        parse('http://cdn.example.test/maya.png').identity.avatarUrl,
        isNull,
      );
      // The server already removed the identity fields: nothing left to ask.
      expect(config.requiresConversationSetup, isFalse);
    });

    test('invalid colour and insecure logo fall back to null', () {
      final config = ChatAppConfiguration.fromBootstrap(
        bootstrap(
          appearance: {
            'primaryColor': 'red',
            'logoUrl': 'http://cdn.example.test/logo.png',
          },
          help: false,
        ),
      );
      expect(config.appearance.primaryColor, isNull);
      expect(config.appearance.logoUrl, isNull);
      expect(config.requiresConversationSetup, isFalse);
      expect(config.helpCenterAvailable, isFalse);
      expect(
        () => ChatAppConfiguration.fromBootstrap({'unreadCount': 0}),
        throwsCode('chat.invalid_response'),
      );
    });

    test('client caches per identity and unread reads refresh it', () async {
      final transport = FakeTransport();
      HelpServer(transport);
      final client = await makeClient(transport);
      bootstraps() =>
          transport.calls.where((c) => c.uri.path.endsWith('/bootstrap'));
      expect(client.cachedConfiguration, isNull);
      final first = await client.getConfiguration();
      expect(identical(await client.getConfiguration(), first), isTrue);
      expect(bootstraps(), hasLength(1));
      await client.getUnreadCount();
      expect(identical(client.cachedConfiguration, first), isFalse);
      expect(bootstraps(), hasLength(2));
      await client.logout();
      expect(client.cachedConfiguration, isNull);
      await expectLater(
        client.getConfiguration(),
        throwsCode('chat.session_required'),
      );
      await client.dispose();
    });
  });

  group('Help API', () {
    test('sends locale, search, collection, cursor and limit', () async {
      final transport = FakeTransport();
      final server = HelpServer(transport);
      final client = await makeClient(transport);
      final help = await client.getHelpCenter(locale: 'id');
      expect(help.activeLocale, 'id');
      expect(help.collections.map((c) => c.id), ['c3', 'c1', 'c2']);
      expect(help.rootCollections.map((c) => c.id), ['c1', 'c2']);
      expect(help.childCollections('c1').single.id, 'c3');
      expect(
        help.articleUrl('a b').toString(),
        'https://help.example.test/id/articles/a%20b',
      );
      await client.listHelpArticles(
        query: '  billing ',
        collectionId: 'c1',
        locale: 'id',
        cursor: '1',
        limit: 5,
      );
      expect(server.calls.last.uri.queryParameters, {
        'limit': '5',
        'query': 'billing',
        'collectionId': 'c1',
        'locale': 'id',
        'cursor': '1',
      });
      final article = await client.getHelpArticle('art/1');
      expect(
        server.calls.last.uri.path,
        '/v1/chat/help-center/articles/art%2F1',
      );
      expect(article.bodyMarkdown, '# Title');
      expect(article.relatedArticles.single.id, 'a2');
      await client.dispose();
    });

    test('rejects invalid input before any request', () async {
      final transport = FakeTransport();
      final server = HelpServer(transport);
      final client = await makeClient(transport);
      for (final call in <Future<Object?> Function()>[
        () => client.listHelpArticles(query: 'a'),
        () => client.listHelpArticles(query: 'x' * 121),
        () => client.listHelpArticles(limit: 51),
        () => client.listHelpArticles(collectionId: ''),
        () => client.getHelpArticle(''),
        () => client.getHelpCenter(locale: 'en us'),
      ]) {
        await expectLater(call(), throwsCode('chat.help_request_invalid'));
      }
      expect(server.calls, isEmpty);
      server.help = false;
      await expectLater(
        client.getHelpCenter(),
        throwsCode('chat.help_center_unavailable'),
      );
      await client.dispose();
    });
  });

  group('ChatHelpController', () {
    test('single-flight load and unavailable state', () async {
      final transport = FakeTransport();
      final server = HelpServer(transport, help: false);
      final client = await makeClient(transport);
      final help = ChatHelpController(client);
      await Future.wait([help.load(), help.load()]);
      expect(server.calls, hasLength(1));
      expect(help.isUnavailable, isTrue);
      expect(help.manifest, isNull);
      await help.load();
      expect(server.calls, hasLength(1));
      await help.dispose();
      await client.dispose();
    });

    test('remembers an explicit locale and clears locale caches', () async {
      final storage = MemoryStorage();
      final transport = FakeTransport();
      final server = HelpServer(transport);
      final options = ChatClientOptions(
        publicChatAppId: appId,
        baseUrl: Uri.parse('https://api.example.test'),
        transport: transport,
        storage: storage,
        allowNewAnonymousIdentity: true,
      );
      var client = await initializeChat(options);
      var help = ChatHelpController(client);
      await help.load();
      expect(help.locale, 'en');
      await help.article('a1');
      await help.article('a1');
      expect(
        server.calls.where((c) => c.uri.path.endsWith('/a1')),
        hasLength(1),
      );

      await help.selectLocale('id');
      expect(help.locale, 'id');
      expect(help.manifest!.activeLocale, 'id');
      await help.article('a1');
      expect(server.calls.last.uri.queryParameters['locale'], 'id');
      expect(storage.values.values, contains('id'));
      await help.dispose();
      await client.dispose();

      // A new client for the same app restores the choice.
      client = await initializeChat(options);
      help = ChatHelpController(client);
      await help.load();
      expect(server.calls.last.uri.queryParameters['locale'], 'id');
      expect(help.locale, 'id');
      await help.dispose();
      await client.dispose();
    });

    test('malformed or unpublished remembered locales fall back', () async {
      for (final remembered in ['zz-invalid-', 'fr']) {
        final storage = MemoryStorage();
        final transport = FakeTransport();
        HelpServer(transport);
        final client = await initializeChat(
          ChatClientOptions(
            publicChatAppId: appId,
            baseUrl: Uri.parse('https://api.example.test'),
            transport: transport,
            storage: storage,
            allowNewAnonymousIdentity: true,
          ),
        );
        final help = ChatHelpController(client);
        await help.selectLocale(remembered);
        expect(help.error, isNull, reason: remembered);
        expect(help.manifest!.activeLocale, 'en', reason: remembered);
        expect(help.locale, 'en', reason: remembered);
        await help.dispose();
        await client.dispose();
      }
    });

    test('locked storage never blocks Help', () async {
      final storage = MemoryStorage();
      final transport = FakeTransport();
      HelpServer(transport);
      final client = await initializeChat(
        ChatClientOptions(
          publicChatAppId: appId,
          baseUrl: Uri.parse('https://api.example.test'),
          transport: transport,
          storage: storage,
          allowNewAnonymousIdentity: true,
        ),
      );
      storage.fail = true;
      final help = ChatHelpController(client);
      await help.load();
      expect(help.manifest, isNotNull);
      await help.selectLocale('id');
      expect(help.locale, 'id');
      await help.dispose();
      await client.dispose();
    });

    test('listings paginate, deduplicate and are reused', () async {
      final transport = FakeTransport();
      final server = HelpServer(transport);
      final client = await makeClient(transport);
      final help = ChatHelpController(client, pageSize: 2);
      await help.load();
      final listing = help.listing(collectionId: 'c1');
      expect(identical(help.listing(collectionId: 'c1'), listing), isTrue);
      await Future.wait([listing.loadMore(), listing.loadMore()]);
      expect(listing.articles.map((a) => a.id), ['a1', 'a2']);
      expect(listing.hasMore, isTrue);
      await listing.loadMore();
      expect(listing.articles.map((a) => a.id), ['a1', 'a2', 'a3', 'a4']);
      expect(listing.hasMore, isFalse);
      await listing.loadMore();
      expect(
        server.calls.where((c) => c.uri.path.endsWith('/articles')),
        hasLength(2),
      );
      expect(
        () => help.listing(query: 'a'),
        throwsCode('chat.help_request_invalid'),
      );
      await help.dispose();
      await client.dispose();
    });

    test('failed article loads are retried, not cached', () async {
      final transport = FakeTransport();
      final server = HelpServer(transport)..failArticles = 1;
      final client = await makeClient(transport);
      final help = ChatHelpController(client);
      await help.load();
      await expectLater(
        help.article('a1'),
        throwsCode('chat.dependency_unavailable'),
      );
      expect((await help.article('a1')).id, 'a1');
      expect(server.failArticles, 0);
      await help.dispose();
      await client.dispose();
    });

    test('identity change drops content and late responses', () async {
      final transport = FakeTransport();
      final server = HelpServer(transport)..gate = Completer<void>();
      final client = await makeClient(transport);
      final help = ChatHelpController(client);
      final loading = help.load();
      await until(() => server.calls.isNotEmpty);
      await client.logout();
      server.gate!.complete();
      await loading;
      expect(help.manifest, isNull);
      expect(help.isLoading, isFalse);
      await help.dispose();
      await client.dispose();
    });
  });
}
