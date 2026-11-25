import 'languages.dart';

const _timestampRules = '''Timestamp format (STRICT — common failure mode):
- Every timestamp MUST have all four components: HH:MM:SS,mmm
  HH = hours (2 digits, zero-padded), MM = minutes (2 digits), SS = seconds (2 digits), mmm = milliseconds (3 digits).
  The separator before milliseconds is a COMMA (,), not a colon.
- Correct: "00:01:42,560 --> 00:01:48,210"
- WRONG (do NOT emit any of these):
    "01:42,560"        ← missing hours
    "00:01:42:560"     ← colon before milliseconds; must be comma
    "01:42:560"        ← missing hours AND colon-instead-of-comma
    "1:42,560"         ← hours not zero-padded
- For audio under 1 hour, the hours field is "00", not omitted.

Cue ordering (STRICT — do not violate):
- Each cue's end MUST be >= its own start. Never emit a cue where end < start.
- Cues MUST NOT overlap. Each cue's start MUST be >= the previous cue's end.
- Do NOT emit a long "umbrella" cue that spans multiple utterances and then
  separate cues for those utterances inside it. Either segment finely OR
  segment coarsely — never both at once. One cue per utterance, in order.''';

const _furigana = '''Readings (furigana):
- After every word that contains kanji, give its reading in hiragana as it was spoken, in Aozora Bunko ruby notation: ｜word《reading》.
- Mark whole words, including any kana inside them: ｜食べ《たべ》る, ｜東京《とうきょう》, ｜今日《きょう》.
- Use the reading actually spoken, for names too.
- Do not add readings to words without kanji.''';

const _outputFormat = '''Output format:
- Return an SRT subtitle file ONLY, with no commentary, code fences, or notes.
- Each cue should be a natural utterance (typically 3-10 seconds).
- If multiple speakers are present, prefix each cue's text with a label like "Speaker 1:".''';

/// The longest note about a recording the user can write.
const contextLimit = 2000;

/// [prompt] after a section on the recording: its file name [title] and the
/// user's [note] about it.
String withBackground(
  String prompt, {
  required String title,
  String note = '',
}) {
  final trimmed = note.trim();
  return [
    'Background on this recording. It is not part of the recording itself.',
    '- File name: "$title". It may or may not describe the content.',
    if (trimmed.isNotEmpty) ...[
      '- Note from the person who made it:',
      '"""',
      trimmed,
      '"""',
    ],
    '',
    prompt,
  ].join('\n');
}

String buildTranscriptionPrompt(Language language) {
  if (language.code == 'en') {
    return '''Transcribe this English audio recording verbatim.

$_outputFormat

$_timestampRules
''';
  }
  const codeSwitching =
      '- Speakers also mix in English words and short phrases (code-switching).';
  final notes = [
    for (final line in language.notes.split('\n'))
      if (line.trim().isNotEmpty) '- ${line.trim()}',
  ];
  final languageNote = notes.isEmpty
      ? 'LANGUAGE NOTE:\n'
            '- This audio is primarily in ${language.name}, written in '
            '${language.script}.\n'
            '$codeSwitching'
      : 'CRITICAL LANGUAGE NOTE:\n${notes.join('\n')}\n$codeSwitching';
  return '''Transcribe this audio recording verbatim.

$languageNote

Output rules:
- Render ${language.name} speech in ${language.script} only.
- Render English speech in standard Latin/English script.
- Do not translate. Preserve the original language of each word as spoken.
${language.code == 'ja' ? '\n$_furigana\n' : ''}
$_outputFormat

$_timestampRules
''';
}

String buildTranslationPrompt(Language language) {
  return '''You are translating an SRT subtitle file to English.

The input mixes ${language.name} (${language.script} script) and English code-switched speech.

CRITICAL: Preserve the SRT structure EXACTLY:
- Same number of cues, in the same order.
- Same cue numbers.
- Same timestamps (do not modify the HH:MM:SS,mmm values).
- Same speaker labels (e.g. "Speaker 1:" prefixes).

Translate the spoken text content:
- Translate ${language.name} to natural conversational English.
- Keep English words/phrases as-is — do not re-translate them.
- Aim for natural English, not literal word-for-word.

Output ONLY the translated SRT. No preamble, no code fences, no commentary.
''';
}

const summaryPrompt = '''You are summarizing a recording transcript that has been translated to English.
Each line is prefixed with a speaker label (e.g. "Speaker 1:" or a name like "Ali:").

Produce a concise summary in English with markdown formatting:
- A 1-2 sentence overview of what the recording is about.
- 3-6 bullet points covering main topics, decisions, and action items.
- Attribute decisions/actions to speakers by their label/name where relevant.

Keep under 250 words. No preamble or sign-off — just the summary.

Transcript follows.
''';

const folderFlatPrompt =
    '''You are synthesizing a unified summary of a set of related recordings.
Below are the English translations of each recording, each preceded by a heading like '## <filename>'.
Lines are prefixed with speaker labels.

Produce in English, markdown:
- 1-2 sentence overview of the set.
- 5-10 bullet points covering: main topics, decisions, action items, key speaker attributions.
- Note threads that span multiple recordings or topics revisited.

Under 400 words. No preamble.

Translations follow.
''';

const folderHierPrompt = '''You are synthesizing a unified summary of a set of related recordings from per-recording summaries.
Below are individual summaries of each recording, each preceded by a heading like '## <filename>'.

Produce in English, markdown:
- 1-2 sentence overview of the set.
- 5-10 bullet points covering: main themes, decisions, action items.
- Highlight cross-recording threads and topic transitions.

Under 400 words. No preamble.

Summaries follow.
''';

const _notesParagraph = '''Lines in square brackets that start with "Note at" were written by the person who made the recording, at that point in it. They are background, not speech. Use them to understand what is being discussed, and do not attribute them to a speaker.

''';

const _picturesParagraph = '''Pictures follow the transcript, each introduced by its number. A note line that names a picture refers to it. Use the pictures as background too, and do not describe them unless they matter to the summary.

''';

String _withContext(String prompt, String lastLine, String paragraphs) {
  assert(prompt.endsWith(lastLine));
  return prompt.substring(0, prompt.length - lastLine.length) +
      paragraphs +
      lastLine;
}

/// The summary prompt, explaining note lines and pictures when the input has
/// them.
String summaryPromptFor({required bool notes, bool pictures = false}) =>
    notes || pictures
    ? _withContext(
        summaryPrompt,
        'Transcript follows.\n',
        '$_notesParagraph${pictures ? _picturesParagraph : ''}',
      )
    : summaryPrompt;

/// The flat folder summary prompt, explaining note lines when the input has
/// them.
String folderFlatPromptFor({required bool notes}) => notes
    ? _withContext(folderFlatPrompt, 'Translations follow.\n', _notesParagraph)
    : folderFlatPrompt;
