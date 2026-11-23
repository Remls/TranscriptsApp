import 'package:material_ui/material_ui.dart';

final _heading = RegExp(r'^(#{1,3})\s+(.+)$');
final _bullet = RegExp(r'^[-*]\s+(.+)$');
final _inline = RegExp(
  r'\*\*(.+?)\*\*'
  r'|__(.+?)__'
  r'|(?<=^|[\s(])\*([^*\n]+?)\*(?=[\s.,;:!?)]|$)'
  r'|(?<=^|[\s(])_([^_\n]+?)_(?=[\s.,;:!?)]|$)'
  r'|`([^`\n]+?)`',
);

/// Bold, italic and code spans of one line of markdown.
List<InlineSpan> markdownSpans(String text) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    final bold = m[1] ?? m[2];
    final italic = m[3] ?? m[4];
    if (bold != null) {
      spans.add(
        TextSpan(
          text: bold,
          style: const TextStyle(fontWeight: .w700),
        ),
      );
    } else if (italic != null) {
      spans.add(
        TextSpan(
          text: italic,
          style: const TextStyle(fontStyle: .italic),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: m[5],
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      );
    }
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}

/// Renders the markdown subset the summaries use: headings, bullet lists,
/// paragraphs, and bold, italic and code spans.
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.markdown, {super.key});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyLarge?.copyWith(height: 1.5);
    final blocks = <Widget>[];
    final paragraph = <String>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      blocks.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text.rich(
            TextSpan(children: markdownSpans(paragraph.join(' '))),
            style: body,
          ),
        ),
      );
      paragraph.clear();
    }

    for (final raw in markdown.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) {
        flushParagraph();
        continue;
      }
      final heading = _heading.firstMatch(line);
      if (heading != null) {
        flushParagraph();
        final style = switch (heading[1]!.length) {
          1 => theme.textTheme.titleLarge,
          2 => theme.textTheme.titleMedium,
          _ => theme.textTheme.titleSmall,
        };
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Text.rich(
              TextSpan(children: markdownSpans(heading[2]!)),
              style: style?.copyWith(fontWeight: .w600),
            ),
          ),
        );
        continue;
      }
      final bullet = _bullet.firstMatch(line);
      if (bullet != null) {
        flushParagraph();
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: .start,
              children: [
                SizedBox(width: 20, child: Text('•', style: body)),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: markdownSpans(bullet[1]!)),
                    style: body,
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }
      paragraph.add(line);
    }
    flushParagraph();

    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: blocks,
      ),
    );
  }
}
