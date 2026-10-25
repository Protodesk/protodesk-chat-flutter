import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'client.dart';
import 'help.dart';
import 'models.dart';

/// In-memory Help Center state for one client: manifest, locale choice,
/// article and listing caches. Everything is dropped when the session ends or
/// the identity changes; late responses from a dropped generation are ignored.
/// An explicit locale choice is remembered per Chat App in the client's storage
/// adapter when one is configured (it is a preference, not a credential).
final class ChatHelpController {
  ChatHelpController(this.client, {this.pageSize = 20}) {
    _subscription = client.states.listen((state) {
      if (state != ChatClientState.ready) _clear();
    });
  }

  static const _maxArticles = 30, _maxListings = 20;

  final ProtodeskChatClient client;
  final int pageSize;
  final _updates = StreamController<void>.broadcast();
  late final StreamSubscription<ChatClientState> _subscription;
  final _articles = LinkedHashMap<String, Future<ChatHelpArticle>>();
  final _listings = LinkedHashMap<String, ChatHelpListing>();
  ChatHelpCenterManifest? _manifest;
  Future<void>? _loading;
  ProtodeskChatException? _error;
  String? _selectedLocale;
  bool _unavailable = false, _restoredLocale = false, _disposed = false;
  int _generation = 0;

  Stream<void> get changes => _updates.stream;
  ChatHelpCenterManifest? get manifest => _manifest;
  bool get isLoading => _loading != null;
  ProtodeskChatException? get error => _error;

  /// The server reported that Help is off or has no published content.
  bool get isUnavailable => _unavailable;

  /// The explicit choice, else the locale the server resolved.
  String? get locale => _selectedLocale ?? _manifest?.activeLocale;

  /// Loads the manifest once (single-flight). Errors are kept in [error].
  Future<void> load({bool refresh = false}) {
    if (_disposed) return Future.value();
    if (!refresh && (_manifest != null || _unavailable)) return Future.value();
    return _loading ??= _loadManifest(_generation).whenComplete(() {
      _loading = null;
      _notify();
    });
  }

  Future<void> _loadManifest(int generation) async {
    _error = null;
    _notify();
    try {
      if (!_restoredLocale) {
        _restoredLocale = true;
        _selectedLocale ??= await _readLocale();
      }
      if (generation != _generation) return;
      ChatHelpCenterManifest manifest;
      try {
        manifest = await client.getHelpCenter(locale: _selectedLocale);
      } on ProtodeskChatException catch (error) {
        // A malformed remembered locale: fall back to the server default once.
        if (_selectedLocale == null ||
            !const {
              'chat.help_request_invalid',
              'chat.help_center_locale_invalid',
            }.contains(error.code))
          rethrow;
        _selectedLocale = null;
        manifest = await client.getHelpCenter();
      }
      if (generation != _generation) return;
      // The server resolves unpublished locales; follow what it actually serves.
      if (_selectedLocale != manifest.activeLocale) _selectedLocale = null;
      _manifest = manifest;
      _unavailable = false;
    } on ProtodeskChatException catch (error) {
      if (generation != _generation) return;
      if (error.code == 'chat.help_center_unavailable') {
        _unavailable = true;
      } else {
        _error = error;
      }
    }
  }

  /// Switches content language, remembers it, clears locale caches and reloads.
  Future<void> selectLocale(String locale) async {
    if (_disposed || locale == this.locale) return;
    _selectedLocale = locale;
    _resetContent();
    await _writeLocale(locale);
    await load(refresh: true);
  }

  /// One article in the current locale, cached. A failed load is not cached.
  Future<ChatHelpArticle> article(String articleId) {
    final key = '${locale ?? ''}|$articleId';
    final cached = _articles.remove(key);
    if (cached != null) return _articles[key] = cached;
    final generation = _generation;
    final future = client.getHelpArticle(articleId, locale: locale);
    _articles[key] = future;
    while (_articles.length > _maxArticles) {
      _articles.remove(_articles.keys.first);
    }
    future.then<void>(
      (_) {},
      onError: (Object _) {
        if (generation == _generation && identical(_articles[key], future)) {
          _articles.remove(key);
        }
      },
    );
    return future;
  }

  /// All articles, one collection, or search results ([query] ≥2 characters).
  /// The same listing object is returned while it stays cached.
  ChatHelpListing listing({String? query, String? collectionId}) {
    final search = query?.trim();
    if (search != null && search.length < 2) {
      throw const ProtodeskChatException('chat.help_request_invalid');
    }
    final key = '${locale ?? ''}|${collectionId ?? ''}|${search ?? ''}';
    final existing = _listings.remove(key);
    if (existing != null) return _listings[key] = existing;
    final listing = ChatHelpListing._(this, search, collectionId, _generation);
    _listings[key] = listing;
    while (_listings.length > _maxListings) {
      _listings.remove(_listings.keys.first);
    }
    return listing;
  }

  void _resetContent() {
    ++_generation;
    _manifest = null;
    _error = null;
    _unavailable = false;
    _articles.clear();
    _listings.clear();
    _loading = null;
    _notify();
  }

  void _clear() {
    _selectedLocale = null;
    _restoredLocale = false;
    _resetContent();
  }

  void _notify() {
    if (!_disposed) _updates.add(null);
  }

  String? get _localeKey {
    final storage = client.options.storage;
    if (storage == null) return null;
    final scope = sha256.convert(
      utf8.encode(
        '${client.options.baseUrl.origin}\n${client.options.publicChatAppId}',
      ),
    );
    return 'protodesk.chat.v1.help.$scope.locale';
  }

  Future<String?> _readLocale() async {
    final key = _localeKey;
    if (key == null) return null;
    try {
      final value = (await client.options.storage!.read(key))?.trim();
      return value == null || value.isEmpty ? null : value;
    } catch (_) {
      return null; // A preference: locked or failing storage never blocks Help.
    }
  }

  Future<void> _writeLocale(String locale) async {
    final key = _localeKey;
    if (key == null) return;
    try {
      await client.options.storage!.write(key, locale);
    } catch (_) {
      // Keep the in-memory choice for this session.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    ++_generation;
    await _subscription.cancel();
    await _updates.close();
  }
}

/// A cursor-paginated article list owned by a [ChatHelpController].
final class ChatHelpListing {
  ChatHelpListing._(
    this._owner,
    this.query,
    this.collectionId,
    this._generation,
  );

  final ChatHelpController _owner;
  final int _generation;
  final String? query, collectionId;
  final _articles = <ChatHelpArticleSummary>[];
  final _ids = <String>{};
  String? _cursor;
  bool _hasMore = true, _loaded = false;
  Future<void>? _pending;
  ProtodeskChatException? _error;

  List<ChatHelpArticleSummary> get articles => List.unmodifiable(_articles);
  bool get hasMore => _hasMore;
  bool get isLoaded => _loaded;
  bool get isLoading => _pending != null;
  ProtodeskChatException? get error => _error;

  /// Loads the first or next page (single-flight); retries after an error.
  Future<void> loadMore() {
    if (!_hasMore || _generation != _owner._generation) return Future.value();
    return _pending ??= _load().whenComplete(() {
      _pending = null;
      _owner._notify();
    });
  }

  Future<void> _load() async {
    _error = null;
    _owner._notify();
    try {
      final page = await _owner.client.listHelpArticles(
        query: query,
        collectionId: collectionId,
        locale: _owner.locale,
        cursor: _cursor,
        limit: _owner.pageSize,
      );
      if (_generation != _owner._generation) return;
      for (final article in page.data) {
        if (_ids.add(article.id)) _articles.add(article);
      }
      _cursor = page.nextCursor;
      _hasMore = page.hasMore && page.nextCursor != null;
      _loaded = true;
    } on ProtodeskChatException catch (error) {
      if (_generation == _owner._generation) _error = error;
    }
  }
}
