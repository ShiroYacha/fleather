import 'dart:convert';

import '../../parchment.dart';

class ParchmentMarkdownCodec extends Codec<ParchmentDocument, String> {
  const ParchmentMarkdownCodec({
    this.strictEncoding = true,
    this.referenceValidator,
  });

  /// Whether to strictly stick to the Markdown syntax during the encoding.
  ///
  /// If this option is enabled, during the encoding, if attributes that are
  /// not natively supported by the Markdown syntax exist, an exception will be
  /// thrown. Otherwise, they will be converted in the best way possible
  /// (for example with HTML tags, plain text or placeholders).
  ///
  /// Currently supported attributes:
  ///   - Underline with `<u>...</u>`
  final bool strictEncoding;

  final bool Function(String)? referenceValidator;

  @override
  Converter<String, ParchmentDocument> get decoder =>
      _ParchmentMarkdownDecoder(referenceValidator: referenceValidator);

  @override
  Converter<ParchmentDocument, String> get encoder =>
      _ParchmentMarkdownEncoder(strict: strictEncoding);
}

class _ParchmentMarkdownDecoder extends Converter<String, ParchmentDocument> {
  _ParchmentMarkdownDecoder({this.referenceValidator});

  final bool Function(String)? referenceValidator;

  static final _headingRegExp = RegExp(r'(#+) *(.+)');
  static final _hashtagRegExp = RegExp(r'#[^\s]+');
  static final _styleRegExp = RegExp(
    // italic then bold
    r'(([*_])(\*{2}|_{2})(?<italic_bold_text>.*?[^ \3\2])\3\2)|'
    // bold then italic
    r'((\*{2}|_{2})([*_])(?<bold_italic_text>.*?[^ \7\6])\7\6)|'
    // italic or bold
    r'(((\*{1,2})|(_{1,2}))(?<bold_or_italic_text>.*?[^ \10])\10)|'
    // strike through
    r'(~~(?<strike_through_text>.+?)~~)|'
    // inline code
    r'(`(?<inline_code_text>.+?)`)',
  );

  static final _linkRegExp = RegExp(r'\[(.+?)\]\(([^)]+)\)');
  static final _ulRegExp = RegExp(r'^( *)\* +(.*)');
  static final _olRegExp = RegExp(r'^( *)\d+[.)] +(.*)');
  static final _clRegExp = RegExp(r'^( *)- +\[( |x|X)\] +(.*)');
  static final _bqRegExp = RegExp(r'^> *(.*)');
  static final _codeRegExpTag = RegExp(r'^( *)```');
  static final _hrRegExp = RegExp(r'^( *)(?:[-*_]){3,}\s*$');
  static final _referenceRegExp = RegExp(r'@[^\s]+');

  bool _inBlockStack = false;

  @override
  ParchmentDocument convert(String input) {
    final lines = input.split('\n');
    final delta = Delta();

    for (final line in lines) {
      _handleLine(line, delta);
    }

    return ParchmentDocument.fromDelta(delta..trim());
  }

  void _handleLine(String line, Delta delta, [ParchmentStyle? style]) {
    if (line.isEmpty && delta.isEmpty) {
      delta.insert('\n');
      return;
    }

    if (_handleHorizontalRule(line, delta)) {
      return;
    }
    if (_handleBlockQuote(line, delta, style)) {
      return;
    }
    if (_handleBlock(line, delta, style)) {
      return;
    }
    if (_handleHeading(line, delta, style)) {
      return;
    }

    if (line.isNotEmpty) {
      if (style?.isInline ?? true) {
        _handleSpan(line, delta, true, style);
      } else {
        _handleSpan(line, delta, false,
            ParchmentStyle().putAll(style?.inlineAttributes ?? []));
        _handleSpan('\n', delta, false,
            ParchmentStyle().putAll(style?.lineAttributes ?? []));
      }
    }
  }

  // Markdown supports headings and blocks within blocks (except for within code)
  // but not blocks within headers, or ul within
  bool _handleBlock(String line, Delta delta, [ParchmentStyle? style]) {
    final match = _codeRegExpTag.matchAsPrefix(line);
    if (match != null) {
      _inBlockStack = !_inBlockStack;
      return true;
    }
    if (_inBlockStack) {
      delta.insert(line);
      delta.insert('\n', ParchmentAttribute.code.toJson());
      // Don't bother testing for code blocks within block stacks
      return true;
    }

    if (_handleOrderedList(line, delta, style) ||
        _handleUnorderedList(line, delta, style) ||
        _handleCheckList(line, delta, style)) {
      return true;
    }

    return false;
  }

  // all blocks are supported within bq
  bool _handleBlockQuote(String line, Delta delta, [ParchmentStyle? style]) {
    // we do not support nested blocks
    if (style?.contains(ParchmentAttribute.block) ?? false) {
      return false;
    }
    final match = _bqRegExp.matchAsPrefix(line);
    final span = match?.group(1);
    if (span != null) {
      final newStyle = (style ?? ParchmentStyle()).put(ParchmentAttribute.bq);

      // all blocks are supported within bq
      _handleLine(span, delta, newStyle);
      return true;
    }
    return false;
  }

  // ol is supported within ol and bq, but not supported within ul
  bool _handleOrderedList(String line, Delta delta, [ParchmentStyle? style]) {
    // we do not support nested blocks
    if (style?.contains(ParchmentAttribute.block) ?? false) {
      return false;
    }
    final match = _olRegExp.matchAsPrefix(line);
    final span = match?.group(2);
    final indentSpaces = match?.group(1)?.length ?? 0;
    final indent = (indentSpaces / 2).floor(); // Convert spaces to indent level
    if (span != null) {
      _handleSpan(span, delta, false, style);
      ParchmentStyle blockStyle = ParchmentStyle().put(ParchmentAttribute.ol);
      if (indent > 0) {
        blockStyle =
            blockStyle.put(ParchmentAttribute.indent.withLevel(indent));
      }
      _handleSpan('\n', delta, false, blockStyle);
      return true;
    }
    return false;
  }

  bool _handleUnorderedList(String line, Delta delta, [ParchmentStyle? style]) {
    // we do not support nested blocks
    if (style?.contains(ParchmentAttribute.block) ?? false) {
      return false;
    }

    final match = _ulRegExp.matchAsPrefix(line);
    final span = match?.group(2);
    final indentSpaces = match?.group(1)?.length ?? 0;
    final indent = (indentSpaces / 2).floor(); // Convert spaces to indent level

    ParchmentStyle newStyle =
        (style ?? ParchmentStyle()).put(ParchmentAttribute.ul);
    if (indent > 0) {
      newStyle = newStyle.put(ParchmentAttribute.indent.withLevel(indent));
    }

    if (span != null) {
      _handleSpan(span, delta, false,
          ParchmentStyle().putAll(newStyle.inlineAttributes));
      _handleSpan(
          '\n', delta, false, ParchmentStyle().putAll(newStyle.lineAttributes));
      return true;
    }
    return false;
  }

  bool _handleCheckList(String line, Delta delta, [ParchmentStyle? style]) {
    // we do not support nested blocks
    if (style?.contains(ParchmentAttribute.block) ?? false) {
      return false;
    }

    final match = _clRegExp.matchAsPrefix(line);
    final span = match?.group(3);
    final indentSpaces = match?.group(1)?.length ?? 0;
    final indent = (indentSpaces / 2).floor(); // Convert spaces to indent level
    final isChecked = match?.group(2) != ' ';

    ParchmentStyle newStyle =
        (style ?? ParchmentStyle()).put(ParchmentAttribute.cl);
    if (indent > 0) {
      newStyle = newStyle.put(ParchmentAttribute.indent.withLevel(indent));
    }
    if (isChecked) {
      newStyle = newStyle.put(ParchmentAttribute.checked);
    }

    if (span != null) {
      _handleSpan(span, delta, false,
          ParchmentStyle().putAll(newStyle.inlineAttributes));
      _handleSpan(
          '\n', delta, false, ParchmentStyle().putAll(newStyle.lineAttributes));
      return true;
    }
    return false;
  }

  bool _handleHeading(String line, Delta delta, [ParchmentStyle? style]) {
    final match = _headingRegExp.matchAsPrefix(line);
    final levelTag = match?.group(1);
    if (levelTag != null) {
      final level = levelTag.length;
      final newStyle = (style ?? ParchmentStyle())
          .put(ParchmentAttribute.heading.withValue(level));

      final span = match?.group(2);
      if (span == null) {
        return false;
      }
      _handleSpan(span, delta, false,
          ParchmentStyle().putAll(newStyle.inlineAttributes));
      _handleSpan(
          '\n', delta, false, ParchmentStyle().putAll(newStyle.lineAttributes));
      return true;
    }

    return false;
  }

  void _handleSpan(
      String span, Delta delta, bool addNewLine, ParchmentStyle? outerStyle) {
    var start = _handleStyles(span, delta, outerStyle);
    span = span.substring(start);

    // Create a list to store all matches with their positions
    final allMatches = <_Match>[];

    // Collect all link matches
    _linkRegExp.allMatches(span).forEach((match) {
      allMatches.add(_Match(
        match.start,
        match.end,
        match.group(0)!,
        type: _MatchType.link,
        groups: [match.group(1)!, match.group(2)!],
      ));
    });

    // Collect all hashtag matches
    _hashtagRegExp.allMatches(span).forEach((match) {
      allMatches.add(_Match(
        match.start,
        match.end,
        match.group(0)!,
        type: _MatchType.hashtag,
      ));
    });

    // Collect all reference matches
    _referenceRegExp.allMatches(span).forEach((match) {
      if (referenceValidator?.call(match.group(0)!) ?? true) {
        allMatches.add(_Match(
          match.start,
          match.end,
          match.group(0)!,
          type: _MatchType.reference,
        ));
      }
    });

    // Sort matches by start position
    allMatches.sort((a, b) => a.start.compareTo(b.start));

    // Process all matches in order
    var currentPos = 0;
    for (final match in allMatches) {
      // Insert any text before the match
      if (match.start > currentPos) {
        delta.insert(
            span.substring(currentPos, match.start), outerStyle?.toJson());
      }

      // Handle the match based on its type
      switch (match.type) {
        case _MatchType.link:
          final text = match.groups![0];
          final href = match.groups![1];
          final linkStyle = (outerStyle ?? ParchmentStyle())
              .put(ParchmentAttribute.link.fromString(href));
          _handleSpan(text, delta, false, linkStyle);
          break;
        case _MatchType.hashtag:
          final hashtagEmbed = SpanEmbed('hashtag', data: {'text': match.text});
          delta.insert(hashtagEmbed.toJson());
          break;
        case _MatchType.reference:
          final referenceEmbed =
              SpanEmbed('reference', data: {'text': match.text});
          delta.insert(referenceEmbed.toJson());
          break;
        case _MatchType.style:
          final text = match.groups![0];
          final styleTag = match.groups![1];
          var newStyle = _fromStyleTag(styleTag);
          if (outerStyle != null) {
            newStyle = newStyle.mergeAll(outerStyle);
          }
      }

      currentPos = match.end;
    }

    // Insert any remaining text
    if (currentPos < span.length) {
      if (addNewLine) {
        delta.insert('${span.substring(currentPos)}\n', outerStyle?.toJson());
      } else {
        delta.insert(span.substring(currentPos), outerStyle?.toJson());
      }
    } else if (addNewLine) {
      delta.insert('\n', outerStyle?.toJson());
    }
  }

  int _handleStyles(String span, Delta delta, ParchmentStyle? outerStyle) {
    // Don't process styles within inline code
    if (outerStyle?.contains(ParchmentAttribute.inlineCode) ?? false) {
      return 0;
    }

    // Create a list to store all matches with their positions
    final allMatches = <_Match>[];

    // Collect all style matches
    _styleRegExp.allMatches(span).forEach((match) {
      String text;
      String styleTag;
      if (match.namedGroup('italic_bold_text') != null) {
        text = match.namedGroup('italic_bold_text')!;
        styleTag = '${match.group(2)}${match.group(3)}';
      } else if (match.namedGroup('bold_italic_text') != null) {
        text = match.namedGroup('bold_italic_text')!;
        styleTag = '${match.group(6)}${match.group(7)}';
      } else if (match.namedGroup('bold_or_italic_text') != null) {
        text = match.namedGroup('bold_or_italic_text')!;
        styleTag = match.group(10)!;
      } else if (match.namedGroup('strike_through_text') != null) {
        text = match.namedGroup('strike_through_text')!;
        styleTag = '~~';
      } else {
        assert(match.namedGroup('inline_code_text') != null);
        text = match.namedGroup('inline_code_text')!;
        styleTag = '`';
      }

      allMatches.add(_Match(
        match.start,
        match.end,
        match.group(0)!,
        type: _MatchType.style,
        groups: [text, styleTag],
      ));
    });

    // Collect all link matches
    _linkRegExp.allMatches(span).forEach((match) {
      allMatches.add(_Match(
        match.start,
        match.end,
        match.group(0)!,
        type: _MatchType.link,
        groups: [match.group(1)!, match.group(2)!],
      ));
    });

    // Sort matches by start position
    allMatches.sort((a, b) => a.start.compareTo(b.start));

    // Process all matches in order
    var currentPos = 0;
    for (final match in allMatches) {
      // Insert any text before the match
      if (match.start > currentPos) {
        delta.insert(
            span.substring(currentPos, match.start), outerStyle?.toJson());
      }

      // Handle the match based on its type
      switch (match.type) {
        case _MatchType.style:
          final text = match.groups![0];
          final styleTag = match.groups![1];
          var newStyle = _fromStyleTag(styleTag);
          if (outerStyle != null) {
            newStyle = newStyle.mergeAll(outerStyle);
          }
          _handleSpan(text, delta, false, newStyle);
          break;
        case _MatchType.link:
          final text = match.groups![0];
          final href = match.groups![1];
          final linkStyle = (outerStyle ?? ParchmentStyle())
              .put(ParchmentAttribute.link.fromString(href));
          _handleSpan(text, delta, false, linkStyle);
          break;
        default:
          // This shouldn't happen as we only collect style and link matches
          break;
      }

      currentPos = match.end;
    }

    return currentPos;
  }

  ParchmentStyle _fromStyleTag(String styleTag) {
    assert(
        (styleTag == '`') |
            (styleTag == '~~') |
            (styleTag == '_') |
            (styleTag == '*') |
            (styleTag == '__') |
            (styleTag == '**') |
            (styleTag == '__*') |
            (styleTag == '**_') |
            (styleTag == '_**') |
            (styleTag == '*__') |
            (styleTag == '***') |
            (styleTag == '___'),
        'Invalid style tag \'$styleTag\'');
    assert(styleTag.isNotEmpty, 'Style tag must not be empty');
    if (styleTag == '`') {
      return ParchmentStyle().put(ParchmentAttribute.inlineCode);
    }
    if (styleTag == '~~') {
      return ParchmentStyle().put(ParchmentAttribute.strikethrough);
    }
    if (styleTag.length == 3) {
      return ParchmentStyle()
          .putAll([ParchmentAttribute.bold, ParchmentAttribute.italic]);
    }
    if (styleTag.length == 2) {
      return ParchmentStyle().put(ParchmentAttribute.bold);
    }
    return ParchmentStyle().put(ParchmentAttribute.italic);
  }

  int _handleLinks(String span, Delta delta, ParchmentStyle? outerStyle) {
    var start = 0;

    final matches = _linkRegExp.allMatches(span);
    for (final match in matches) {
      if (match.start > start) {
        delta.insert(span.substring(start, match.start)); //, outerStyle);
      }

      final text = match.group(1);
      final href = match.group(2);
      if (text == null || href == null) {
        return start;
      }
      final newStyle = (outerStyle ?? ParchmentStyle())
          .put(ParchmentAttribute.link.fromString(href));

      _handleSpan(text, delta, false, newStyle);
      start = match.end;
    }

    return start;
  }

  int _handleHashtags(String span, Delta delta) {
    var start = 0;

    final matches = _hashtagRegExp.allMatches(span);
    for (final match in matches) {
      if (match.start > start) {
        delta.insert(span.substring(start, match.start));
      }

      final hashtag = match.group(0)!;
      final hashtagEmbed = SpanEmbed('hashtag', data: {'text': hashtag});
      delta.insert(hashtagEmbed.toJson());

      start = match.end;
    }

    return start;
  }

  int _handleReferences(String span, Delta delta) {
    var start = 0;

    final matches = _referenceRegExp.allMatches(span);
    for (final match in matches) {
      if (referenceValidator != null && !referenceValidator!(match.group(0)!)) {
        continue;
      }

      if (match.start > start) {
        delta.insert(span.substring(start, match.start));
      }

      final reference = match.group(0)!;
      final referenceEmbed = SpanEmbed('reference', data: {'text': reference});
      delta.insert(referenceEmbed.toJson());

      start = match.end;
    }

    return start;
  }

  bool _handleHorizontalRule(String line, Delta delta) {
    final match = _hrRegExp.matchAsPrefix(line);
    if (match != null) {
      // If delta is not empty and doesn't end with newline, add one
      if (!delta.isEmpty && !delta.last.data.toString().endsWith('\n')) {
        delta.insert('\n');
      }

      // Insert the horizontal rule as a block embed with its own line
      delta
        ..insert(BlockEmbed.horizontalRule.toJson())
        ..insert('\n');

      return true;
    }
    return false;
  }
}

class _ParchmentMarkdownEncoder extends Converter<ParchmentDocument, String> {
  const _ParchmentMarkdownEncoder({required this.strict});

  final bool strict;

  static final simpleBlocks = <ParchmentAttribute, String>{
    ParchmentAttribute.bq: '> ',
    ParchmentAttribute.ul: '* ',
    ParchmentAttribute.ol: '. ',
  };

  String _trimRight(StringBuffer buffer) {
    var text = buffer.toString();
    if (!text.endsWith(' ')) return '';
    final result = text.trimRight();
    buffer.clear();
    buffer.write(result);
    return ' ' * (text.length - result.length);
  }

  void handleText(
      StringBuffer buffer, TextNode node, ParchmentStyle currentInlineStyle) {
    final style = node.style;
    final rightPadding = _trimRight(buffer);

    for (final attr in currentInlineStyle.inlineAttributes.toList().reversed) {
      if (!style.contains(attr)) {
        _writeAttribute(buffer, attr, close: true);
      }
    }

    buffer.write(rightPadding);

    final leftTrimmedText = node.value.trimLeft();

    buffer.write(' ' * (node.length - leftTrimmedText.length));

    for (final attr in style.inlineAttributes) {
      if (!currentInlineStyle.contains(attr)) {
        _writeAttribute(buffer, attr);
      }
    }

    buffer.write(leftTrimmedText);
  }

  @override
  String convert(ParchmentDocument input) {
    final buffer = StringBuffer();
    final lineBuffer = StringBuffer();
    var currentInlineStyle = ParchmentStyle();
    ParchmentAttribute? currentBlockAttribute;

    void handleLine(LineNode node) {
      if (node.hasBlockEmbed) {
        if ((node.children.single as EmbedNode).value ==
            BlockEmbed.horizontalRule) {
          _writeHorizontalLineTag(buffer);
        } else {
          buffer.write('[object]');
        }
        return;
      }

      for (final attr in node.style.lineAttributes) {
        if (attr.key == ParchmentAttribute.block.key) {
          if (currentBlockAttribute != attr) {
            _writeAttribute(lineBuffer, attr);
            currentBlockAttribute = attr;
          } else if (attr != ParchmentAttribute.code) {
            _writeAttribute(lineBuffer, attr);
          }
        } else {
          _writeAttribute(lineBuffer, attr);
        }
      }

      for (final child in node.children) {
        if (child is TextNode) {
          handleText(lineBuffer, child, currentInlineStyle);
          currentInlineStyle = child.style;
        } else if (child is EmbedNode && child.value is SpanEmbed) {
          // Handle both hashtags and references
          final embedData = child.value.data['text'] as String;
          lineBuffer.write(embedData);
        }
      }

      handleText(lineBuffer, TextNode(), currentInlineStyle);

      currentInlineStyle = ParchmentStyle();

      final blockAttribute = node.style.get(ParchmentAttribute.block);
      if (currentBlockAttribute != blockAttribute) {
        _writeAttribute(lineBuffer, currentBlockAttribute, close: true);
      }

      buffer.write(lineBuffer);
      lineBuffer.clear();
    }

    void handleBlock(BlockNode node) {
      // store for each indent level the current item order
      int currentLevel = 0;
      Map<int, int> currentItemOrders = {0: 1};
      for (final lineNode in node.children) {
        if ((lineNode is LineNode) &&
            lineNode.style.contains(ParchmentAttribute.indent)) {
          final indent = lineNode.style.value(ParchmentAttribute.indent)!;
          currentLevel++;
          currentItemOrders[currentLevel] = 1;
          // Insert 2 spaces per indent before black start
          lineBuffer.writeAll(List.generate(indent, (_) => '  '));
        }
        if (node.style.containsSame(ParchmentAttribute.ol)) {
          lineBuffer.write(currentItemOrders[currentLevel]);
        } else if (node.style.containsSame(ParchmentAttribute.cl)) {
          lineBuffer.write('- [');
          if ((lineNode as LineNode)
              .style
              .contains(ParchmentAttribute.checked)) {
            lineBuffer.write('X');
          } else {
            lineBuffer.write(' ');
          }
          lineBuffer.write('] ');
        }
        handleLine(lineNode as LineNode);
        if (!lineNode.isLast) {
          buffer.write('\n');
        }
        currentItemOrders[currentLevel] = currentItemOrders[currentLevel]! + 1;
      }

      handleLine(LineNode());
      currentBlockAttribute = null;
    }

    for (final child in input.root.children) {
      if (child is LineNode) {
        handleLine(child);
        buffer.write('\n\n');
      } else if (child is BlockNode) {
        handleBlock(child);
        buffer.write('\n\n');
      }
    }

    return buffer.toString();
  }

  void _writeAttribute(StringBuffer buffer, ParchmentAttribute? attribute,
      {bool close = false}) {
    if (attribute == ParchmentAttribute.bold) {
      _writeBoldTag(buffer);
    } else if (attribute == ParchmentAttribute.italic) {
      _writeItalicTag(buffer);
    } else if (attribute == ParchmentAttribute.inlineCode) {
      _writeInlineCodeTag(buffer);
    } else if (attribute == ParchmentAttribute.strikethrough) {
      _writeStrikeThoughTag(buffer);
    } else if (attribute?.key == ParchmentAttribute.link.key) {
      _writeLinkTag(buffer, attribute as ParchmentAttribute<String>,
          close: close);
    } else if (attribute?.key == ParchmentAttribute.heading.key) {
      _writeHeadingTag(buffer, attribute as ParchmentAttribute<int>);
    } else if (attribute?.key == ParchmentAttribute.block.key) {
      _writeBlockTag(buffer, attribute as ParchmentAttribute<String>,
          close: close);
    } else if (attribute?.key == ParchmentAttribute.checked.key) {
      // no-op already handled in handleBlock
    } else if (attribute?.key == ParchmentAttribute.indent.key) {
      // no-op already handled in handleBlock
    } else if (!strict && attribute?.key == ParchmentAttribute.underline.key) {
      _writeUnderlineTag(buffer, close: close);
    } else if (strict) {
      throw ArgumentError('Cannot handle $attribute');
    } else {
      _writeObjectTag(buffer);
    }
  }

  void _writeBoldTag(StringBuffer buffer) {
    buffer.write('**');
  }

  void _writeItalicTag(StringBuffer buffer) {
    buffer.write('_');
  }

  void _writeUnderlineTag(StringBuffer buffer, {bool close = false}) {
    if (close) {
      buffer.write('</u>');
    } else {
      buffer.write('<u>');
    }
  }

  void _writeInlineCodeTag(StringBuffer buffer) {
    buffer.write('`');
  }

  void _writeStrikeThoughTag(StringBuffer buffer) {
    buffer.write('~~');
  }

  void _writeLinkTag(
    StringBuffer buffer,
    ParchmentAttribute<String> link, {
    bool close = false,
  }) {
    if (close) {
      buffer.write('](${link.value})');
    } else {
      buffer.write('[');
    }
  }

  void _writeHeadingTag(StringBuffer buffer, ParchmentAttribute<int> heading) {
    var level = heading.value!;
    buffer.write('${'#' * level} ');
  }

  void _writeBlockTag(StringBuffer buffer, ParchmentAttribute<String> block,
      {bool close = false}) {
    if (block == ParchmentAttribute.code) {
      if (close) {
        buffer.write('\n```');
      } else {
        buffer.write('```\n');
      }
    } else {
      if (close) return; // no close tag needed for simple blocks.

      final tag = simpleBlocks[block];
      if (tag != null) {
        buffer.write(tag);
      }
    }
  }

  void _writeHorizontalLineTag(StringBuffer buffer) {
    // Add newline before if buffer doesn't end with one
    if (buffer.isNotEmpty && !buffer.toString().endsWith('\n')) {
      buffer.write('\n');
    }
    buffer.write('---');
    // Add newline after
    buffer.write('\n');
  }

  void _writeObjectTag(StringBuffer buffer) {
    buffer.write('[object]');
  }
}

enum _MatchType { link, hashtag, reference, style }

class _Match {
  final int start;
  final int end;
  final String text;
  final _MatchType type;
  final List<String>? groups;

  _Match(
    this.start,
    this.end,
    this.text, {
    required this.type,
    this.groups,
  });
}
