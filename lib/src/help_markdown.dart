import 'configuration.dart' show safeHttpsUrl;

/// Compact Help Markdown, matching the web widget's `safe-markdown.ts`:
/// headings, paragraphs, emphasis, HTTPS links and raster images, quotes,
/// lists with task state, tables and escaped fenced code. Raw HTML lines are
/// dropped and unsafe links degrade to plain text. Nothing is interpreted as
/// markup beyond these blocks.
final class ChatHelpDocument {
  ChatHelpDocument._(this.blocks, this.outline);

  factory ChatHelpDocument.parse(String markdown) {
    final blocks = _parseBlocks(markdown);
    final used = <String, int>{};
    final outline = <ChatHelpHeading>[];
    final withIds = [
      for (final block in blocks)
        if (block is ChatHelpHeading && block.level <= 3)
          () {
            final label = block.text;
            if (label.isEmpty) return block;
            final base = label
                .toLowerCase()
                .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '-')
                .replaceAll(RegExp(r'^-|-$'), '');
            final key = base.isEmpty ? 'section' : base;
            final count = used[key] ?? 0;
            used[key] = count + 1;
            final heading = ChatHelpHeading._(
              block.level,
              block.content,
              id: count == 0 ? key : '$key-${count + 1}',
            );
            outline.add(heading);
            return heading;
          }()
        else
          block,
    ];
    return ChatHelpDocument._(
      List.unmodifiable(withIds),
      List.unmodifiable(outline),
    );
  }

  final List<ChatHelpBlock> blocks;

  /// Readable text of inline content (link labels, image alt text).
  static String plainText(List<ChatHelpInline> content) => _plainText(content);

  /// Level 1–3 headings with stable, de-duplicated IDs for "On this page".
  final List<ChatHelpHeading> outline;
}

sealed class ChatHelpBlock {
  const ChatHelpBlock();
}

final class ChatHelpHeading extends ChatHelpBlock {
  const ChatHelpHeading._(this.level, this.content, {this.id});
  final int level;
  final List<ChatHelpInline> content;

  /// Set for level 1–3 headings with text.
  final String? id;
  String get text => ChatHelpDocument.plainText(content);
}

final class ChatHelpParagraph extends ChatHelpBlock {
  const ChatHelpParagraph._(this.content);
  final List<ChatHelpInline> content;
}

final class ChatHelpQuote extends ChatHelpBlock {
  const ChatHelpQuote._(this.content);
  final List<ChatHelpInline> content;
}

final class ChatHelpList extends ChatHelpBlock {
  const ChatHelpList._(this.ordered, this.items);
  final bool ordered;
  final List<ChatHelpListItem> items;
}

final class ChatHelpListItem {
  const ChatHelpListItem._(this.content, this.checked);
  final List<ChatHelpInline> content;

  /// Task state, or null for an ordinary item.
  final bool? checked;
}

final class ChatHelpTable extends ChatHelpBlock {
  const ChatHelpTable._(this.headers, this.rows);
  final List<List<ChatHelpInline>> headers;
  final List<List<List<ChatHelpInline>>> rows;
}

/// Escaped code. `mermaid` stays source: diagrams belong to the full Help site.
final class ChatHelpCode extends ChatHelpBlock {
  const ChatHelpCode._(this.value, this.language);
  final String value;
  final String? language;
}

sealed class ChatHelpInline {
  const ChatHelpInline();
}

final class ChatHelpText extends ChatHelpInline {
  const ChatHelpText(this.value);
  final String value;
}

final class ChatHelpInlineCode extends ChatHelpInline {
  const ChatHelpInlineCode(this.value);
  final String value;
}

final class ChatHelpStrong extends ChatHelpInline {
  const ChatHelpStrong(this.value);
  final String value;
}

final class ChatHelpEmphasis extends ChatHelpInline {
  const ChatHelpEmphasis(this.value);
  final String value;
}

final class ChatHelpLink extends ChatHelpInline {
  const ChatHelpLink(this.label, this.url);
  final String label;
  final Uri url;
}

enum ChatHelpImageSize { original, small, medium, full }

final class ChatHelpImage extends ChatHelpInline {
  const ChatHelpImage(this.alt, this.url, this.size);
  final String alt;
  final Uri url;
  final ChatHelpImageSize size;
}

String _plainText(List<ChatHelpInline> content) => content
    .map(
      (item) => switch (item) {
        ChatHelpText(:final value) ||
        ChatHelpInlineCode(:final value) ||
        ChatHelpStrong(:final value) ||
        ChatHelpEmphasis(:final value) => value,
        ChatHelpLink(:final label) => label,
        ChatHelpImage(:final alt) => alt,
      },
    )
    .join()
    .trim();

final _inline = RegExp(
  r'(?<code>`[^`\n]+`)|(?<strong>\*\*[^*\n]+\*\*|__[^_\n]+__)|'
  r'(?<emphasis>\*[^*\n]+\*|_[^_\n]+_)|(?<link>!?\[[^\]]*\]\([^)\s]+\))',
);
final _linkParts = RegExp(r'^(!?)\[([^\]]*)\]\(([^)\s]+)\)$');
final _imageSize = RegExp(
  r'(?:#|&)pd-image-size=(original|small|medium|full)$',
);

List<ChatHelpInline> parseHelpInline(String value) {
  final result = <ChatHelpInline>[];
  var offset = 0;
  for (final match in _inline.allMatches(value)) {
    if (match.start > offset) {
      result.add(ChatHelpText(value.substring(offset, match.start)));
    }
    final code = match.namedGroup('code');
    final strong = match.namedGroup('strong');
    final emphasis = match.namedGroup('emphasis');
    if (code != null) {
      result.add(ChatHelpInlineCode(code.substring(1, code.length - 1)));
    } else if (strong != null) {
      result.add(ChatHelpStrong(strong.substring(2, strong.length - 2)));
    } else if (emphasis != null) {
      result.add(ChatHelpEmphasis(emphasis.substring(1, emphasis.length - 1)));
    } else {
      final parts = _linkParts.firstMatch(match.namedGroup('link')!)!;
      final isImage = parts[1] == '!';
      final label = parts[2]!;
      final raw = parts[3]!;
      final inline = isImage ? _image(label, raw) : _link(label, raw);
      if (inline != null) {
        result.add(inline);
      } else if (label.isNotEmpty) {
        result.add(ChatHelpText(label));
      }
    }
    offset = match.end;
  }
  if (offset < value.length) result.add(ChatHelpText(value.substring(offset)));
  return result.isEmpty ? [ChatHelpText(value)] : result;
}

ChatHelpInline? _link(String label, String raw) {
  final url = safeHttpsUrl(raw);
  return url == null
      ? null
      : ChatHelpLink(label.isEmpty ? url.toString() : label, url);
}

ChatHelpInline? _image(String alt, String raw) {
  final marker = _imageSize.firstMatch(raw);
  final url = safeHttpsUrl(
    marker == null ? raw : raw.substring(0, marker.start),
  );
  if (url == null || url.path.toLowerCase().endsWith('.svg')) return null;
  final size = ChatHelpImageSize.values.firstWhere(
    (size) => size.name == marker?[1],
    orElse: () => ChatHelpImageSize.full,
  );
  return ChatHelpImage(alt, url, size);
}

final _fence = RegExp(r'^\s*```([^\s`]*)');
final _rawHtml = RegExp(r'^\s*</?[A-Za-z][^>]*>');
final _heading = RegExp(r'^(#{1,6})\s+(.+)$');
final _quote = RegExp(r'^>\s?(.*)$');
final _unordered = RegExp(r'^\s*[-*+]\s+(.+)$');
final _ordered = RegExp(r'^\s*\d+[.)]\s+(.+)$');
final _task = RegExp(r'^\[([ xX])\]\s+(.+)$');
final _divider = RegExp(r'^:?-{3,}:?$');

List<ChatHelpBlock> _parseBlocks(String markdown) {
  final lines = markdown.replaceAll(RegExp(r'\r\n?'), '\n').split('\n');
  final blocks = <ChatHelpBlock>[];
  var paragraph = <String>[];
  List<String>? code;
  var codeLanguage = '';

  void flushParagraph() {
    final value = paragraph.join(' ').trim();
    paragraph = [];
    if (value.isNotEmpty)
      blocks.add(ChatHelpParagraph._(parseHelpInline(value)));
  }

  void flushCode() {
    blocks.add(
      ChatHelpCode._(
        code!.join('\n'),
        codeLanguage.isEmpty ? null : codeLanguage,
      ),
    );
    code = null;
    codeLanguage = '';
  }

  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final fence = _fence.firstMatch(line);
    if (fence != null) {
      flushParagraph();
      if (code != null) {
        flushCode();
      } else {
        code = [];
        codeLanguage = fence[1]!.toLowerCase();
      }
      continue;
    }
    if (code != null) {
      code!.add(line);
      continue;
    }
    if (line.trim().isEmpty || _rawHtml.hasMatch(line)) {
      flushParagraph();
      continue;
    }

    final header = _tableCells(line);
    final divider = index + 1 < lines.length
        ? _tableCells(lines[index + 1])
        : const <String>[];
    if (header.isNotEmpty &&
        header.length == divider.length &&
        divider.every((cell) => _divider.hasMatch(cell.trim()))) {
      flushParagraph();
      final rows = <List<List<ChatHelpInline>>>[];
      index += 2;
      for (; index < lines.length; index++) {
        final cells = _tableCells(lines[index]);
        if (cells.isEmpty) break;
        rows.add([
          for (var cell = 0; cell < header.length; cell++)
            parseHelpInline(cell < cells.length ? cells[cell] : ''),
        ]);
      }
      index--;
      blocks.add(
        ChatHelpTable._(
          List.unmodifiable(header.map(parseHelpInline)),
          List.unmodifiable(rows),
        ),
      );
      continue;
    }

    final heading = _heading.firstMatch(line);
    if (heading != null) {
      flushParagraph();
      blocks.add(
        ChatHelpHeading._(heading[1]!.length, parseHelpInline(heading[2]!)),
      );
      continue;
    }

    final quote = _quote.firstMatch(line);
    if (quote != null) {
      flushParagraph();
      blocks.add(ChatHelpQuote._(parseHelpInline(quote[1]!)));
      continue;
    }

    final ordered = _unordered.firstMatch(line) == null;
    if (!ordered || _ordered.hasMatch(line)) {
      flushParagraph();
      final pattern = ordered ? _ordered : _unordered;
      final items = <ChatHelpListItem>[];
      for (; index < lines.length; index++) {
        final item = pattern.firstMatch(lines[index]);
        if (item == null) break;
        final raw = item[1]!;
        final task = _task.firstMatch(raw);
        items.add(
          ChatHelpListItem._(
            parseHelpInline(task?[2] ?? raw),
            task == null ? null : task[1]!.toLowerCase() == 'x',
          ),
        );
      }
      index--;
      blocks.add(ChatHelpList._(ordered, List.unmodifiable(items)));
      continue;
    }

    paragraph.add(line.trim());
  }
  if (code != null) flushCode();
  flushParagraph();
  return blocks;
}

List<String> _tableCells(String line) {
  final trimmed = line.trim();
  if (!trimmed.contains('|')) return const [];
  return trimmed
      .replaceFirst(RegExp(r'^\|'), '')
      .replaceFirst(RegExp(r'\|$'), '')
      .split('|')
      .map((cell) => cell.trim())
      .toList();
}
