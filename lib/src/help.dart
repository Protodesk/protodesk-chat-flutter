import 'configuration.dart' show safeHttpsUrl;
import 'models.dart';

/// Published Help Center structure for one resolved locale.
final class ChatHelpCenterManifest {
  ChatHelpCenterManifest._({
    required this.name,
    required this.description,
    required this.defaultLocale,
    required this.activeLocale,
    required this.publicUrl,
    required this.availableLocales,
    required this.collections,
    required this.featuredArticles,
  });

  factory ChatHelpCenterManifest.fromJson(Map<String, dynamic> json) =>
      _parse(() {
        final collections = [
          for (final value in json['collections'] as List)
            ChatHelpCollection._parse(value as Map),
        ]..sort((a, b) => a.position.compareTo(b.position));
        return ChatHelpCenterManifest._(
          name: json['name'] as String,
          description: json['description'] as String,
          defaultLocale: json['defaultLocale'] as String,
          activeLocale: json['activeLocale'] as String,
          publicUrl: safeHttpsUrl(json['publicUrl']),
          availableLocales: List.unmodifiable(
            (json['availableLocales'] as List).cast<String>(),
          ),
          collections: List.unmodifiable(collections),
          featuredArticles: List.unmodifiable([
            for (final value in json['featuredArticles'] as List)
              ChatHelpArticleSummary._parse(value as Map),
          ]),
        );
      });

  final String name, description, defaultLocale, activeLocale;

  /// Standalone public Help Center, when one is published over HTTPS.
  final Uri? publicUrl;
  final List<String> availableLocales;
  final List<ChatHelpCollection> collections;
  final List<ChatHelpArticleSummary> featuredArticles;

  List<ChatHelpCollection> get rootCollections =>
      collections.where((c) => c.parentId == null).toList(growable: false);

  List<ChatHelpCollection> childCollections(String parentId) =>
      collections.where((c) => c.parentId == parentId).toList(growable: false);

  /// Public page for an article, or null without a public Help Center.
  Uri? articleUrl(String slug) {
    final base = publicUrl;
    if (base == null) return null;
    final path = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path:
          '$path/${Uri.encodeComponent(activeLocale)}/articles/'
          '${Uri.encodeComponent(slug)}',
      query: null,
      fragment: null,
    );
  }
}

final class ChatHelpCollection {
  ChatHelpCollection._({
    required this.id,
    required this.parentId,
    required this.slug,
    required this.name,
    required this.description,
    required this.position,
    required this.articleCount,
  });
  factory ChatHelpCollection._parse(Map json) => ChatHelpCollection._(
    id: json['id'] as String,
    parentId: json['parentId'] as String?,
    slug: json['slug'] as String,
    name: json['name'] as String,
    description: json['description'] as String? ?? '',
    position: json['position'] as int? ?? 0,
    articleCount: json['articleCount'] as int,
  );
  final String id, slug, name, description;
  final String? parentId;
  final int position, articleCount;
}

/// The collection an article belongs to.
final class ChatHelpCollectionRef {
  ChatHelpCollectionRef._(this.id, this.slug, this.name);
  static ChatHelpCollectionRef? _parse(Object? value) => value is Map
      ? ChatHelpCollectionRef._(
          value['id'] as String,
          value['slug'] as String,
          value['name'] as String,
        )
      : null;
  final String id, slug, name;
}

final class ChatHelpArticleSummary {
  ChatHelpArticleSummary._(Map json)
    : id = json['id'] as String,
      slug = json['slug'] as String,
      title = json['title'] as String,
      excerpt = json['excerpt'] as String? ?? '',
      collection = ChatHelpCollectionRef._parse(json['collection']),
      locale = json['locale'] as String,
      updatedAt = DateTime.parse(json['updatedAt'] as String);
  factory ChatHelpArticleSummary._parse(Map json) =>
      ChatHelpArticleSummary._(json);
  final String id, slug, title, excerpt, locale;
  final ChatHelpCollectionRef? collection;
  final DateTime updatedAt;
}

final class ChatHelpArticle extends ChatHelpArticleSummary {
  ChatHelpArticle._(super.json)
    : bodyMarkdown = json['bodyMarkdown'] as String,
      relatedArticles = List.unmodifiable([
        for (final value in json['relatedArticles'] as List? ?? const [])
          ChatHelpRelatedArticle._(value as Map),
      ]),
      super._();

  factory ChatHelpArticle.fromJson(Map<String, dynamic> json) =>
      _parse(() => ChatHelpArticle._(json));

  /// Compact Help Markdown. Render with `ChatHelpDocument.parse`.
  final String bodyMarkdown;
  final List<ChatHelpRelatedArticle> relatedArticles;
}

final class ChatHelpRelatedArticle {
  ChatHelpRelatedArticle._(Map json)
    : id = json['id'] as String,
      slug = json['slug'] as String,
      title = json['title'] as String,
      excerpt = json['excerpt'] as String? ?? '';
  final String id, slug, title, excerpt;
}

ChatPage<ChatHelpArticleSummary> parseHelpArticlePage(
  Map<String, dynamic> json,
) => _parse(
  () => ChatPage(
    List.unmodifiable([
      for (final value in json['data'] as List)
        ChatHelpArticleSummary._parse(value as Map),
    ]),
    hasMore: json['hasMore'] as bool,
    nextCursor: json['nextCursor'] as String?,
  ),
);

T _parse<T>(T Function() parse) {
  try {
    return parse();
  } catch (_) {
    throw const ProtodeskChatException('chat.invalid_response');
  }
}
