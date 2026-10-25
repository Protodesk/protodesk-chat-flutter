import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';
import 'package:protodesk_chat/src/help_markdown.dart' show parseHelpInline;

/// Compact, comparable description of inline content.
List<String> inline(List<ChatHelpInline> content) => [
  for (final item in content)
    switch (item) {
      ChatHelpText(:final value) => 'text:$value',
      ChatHelpInlineCode(:final value) => 'code:$value',
      ChatHelpStrong(:final value) => 'strong:$value',
      ChatHelpEmphasis(:final value) => 'em:$value',
      ChatHelpLink(:final label, :final url) => 'link:$label>$url',
      ChatHelpImage(:final alt, :final url, :final size) =>
        'image:$alt>$url@${size.name}',
    },
];

void main() {
  // Cases mirror protodesk-web/src/widget/safe-markdown.test.ts.
  test('keeps the supported article structure', () {
    final blocks = ChatHelpDocument.parse(
      '# Setup\n\nUse `npm install` with **care**.\n\n- First\n- Second\n\n> Keep this safe.',
    ).blocks;
    expect(blocks, hasLength(4));
    final heading = blocks[0] as ChatHelpHeading;
    expect(heading.level, 1);
    expect(inline(heading.content), ['text:Setup']);
    expect(inline((blocks[1] as ChatHelpParagraph).content), [
      'text:Use ',
      'code:npm install',
      'text: with ',
      'strong:care',
      'text:.',
    ]);
    final list = blocks[2] as ChatHelpList;
    expect(list.ordered, isFalse);
    expect(list.items.map((i) => inline(i.content)), [
      ['text:First'],
      ['text:Second'],
    ]);
    expect(list.items.every((i) => i.checked == null), isTrue);
    expect(inline((blocks[3] as ChatHelpQuote).content), [
      'text:Keep this safe.',
    ]);
  });

  test('allows HTTPS links and raster images, rejects unsafe media', () {
    expect(
      inline(
        parseHelpInline(
          'Read [the guide](https://example.com/help), [bad](javascript:alert(1)), '
          '![logo](https://example.com/logo.png), and ![vector](https://example.com/logo.svg).',
        ),
      ),
      [
        'text:Read ',
        'link:the guide>https://example.com/help',
        'text:, ',
        'text:bad',
        'text:), ',
        'image:logo>https://example.com/logo.png@full',
        'text:, and ',
        'text:vector',
        'text:.',
      ],
    );
    expect(
      inline(
        parseHelpInline(
          '[http](http://example.com) [creds](https://u:p@example.com) [](https://example.com/x)',
        ),
      ),
      [
        'text:http',
        'text: ',
        'text:creds',
        'text: ',
        'link:https://example.com/x>https://example.com/x',
      ],
    );
  });

  test('keeps image size presets while stripping the storage marker', () {
    expect(
      inline(
        parseHelpInline(
          '![diagram](https://example.com/diagram.png#pd-image-size=medium)'
          '![raw](https://example.com/raw.png#pd-image-size=original)',
        ),
      ),
      [
        'image:diagram>https://example.com/diagram.png@medium',
        'image:raw>https://example.com/raw.png@original',
      ],
    );
  });

  test('drops standalone raw HTML', () {
    final blocks = ChatHelpDocument.parse(
      "Before\n\n<script>alert('x')</script>\n\nAfter",
    ).blocks;
    expect(blocks.map((b) => inline((b as ChatHelpParagraph).content)), [
      ['text:Before'],
      ['text:After'],
    ]);
  });

  test('keeps compact task, table and fenced-code fallbacks', () {
    final blocks = ChatHelpDocument.parse('''- [x] Published
- [ ] Reviewed

| Feature | State |
| --- | :---: |
| Tables | Ready |
| Short |

```mermaid
flowchart LR
  A --> B
```''').blocks;
    final tasks = blocks[0] as ChatHelpList;
    expect(tasks.items.map((i) => i.checked), [true, false]);
    expect(inline(tasks.items.first.content), ['text:Published']);
    final table = blocks[1] as ChatHelpTable;
    expect(table.headers.map(inline), [
      ['text:Feature'],
      ['text:State'],
    ]);
    expect(table.rows.map((row) => row.map(inline).toList()), [
      [
        ['text:Tables'],
        ['text:Ready'],
      ],
      [
        ['text:Short'],
        ['text:'],
      ],
    ]);
    final code = blocks[2] as ChatHelpCode;
    expect(code.language, 'mermaid');
    expect(code.value, 'flowchart LR\n  A --> B');
  });

  test('ordered lists, joined paragraphs and unterminated code', () {
    final blocks = ChatHelpDocument.parse(
      '1. One\n2) Two\n\nLine one\nline two\r\n\n```\n<b>not html</b>',
    ).blocks;
    final list = blocks[0] as ChatHelpList;
    expect(list.ordered, isTrue);
    expect(list.items, hasLength(2));
    expect(inline((blocks[1] as ChatHelpParagraph).content), [
      'text:Line one line two',
    ]);
    final code = blocks[2] as ChatHelpCode;
    expect(code.language, isNull);
    expect(code.value, '<b>not html</b>');
  });

  test('outline gives level 1–3 headings stable unique IDs', () {
    final document = ChatHelpDocument.parse(
      '## Get started\n### Get started\n## Akun & Tagihan\n#### Deep\n## ***\n## Get started',
    );
    expect(document.outline.map((h) => (h.id, h.level, h.text)), [
      ('get-started', 2, 'Get started'),
      ('get-started-2', 3, 'Get started'),
      ('akun-tagihan', 2, 'Akun & Tagihan'),
      ('section', 2, '***'),
      ('get-started-3', 2, 'Get started'),
    ]);
    final deep = document.blocks.whereType<ChatHelpHeading>().firstWhere(
      (h) => h.level == 4,
    );
    expect(deep.id, isNull);
  });
}
