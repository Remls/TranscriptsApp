import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'fullscreen_video.dart';
import 'furigana_icon.dart';
import 'library_list.dart';
import 'job.dart';
import 'job_panel.dart';
import 'language_editor.dart';
import 'languages.dart';
import 'library.dart';
import 'library_search.dart';
import 'line_actions.dart';
import 'markdown_view.dart';
import 'note_editor.dart';
import 'notes.dart';
import 'pip.dart';
import 'playback.dart';
import 'recording_actions.dart';
import 'player_bar.dart';
import 'ruby.dart';
import 'search.dart';
import 'session.dart';
import 'settings_screen.dart';
import 'srt.dart';
import 'swipe_back.dart';
import 'transcript_view.dart';
import 'video_panel.dart';
import 'transcription_job.dart';

enum _Tab {
  transcript('Transcript', 'transcript', JobKind.transcribe),
  translation('Translation', 'translation', JobKind.translate),
  summary('Summary', 'summary', JobKind.summary);

  const _Tab(this.label, this.noun, this.kind);

  final String label;
  final String noun;
  final JobKind kind;
}

/// The open recording: its video, its transcript, translation and summary
/// tabs, and the player.
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({
    super.key,
    required this.session,
    required this.pip,
    required this.onLibraryChanged,
    this.hit,
    this.query = '',
  });

  final Session session;
  final PipController pip;

  /// Called when an action here changed the library's files.
  final VoidCallback onLibraryChanged;

  /// A library search hit to show, with the [query] that found it.
  final LibraryHit? hit;
  final String query;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> with RouteAware {
  bool _showVideo = true;

  /// The picture of the open recording when it is a video.
  VideoPicture? _picture;

  /// The open recording's path, to notice when another one opens.
  String? _openPath;

  /// Whether this screen is in front of every other route.
  bool _inFront = true;
  StreamSubscription<bool>? _playingSub;

  /// The tab controller of the open recording, its key and its last index.
  TabController? _tabController;
  String? _tabKey;
  int _tabIndex = 0;

  /// The search in the open recording: whether it is open, the query it
  /// searches for, and the index of the current match.
  bool _searching = false;

  /// The selected lines as (cue, item) pairs, or null when not selecting.
  Set<(int, int)>? _selection;

  /// Whether the search field takes the keyboard when it opens.
  bool _focusSearch = true;
  final _searchField = TextEditingController();

  /// The note about the open recording, as typed in the transcription panel.
  var _context = '';
  String? _contextPath;
  Timer? _searchDebounce;
  String _query = '';
  int _matchIndex = 0;

  Session get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    _playingSub = _session.player.playingStream.listen((_) => _updatePip());
    widget.pip.onAction = _onPipAction;
    _onSessionChanged();
    final hit = widget.hit;
    if (hit != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openAtHit(hit, widget.query);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) pipRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() {
    _inFront = false;
    _updatePip();
  }

  @override
  void didPopNext() {
    _inFront = true;
    _updatePip();
  }

  void _onSessionChanged() {
    final recording = _session.recording;
    if (recording == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final route = ModalRoute.of(context);
        if (mounted && route != null && route.isActive) {
          Navigator.of(context).removeRoute(route);
        }
      });
    }
    final video = _session.player.video;
    if (!identical(video, _picture?.controller)) {
      _picture
        ?..removeListener(_updatePip)
        ..dispose();
      _picture = video == null
          ? null
          : (VideoPicture(video)..addListener(_updatePip));
    }
    final path = recording?.relPath;
    if (path != _openPath) {
      _openPath = path;
      _matchIndex = 0;
      _selection = null;
    }
    _updatePip();
  }

  /// Tells the system whether leaving the app shrinks the video.
  void _updatePip() {
    final picture = _picture;
    final ready = picture != null && picture.isInitialized;
    final size = ready ? picture.controller.value.size : Size.zero;
    widget.pip.update(
      active: pipAllowed(
        isVideo: picture != null,
        showVideo: _showVideo,
        playing: _session.player.playing,
        videoReady: ready,
        inFront: _inFront || (picture?.fullscreen ?? false),
      ),
      playing: _session.player.playing,
      width: size.width.round(),
      height: size.height.round(),
    );
  }

  void _onPipAction(PipAction action) {
    final player = _session.player;
    switch (action) {
      case .back:
        _session.seekBy(-skipInterval);
      case .forward:
        _session.seekBy(skipInterval);
      case .play:
        player.play();
      case .pause:
        player.pause();
    }
  }

  void _setShowVideo(bool show) {
    setState(() => _showVideo = show);
    _updatePip();
  }

  /// Keeps [_tabIndex] current for the tab controller of [key].
  void _rememberTabs(TabController controller, String key) {
    if (identical(controller, _tabController)) return;
    _tabController = controller;
    _tabKey = key;
    _tabIndex = controller.index;
    controller.addListener(() {
      if (controller.index == _tabIndex) return;
      _tabIndex = controller.index;
      if (_searching) setState(() => _matchIndex = 0);
    });
  }

  /// Opens the actions for a line of the transcript, or of the translation
  /// into [translation] when given.
  void _onLineLongPress(int cue, int item, {String? translation}) {
    if (_selection != null) {
      _toggleLine(cue, item);
      return;
    }
    showLineActions(
      context,
      _session,
      translation: translation,
      cue: cue,
      item: item,
      onSelect: () => setState(() => _selection = {(cue, item)}),
    );
  }

  void _toggleLine(int cue, int item) => setState(() {
    final selection = _selection;
    if (selection == null) return;
    if (!selection.remove((cue, item))) selection.add((cue, item));
    if (selection.isEmpty) _selection = null;
  });

  void _clearSelection() => setState(() => _selection = null);

  /// The selected lines in reading order.
  List<(int, int)> _selectedLines() {
    final lines = _selection!.toList()
      ..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
    return lines;
  }

  PreferredSizeWidget _tabBar(List<_Tab> tabs) =>
      TabBar(tabs: [for (final t in tabs) Tab(text: t.label)]);

  PreferredSizeWidget _selectionBar(List<_Tab> tabs) {
    final count = _selection!.length;
    return AppBar(
      leading: IconButton(
        tooltip: 'Stop selecting',
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text('$count selected'),
      actions: [
        IconButton(
          tooltip: 'Change speaker',
          icon: const Icon(Icons.swap_horiz),
          onPressed: () async {
            if (await changeSpeakerOf(context, _session, _selectedLines())) {
              _clearSelection();
            }
          },
        ),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            if (await deleteLines(context, _session, _selectedLines())) {
              _clearSelection();
            }
          },
        ),
      ],
      bottom: _tabBar(tabs),
    );
  }

  void _openSearch() => setState(() {
    _searching = true;
    _focusSearch = true;
  });

  void _closeSearch() {
    _searchDebounce?.cancel();
    _searchField.clear();
    setState(() {
      _searching = false;
      _query = '';
      _matchIndex = 0;
    });
  }

  void _setQuery(String text) {
    _searchDebounce?.cancel();
    setState(() {
      _query = text;
      _matchIndex = 0;
    });
  }

  void _onSearchChanged(String text) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _setQuery(text);
    });
  }

  void _onSearchSubmitted(String text, int count) {
    if (text != _query) {
      _setQuery(text);
    } else if (count > 0) {
      setState(() => _matchIndex = (_matchIndex + 1) % count);
    }
  }

  /// The lines shown on [tab] of [recording], or null when it shows none.
  List<Cue>? _cuesOn(Recording recording, _Tab tab) => switch (tab) {
    _Tab.transcript => recording.hasTranscript ? _session.cues : null,
    _Tab.translation =>
      recording.hasTranslation ? _session.translatedCues : null,
    _Tab.summary => null,
  };

  /// The matches of the query on [tab] of [recording].
  List<SearchMatch> _matchesOn(Recording recording, _Tab tab) {
    final cues = _cuesOn(recording, tab);
    if (!_searching || cues == null) return const [];
    return findMatches(transcriptRows(cues, _session.notes), cues, _query);
  }

  /// Opens the recording [hit] is in at its time, on the tab that shows it,
  /// with a search for [query] on that match.
  Future<void> _openAtHit(LibraryHit hit, String query) async {
    final file = _session.library.recordingAt(hit.relPath);
    if (file == null) return;
    final recording = _session.library.describe(file);
    final position = Duration(milliseconds: (hit.time * 1000).round());
    if (_session.recording?.relPath == recording.relPath) {
      await _session.player.seek(position);
    } else {
      await _session.open(recording, position: position);
    }
    if (hit.source == HitSource.translation) {
      _session.showTranslation(hit.lang);
    }
    if (!mounted) return;
    final tabs = _tabsFor(recording);
    final tab = switch (hit.source) {
      HitSource.transcript => _Tab.transcript,
      HitSource.translation => _Tab.translation,
      HitSource.note =>
        recording.hasTranscript || !recording.hasTranslation
            ? _Tab.transcript
            : _Tab.translation,
    };
    final tabIndex = tabs.indexOf(tab).clamp(0, tabs.length - 1);
    _searchDebounce?.cancel();
    _searchField.text = query;
    setState(() {
      _searching = true;
      _focusSearch = false;
      _query = query;
      _tabIndex = tabIndex;
      _tabKey = '${recording.relPath}:${tabs.length}';
      final cues = _cuesOn(recording, tab) ?? const [];
      final rows = transcriptRows(cues, _session.notes);
      final matches = _matchesOn(recording, tab);
      final at = matches.indexWhere(
        (m) => hit.source == HitSource.note
            ? m.cue == null &&
                  (rows[m.row] as Note).id == hit.noteId &&
                  m.start == hit.start
            : m.cue == hit.cue && m.item == hit.item && m.start == hit.start,
      );
      _matchIndex = at < 0 ? 0 : at;
    });
    final controller = _tabController;
    if (controller != null && controller.length == tabs.length) {
      controller.animateTo(tabIndex);
    }
  }

  /// The search to show on [tab], or null when no search is open.
  SearchHighlight? _highlightOn(Recording recording, _Tab tab) {
    if (!_searching) return null;
    final matches = _matchesOn(recording, tab);
    final tabs = _tabsFor(recording);
    final shown = tabs[_tabIndex.clamp(0, tabs.length - 1)];
    return SearchHighlight(
      matches,
      tab == shown && matches.isNotEmpty
          ? _matchIndex.clamp(0, matches.length - 1)
          : -1,
    );
  }

  Future<void> _onRecordingAction(
    Recording recording,
    RecordingAction action,
  ) async {
    final produced = await runRecordingAction(
      context,
      _session,
      recording,
      action,
      widget.onLibraryChanged,
    );
    widget.onLibraryChanged();
    if (produced != null) {
      await _session.open(_session.library.describe(produced));
    }
    _refresh();
  }

  @override
  void dispose() {
    pipRouteObserver.unsubscribe(this);
    widget.pip.update(active: false);
    _session.removeListener(_onSessionChanged);
    _playingSub?.cancel();
    widget.pip.onAction = null;
    _picture?.dispose();
    _searchDebounce?.cancel();
    _searchField.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(session: _session),
      ),
    ).then((_) => _refresh());
  }

  /// English recordings need no translation tab.
  List<_Tab> _tabsFor(Recording recording) => [
    _Tab.transcript,
    if (recording.lang != 'en') _Tab.translation,
    _Tab.summary,
  ];

  bool _hasContent(Recording recording, _Tab tab) => switch (tab) {
    _Tab.transcript => recording.hasTranscript,
    _Tab.translation => recording.hasTranslation,
    _Tab.summary => recording.hasSummary,
  };

  /// The note typed for [recording], starting from its saved note.
  String _contextFor(Recording recording) {
    if (_contextPath != recording.relPath) {
      _contextPath = recording.relPath;
      _context = _session.library.contextOf(recording.file);
    }
    return _context;
  }

  /// Starts the job behind [tab], reporting a missing setting or a failed
  /// regeneration in a snackbar.
  void _start(Recording recording, _Tab tab, {String? lang, String? note}) {
    final hadContent = _hasContent(recording, tab);
    final problem = switch (tab) {
      _Tab.transcript => _session.startTranscription(
        recording,
        lang ?? _session.transcribeLang,
        context: note ?? _contextFor(recording),
      ),
      _Tab.translation => _session.startTranslation(recording),
      _Tab.summary => _session.startSummary(recording),
    };
    final messenger = ScaffoldMessenger.of(context);
    if (problem != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(problem),
          persist: false,
          action: SnackBarAction(label: 'Settings', onPressed: _openSettings),
        ),
      );
      return;
    }
    final job = _session.jobFor(tab.kind, recording.relPath)!;
    void onChange() {
      if (job.state == JobState.running) return;
      job.removeListener(onChange);
      if (!mounted) return;
      _refresh();
      if (job.state == JobState.failed && hadContent) {
        messenger.showSnackBar(
          SnackBar(content: Text('${tab.label} failed: ${job.error}')),
        );
      }
    }

    job.addListener(onChange);
  }

  Future<void> _regenerate(Recording recording, _Tab tab) async {
    var lang = _session.languages.contains(recording.lang)
        ? recording.lang
        : _session.transcribeLang;
    var note = _session.library.contextOf(recording.file);
    final confirmed = await confirmRegenerate(
      context,
      what: tab.noun,
      options: tab != _Tab.transcript
          ? null
          : StatefulBuilder(
              builder: (context, setDialogState) => Column(
                mainAxisSize: .min,
                crossAxisAlignment: .start,
                children: [
                  LanguageRow(
                    label: 'Language',
                    languages: _session.languages,
                    lookup: _session.languageLookup,
                    value: lang,
                    onChanged: (code) => setDialogState(() => lang = code),
                  ),
                  const SizedBox(height: 16),
                  ContextField(
                    initialText: note,
                    onChanged: (text) => note = text,
                  ),
                ],
              ),
            ),
    );
    if (confirmed && mounted) {
      _start(recording, tab, lang: lang, note: note);
    }
  }

  Widget _menu(Recording recording) {
    return PopupMenuButton<RecordingAction>(
      onSelected: (action) => _onRecordingAction(recording, action),
      itemBuilder: (context) => [
        for (final (i, group) in recordingActionGroups.indexed) ...[
          if (i > 0) const PopupMenuDivider(),
          for (final (action, _, label) in group)
            PopupMenuItem(value: action, child: Text(label)),
        ],
      ],
    );
  }

  /// The strip above a tab's content, with the actions that belong to it.
  Widget _strip(Recording recording, _Tab tab) {
    final lines = switch (tab) {
      _Tab.transcript => _session.cues,
      _Tab.translation => _session.translatedCues,
      _Tab.summary => null,
    }?.fold(0, (sum, cue) => sum + cue.items.length);
    final furigana = _session.settings.readings;
    return ActionStrip(
      info: lines == null ? null : '$lines ${lines == 1 ? 'line' : 'lines'}',
      hint: lines == null ? null : 'Long-press a line to edit',
      actions: [
        if (tab == _Tab.transcript && _session.furiganaCues.isNotEmpty)
          IconButton(
            tooltip: furigana ? 'Hide furigana' : 'Show furigana',
            onPressed: () => _session.settings.setReadings(!furigana),
            icon: FuriganaIcon(off: !furigana),
          ),
        if (tab == _Tab.transcript)
          IconButton(
            tooltip: 'Speakers',
            onPressed: () => showSpeakersSheet(context, _session),
            icon: const Icon(Icons.people_outline),
          ),
        IconButton(
          tooltip: 'Regenerate',
          onPressed: () => _regenerate(recording, tab),
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _session,
        _session.settings,
        _session.durations,
        widget.pip,
      ]),
      builder: (context, _) {
        final recording = _session.recording;
        final picture = _picture;
        if (widget.pip.inPip && picture != null && picture.isInitialized) {
          return PipVideo(picture: picture);
        }
        if (recording == null) return const Scaffold();
        final tabs = _tabsFor(recording);
        final tabKey = '${recording.relPath}:${tabs.length}';
        return DefaultTabController(
          key: ValueKey(tabKey),
          length: tabs.length,
          initialIndex: tabKey == _tabKey ? _tabIndex : 0,
          child: Builder(
            builder: (tabContext) {
              _rememberTabs(DefaultTabController.of(tabContext), tabKey);
              return _scaffold(recording, tabs);
            },
          ),
        );
      },
    );
  }

  Widget _scaffold(Recording recording, List<_Tab> tabs) {
    final picture = _picture;
    final shown = tabs[_tabIndex.clamp(0, tabs.length - 1)];
    final matchCount = _matchesOn(recording, shown).length;
    final current = matchCount == 0 ? 0 : _matchIndex.clamp(0, matchCount - 1);
    return PopScope(
      canPop: !_searching && _selection == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selection != null) {
          _clearSelection();
        } else {
          _closeSearch();
        }
      },
      child: Scaffold(
        appBar: _selection != null
            ? _selectionBar(tabs)
            : AppBar(
                leading: _searching
                    ? IconButton(
                        tooltip: 'Close search',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: _closeSearch,
                      )
                    : null,
                title: _searching
                    ? TextField(
                        controller: _searchField,
                        autofocus: _focusSearch,
                        textInputAction: TextInputAction.search,
                        onChanged: _onSearchChanged,
                        onSubmitted: (text) =>
                            _onSearchSubmitted(text, matchCount),
                        decoration: const InputDecoration(
                          hintText: 'Search',
                          border: InputBorder.none,
                        ),
                      )
                    : Text(recording.name),
                actions: _searching
                    ? [
                        if (_query.trim().isNotEmpty)
                          Text(
                            matchCount == 0
                                ? 'No matches'
                                : '${current + 1} of $matchCount',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        IconButton(
                          tooltip: 'Previous match',
                          icon: const Icon(Icons.keyboard_arrow_up),
                          onPressed: matchCount == 0
                              ? null
                              : () => setState(
                                  () =>
                                      _matchIndex = (current - 1) % matchCount,
                                ),
                        ),
                        IconButton(
                          tooltip: 'Next match',
                          icon: const Icon(Icons.keyboard_arrow_down),
                          onPressed: matchCount == 0
                              ? null
                              : () => setState(
                                  () =>
                                      _matchIndex = (current + 1) % matchCount,
                                ),
                        ),
                      ]
                    : [
                        if (recording.isVideo && !_session.pictureUnavailable)
                          IconButton(
                            tooltip: _showVideo ? 'Hide video' : 'Show video',
                            icon: Icon(
                              _showVideo
                                  ? Icons.videocam_outlined
                                  : Icons.videocam_off_outlined,
                            ),
                            onPressed: () => _setShowVideo(!_showVideo),
                          ),
                        IconButton(
                          tooltip: 'Search',
                          icon: const Icon(Icons.search),
                          onPressed: _openSearch,
                        ),
                        _menu(recording),
                      ],
                bottom: _tabBar(tabs),
              ),
        body: _session.loadError != null
            ? _Message(_session.loadError!)
            : Column(
                children: [
                  if (_session.preparing)
                    const _Notice(
                      'Preparing this file for playback. This happens once.',
                      busy: true,
                    ),
                  if (_session.pictureUnavailable)
                    const _Notice(
                      'This video\'s picture can\'t be shown on this phone. '
                      'Its sound plays as usual.',
                    ),
                  if (picture != null && _showVideo)
                    VideoPanel(
                      key: ValueKey(recording.relPath),
                      session: _session,
                      picture: picture,
                      pip: widget.pip,
                      subtitles: () => firstSubtitles(
                        switch (tabs[_tabIndex.clamp(0, tabs.length - 1)]) {
                          _Tab.transcript => [SubtitleMode.transcript],
                          _Tab.translation => [SubtitleMode.translation],
                          _Tab.summary => [
                            SubtitleMode.translation,
                            SubtitleMode.transcript,
                          ],
                        },
                        hasTranscript: _session.cues.isNotEmpty,
                        hasTranslation: _session.translatedCues.isNotEmpty,
                      ),
                    ),
                  Expanded(
                    child: SwipeBack(
                      onSwipeBack: () => Navigator.maybePop(context),
                      child: TabBarView(
                        children: [
                          for (final t in tabs) _tabBody(recording, t),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
        bottomNavigationBar: PlayerBar(
          session: _session,
          onAddNote: () => editNote(context, _session),
        ),
      ),
    );
  }

  Widget _tabBody(Recording recording, _Tab tab) {
    final job = _session.jobFor(tab.kind, recording.relPath);
    final running = job?.state == JobState.running;
    final language = _session.languages.resolve(recording.lang);
    switch (tab) {
      case _Tab.transcript:
        if (!recording.hasTranscript || running) {
          return JobPanel(
            icon: Icons.subject,
            title: 'No transcript yet',
            actionLabel: 'Transcribe',
            job: job,
            outputRtl: job is TranscriptionJob
                ? job.language.rtl
                : language.rtl,
            showOutput: stripRuby,
            options: Column(
              mainAxisSize: .min,
              children: [
                LanguageRow(
                  label: 'Language',
                  languages: _session.languages,
                  lookup: _session.languageLookup,
                  value: _session.transcribeLang,
                  onChanged: _session.settings.setTranscribeLang,
                ),
                const SizedBox(height: 16),
                ContextField(
                  key: ValueKey('${recording.relPath}:context'),
                  initialText: _contextFor(recording),
                  onChanged: (text) => _context = text,
                ),
              ],
            ),
            onStart: () => _start(recording, tab),
          );
        }
        return Column(
          children: [
            _strip(recording, tab),
            if (!_session.languages.contains(recording.lang))
              _UnknownLanguageBar(
                language: language,
                onAdd: () => showLanguageEditor(
                  context,
                  _session.languages,
                  _session.languageLookup,
                  code: recording.lang,
                ),
              ),
            Expanded(
              child: _session.cues.isEmpty
                  ? const _Message('No cues parsed')
                  : _transcriptView(recording),
            ),
          ],
        );
      case _Tab.translation:
        if (!recording.hasTranslation || running) {
          return JobPanel(
            icon: Icons.translate,
            title: 'No English translation yet',
            actionLabel: 'Translate',
            job: job,
            note: recording.hasTranscript
                ? null
                : 'Transcribe this recording first',
            onStart: recording.hasTranscript
                ? () => _start(recording, tab)
                : null,
          );
        }
        return Column(
          children: [
            _strip(recording, tab),
            Expanded(
              child: _session.translatedCues.isEmpty
                  ? const _Message('No cues parsed')
                  : _translationView(recording),
            ),
          ],
        );
      case _Tab.summary:
        final summary = _session.summary;
        if (summary == null || running) {
          final ready = recording.lang == 'en'
              ? recording.hasTranscript
              : recording.hasTranslation;
          return JobPanel(
            icon: Icons.summarize_outlined,
            title: 'No summary yet',
            actionLabel: 'Summarize',
            job: job,
            note: ready
                ? null
                : recording.lang == 'en'
                ? 'Transcribe this recording first'
                : 'Translate this recording first',
            onStart: ready ? () => _start(recording, tab) : null,
          );
        }
        return Column(
          children: [
            _strip(recording, tab),
            Expanded(child: MarkdownView(summary)),
          ],
        );
    }
  }

  Widget _transcriptView(Recording recording) {
    return TranscriptView(
      key: ValueKey('${recording.relPath}:transcript'),
      search: _highlightOn(recording, _Tab.transcript),
      cues: _session.cues,
      readings: _session.settings.readings && _session.furiganaCues.isNotEmpty
          ? _session.furiganaCues
          : null,
      notes: _session.notes,
      noteImage: _session.noteImageOf,
      onPictureTap: (picture) => showPicture(context, picture),
      onNoteTap: (note) => editNote(context, _session, existing: note),
      language: _session.languages.resolve(recording.lang),
      speakerNames: _session.speakerNames,
      speakerOverrides: _session.speakerOverrides,
      activeIndex: _session.activeIndex,
      onSeek: _session.seekAndPlay,
      onLineLongPress: (cue, item) => _onLineLongPress(cue, item),
      selected: _selection,
      onLineTap: _toggleLine,
    );
  }

  Widget _translationView(Recording recording) {
    return TranscriptView(
      key: ValueKey('${recording.relPath}:translation'),
      search: _highlightOn(recording, _Tab.translation),
      cues: _session.translatedCues,
      notes: _session.notes,
      noteImage: _session.noteImageOf,
      onPictureTap: (picture) => showPicture(context, picture),
      onNoteTap: (note) => editNote(context, _session, existing: note),
      language: _session.languages.resolve(_session.translationLang),
      speakerNames: _session.speakerNames,
      speakerOverrides: _session.speakerOverrides,
      activeIndex: _session.translationActiveIndex,
      onSeek: _session.seekAndPlay,
      onLineLongPress: (cue, item) =>
          _onLineLongPress(cue, item, translation: _session.translationLang),
      selected: _selection,
      onLineTap: _toggleLine,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: .center,
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Says that the open recording's language is missing from the list, and
/// offers to add it.
class _UnknownLanguageBar extends StatelessWidget {
  const _UnknownLanguageBar({required this.language, required this.onAdd});

  final Language language;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: InkWell(
        onTap: onAdd,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Icon(
                Icons.translate,
                size: 18,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  language.name,
                  style: TextStyle(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
              TextButton(onPressed: onAdd, child: const Text('Add')),
            ],
          ),
        ),
      ),
    );
  }
}

/// A slim bar above the tabs with a line about the open recording.
class _Notice extends StatelessWidget {
  const _Notice(this.text, {this.busy = false});

  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
          if (busy) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}
