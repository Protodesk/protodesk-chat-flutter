import 'package:protodesk_chat/protodesk_chat.dart';

import 'fake_transport.dart';

/// A small published Help Center for widget tests and goldens.
const helpArticleMarkdown = '''Protodesk brings customer conversations, a public Help Center, and Evelin AI into one support workspace.

## What you can do

- Read and reply to customers in **Threads**.
- Connect email and Live Chat so your team can handle support in one place.
- [x] Publish answers in your Help Center.

## Next steps

1. Invite a teammate.
2. Read [the setup guide](https://help.example.test/en/articles/setup).

> Tip: start with your three most common questions.

| Plan | Seats |
| --- | --- |
| Starter | 3 |

```bash
npx protodesk init
```''';

Map<String, dynamic> helpCollection(
  String id,
  String name, {
  String? parent,
  int position = 0,
  int count = 3,
  String description = '',
}) => {
  'id': id,
  'parentId': parent,
  'slug': id,
  'name': name,
  'description': description,
  'position': position,
  'articleCount': count,
};

Map<String, dynamic> helpSummary(
  String id,
  String title, {
  String excerpt = '',
  String collection = 'getting-started',
}) => {
  'id': id,
  'slug': 'slug-$id',
  'title': title,
  'excerpt': excerpt,
  'hasCustomExcerpt': excerpt.isNotEmpty,
  'collection': {
    'id': collection,
    'slug': collection,
    'name': 'Getting started',
  },
  'locale': 'en',
  'updatedAt': '2026-10-25T00:00:00Z',
  'position': 0,
};

Map<String, dynamic> helpManifest({bool featured = true}) => {
  'name': 'Protodesk',
  'description': 'Find clear answers from our support team.',
  'defaultLocale': 'en',
  'activeLocale': 'en',
  'publicUrl': 'https://help.example.test/',
  'availableLocales': ['en', 'id'],
  'collections': [
    helpCollection(
      'getting-started',
      'Getting started',
      description: 'Set up Protodesk and confidently handle your first customer conversation.',
    ),
    helpCollection(
      'conversations',
      'Conversations',
      position: 1,
      count: 12,
      description: 'Reply to customers and keep your shared inbox organized.',
    ),
    helpCollection('channels', 'Channels', position: 2, count: 9),
  ],
  'featuredArticles': featured
      ? [
          helpSummary('a1', 'Add knowledge sources for Evelin'),
          helpSummary('a2', 'Use Evelin to prepare customer replies'),
          helpSummary('a3', 'Install Live Chat on your website'),
        ]
      : [],
};

/// Answers `/help-center*` routes, or returns null for any other path.
ChatResponse? helpResponse(Call call, {bool featured = true}) {
  final path = call.uri.path;
  if (!path.contains('/help-center')) return null;
  if (path.endsWith('/help-center')) {
    return ChatResponse(200, helpManifest(featured: featured));
  }
  if (path.endsWith('/articles')) {
    final query = call.uri.queryParameters['query'];
    return ChatResponse(200, {
      'data': query == 'nothing'
          ? []
          : [
              helpSummary(
                'a4',
                'Navigate your Protodesk workspace',
                excerpt: 'Find Threads, Evelin AI and Help Center articles.',
              ),
              helpSummary(
                'a5',
                'What is Protodesk?',
                excerpt: 'Bring customer conversations together.',
              ),
            ],
      'hasMore': false,
      'nextCursor': null,
    });
  }
  final id = path.split('/').last;
  return ChatResponse(200, {
    ...helpSummary(
      id,
      'What is Protodesk?',
      excerpt: 'Bring customer conversations, public help articles, and Evelin AI together in one support workspace.',
    ),
    'bodyMarkdown': helpArticleMarkdown,
    'relatedArticles': [
      {
        'id': 'a4',
        'slug': 'slug-a4',
        'title': 'Navigate your Protodesk workspace',
        'excerpt': '',
      },
    ],
  });
}
