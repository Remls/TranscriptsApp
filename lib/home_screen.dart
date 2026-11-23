import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'combine_screen.dart';
import 'file_drawer.dart';
import 'folder_screen.dart';
import 'job.dart';
import 'job_panel.dart';
import 'language_editor.dart';
import 'languages.dart';
import 'library.dart';
import 'library_actions.dart' as actions;
import 'library_search.dart';
import 'library_search_screen.dart';
import 'line_actions.dart';
import 'markdown_view.dart';
import 'note_editor.dart';
import 'notes.dart';
import 'pip.dart';
import 'player_bar.dart';
import 'rechunk.dart';
import 'search.dart';
import 'session.dart';
import 'settings_screen.dart';
import 'share_receiver.dart';
import 'share_sheet.dart';
import 'srt.dart';
import 'split_screen.dart';
import 'transcript_view.dart';
import 'video_panel.dart';
import 'transcription_job.dart';
import 'trash_screen.dart';

enum _Tab {
  transcript('Transcript', 'transcript', JobKind.transcribe),
  translation('Translation', 'translation', JobKind.translate),
  summary('Summary', 'summary', JobKind.summary);

  const _Tab(this.label, this.noun, this.kind);

  final String label;
  final String noun;
  final JobKind kind;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.session, required this.pip});

  final Session session;
  final PipController pip;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, RouteAware {
  late List<LibrarySection> _sections;
  bool _showVideo = true;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// The picture of the open recording when it is a video.
  VideoFollower? _follower;
  String? _followerPath;

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

  /// Whether the search field takes the keyboard when it opens.
  bool _focusSearch = true;
  final _searchField = TextEditingController();
  Timer? _searchDebounce;
  String _query = '';
  int _matchIndex = 0;

  /// The drawer sections the user has open.
  final _expandedSections = <String>{};

  Session get _session => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sections = _session.library.scan();
    _probeDurations();
    _session.restore();
    listenForSharedFiles(_importShared);
    _session.addListener(_onSessionChanged);
    _playingSub = _session.player.playingStream.listen((_) => _updatePip());
    widget.pip.onAction = _onPipAction;
    _onSessionChanged();
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
    final path = recording != null && recording.isVideo
        ? recording.file.path
        : null;
    if (path != _followerPath) {
      _follower
        ?..removeListener(_updatePip)
        ..dispose();
      _follower = path == null
          ? null
          : (VideoFollower(_session.player, File(path))
              ..addListener(_updatePip));
      _followerPath = path;
      _matchIndex = 0;
    }
    _updatePip();
  }

  /// Tells the system whether leaving the app shrinks the video.
  void _updatePip() {
    final follower = _follower;
    final ready = follower != null && follower.isInitialized;
    final size = ready ? follower.controller.value.size : Size.zero;
    widget.pip.update(
      active: pipAllowed(
        isVideo: follower != null,
        showVideo: _showVideo,
        playing: _session.player.playing,
        videoReady: ready,
        inFront: _inFront || (follower?.fullscreen ?? false),
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
        _session.seekBy(const Duration(seconds: -10));
      case .forward:
        _session.seekBy(const Duration(seconds: 10));
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

  Future<void> _importPicked() async {
    final picked = await FilePicker.pickFiles();
    if (!mounted) return;
    await actions.importSources(context, _session, [
      for (final f in picked)
        if (f.path != null) (file: File(f.path!), name: f.name),
    ]);
    await FilePicker.clearTemporaryFiles();
    if (mounted) _rescan();
  }

  /// Imports files another app shared, then removes their cache copies.
  Future<void> _importShared(List<File> files, int unreadable) async {
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            unreadable == 1
                ? 'The shared file could not be read'
                : 'The shared files could not be read',
          ),
          persist: false,
        ),
      );
      return;
    }
    await actions.importSources(context, _session, [
      for (final f in files) (file: f, name: p.basename(f.path)),
    ]);
    for (final f in files) {
      if (f.parent.existsSync()) f.parent.deleteSync(recursive: true);
    }
    if (mounted) _rescan();
  }

  /// Opens the combine screen for [folder] with [preselected] ticked, then
  /// opens the combined recording.
  Future<void> _combine(Directory folder, Set<String> preselected) async {
    final combined = await Navigator.push<File>(
      context,
      MaterialPageRoute(
        builder: (_) => CombineScreen(
          session: _session,
          folder: folder,
          preselected: preselected,
        ),
      ),
    );
    if (!mounted) return;
    _rescan();
    if (combined != null) {
      await _session.open(_session.library.describe(combined));
    }
  }

  /// Opens the split screen for [recording]'s family, then opens the first
  /// chunk.
  Future<void> _split(Recording recording) async {
    final first = await Navigator.push<File>(
      context,
      MaterialPageRoute(
        builder: (_) => SplitScreen(session: _session, recording: recording),
      ),
    );
    if (!mounted) return;
    _rescan();
    if (first != null) await _session.open(_session.library.describe(first));
  }

  void _closeDrawer() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
  }

  /// Every recording in [section] when they share one format, else none.
  Set<String> _allIfOneFormat(LibrarySection section) {
    final formats = {
      for (final r in section.recordings)
        p.extension(r.file.path).toLowerCase(),
    };
    return formats.length == 1
        ? {for (final r in section.recordings) r.file.path}
        : {};
  }

  Future<void> _onLibraryAction(LibraryAction action) async {
    switch (action) {
      case LibraryAction.search:
        Navigator.pop(context);
        final picked = await Navigator.push<PickedHit>(
          context,
          MaterialPageRoute(
            builder: (_) => LibrarySearchScreen(
              rootPath: _session.library.root.path,
              languageOf: _session.languages.resolve,
            ),
          ),
        );
        if (picked != null && mounted) {
          await _openAtHit(picked.hit, picked.query);
        }
      case LibraryAction.import:
        Navigator.pop(context);
        await _importPicked();
      case LibraryAction.newFolder:
        await actions.createFolder(context, _session);
      case LibraryAction.trash:
        Navigator.pop(context);
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => TrashScreen(library: _session.library),
          ),
        );
      case LibraryAction.settings:
        Navigator.pop(context);
        _openSettings();
    }
    if (mounted) _rescan();
  }

  Future<void> _onFolderAction(
    LibrarySection section,
    FolderAction action,
  ) async {
    final folder = section.folder!;
    switch (action) {
      case FolderAction.summary:
        Navigator.pop(context);
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => FolderScreen(
              session: _session,
              folder: folder,
              onOpenSettings: _openSettings,
            ),
          ),
        );
      case FolderAction.combine:
        Navigator.pop(context);
        await _combine(folder, _allIfOneFormat(section));
      case FolderAction.shareZip:
        Navigator.pop(context);
        await shareFolderZip(context, _session, folder);
      case FolderAction.rename:
        await actions.renameFolder(context, _session, folder);
      case FolderAction.trash:
        await actions.trashFolder(context, _session, folder, _rescan);
    }
    if (mounted) _rescan();
  }

  Future<void> _onRecordingAction(
    Recording recording,
    RecordingAction action,
  ) async {
    switch (action) {
      case RecordingAction.share:
        await showShareSheet(context, _session, recording);
      case RecordingAction.split:
        _closeDrawer();
        await _split(recording);
      case RecordingAction.combine:
        _closeDrawer();
        await _combine(recording.file.parent, {
          for (final f in familyMembers(recording.file)) f.path,
        });
      case RecordingAction.rename:
        await actions.renameRecording(context, _session, recording);
      case RecordingAction.move:
        await actions.moveRecording(context, _session, recording);
      case RecordingAction.trash:
        await actions.trashRecording(context, _session, recording, _rescan);
    }
    if (mounted) _rescan();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pipRouteObserver.unsubscribe(this);
    _session.removeListener(_onSessionChanged);
    _playingSub?.cancel();
    widget.pip.onAction = null;
    _follower?.dispose();
    _searchDebounce?.cancel();
    _searchField.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _session.persistPosition();
  }

  void _rescan() {
    setState(() => _sections = _session.library.scan());
    _probeDurations();
  }

  void _probeDurations() {
    _session.durations.probe([
      for (final section in _sections) ...section.recordings,
    ]);
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(session: _session),
      ),
    ).then((_) {
      if (mounted) _rescan();
    });
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

  /// Starts the job behind [tab], reporting a missing setting or a failed
  /// regeneration in a snackbar.
  void _start(Recording recording, _Tab tab, {String? lang}) {
    final hadContent = _hasContent(recording, tab);
    final problem = switch (tab) {
      _Tab.transcript => _session.startTranscription(
        recording,
        lang ?? _session.transcribeLang,
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
      _rescan();
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
    final confirmed = await confirmRegenerate(
      context,
      what: tab.noun,
      options: tab != _Tab.transcript
          ? null
          : StatefulBuilder(
              builder: (context, setDialogState) => LanguageRow(
                label: 'Language',
                languages: _session.languages,
                lookup: _session.languageLookup,
                value: lang,
                onChanged: (code) => setDialogState(() => lang = code),
              ),
            ),
    );
    if (confirmed && mounted) _start(recording, tab, lang: lang);
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
    return ActionStrip(
      info: lines == null ? null : '$lines ${lines == 1 ? 'line' : 'lines'}',
      hint: lines == null ? null : 'Long-press a line to edit',
      actions: [
        if (tab == _Tab.transcript)
          TextButton.icon(
            onPressed: () => showSpeakersSheet(context, _session),
            icon: const Icon(Icons.people_outline, size: 18),
            label: const Text('Speakers'),
          ),
        TextButton.icon(
          onPressed: () => _regenerate(recording, tab),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Regenerate'),
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
        final follower = _follower;
        if (widget.pip.inPip && follower != null && follower.isInitialized) {
          return PipVideo(follower: follower);
        }
        final drawer = FileDrawer(
          sections: _sections,
          selected: recording?.relPath,
          expanded: _expandedSections,
          durationOf: _session.durations.of,
          isBusy: (r) => _session.recordingBusy(r.relPath),
          onSelect: (r) {
            Navigator.pop(context);
            _session.open(r);
          },
          onLibraryAction: _onLibraryAction,
          onFolderAction: _onFolderAction,
          onRecordingAction: _onRecordingAction,
        );
        void onDrawerChanged(bool open) {
          if (open) _rescan();
        }

        if (recording == null) {
          return Scaffold(
            key: _scaffoldKey,
            appBar: AppBar(title: const Text('Transcripts')),
            drawer: drawer,
            onDrawerChanged: onDrawerChanged,
            body: _Message(
              _sections.isEmpty ? 'No recordings yet' : 'Select a recording',
            ),
          );
        }
        final tabs = _tabsFor(recording);
        final tabKey = '${recording.relPath}:${tabs.length}';
        return DefaultTabController(
          key: ValueKey(tabKey),
          length: tabs.length,
          initialIndex: tabKey == _tabKey ? _tabIndex : 0,
          child: Builder(
            builder: (tabContext) {
              _rememberTabs(DefaultTabController.of(tabContext), tabKey);
              return _scaffold(recording, tabs, drawer, onDrawerChanged);
            },
          ),
        );
      },
    );
  }

  Widget _scaffold(
    Recording recording,
    List<_Tab> tabs,
    Widget drawer,
    ValueChanged<bool> onDrawerChanged,
  ) {
    final follower = _follower;
    final shown = tabs[_tabIndex.clamp(0, tabs.length - 1)];
    final matchCount = _matchesOn(recording, shown).length;
    final current = matchCount == 0 ? 0 : _matchIndex.clamp(0, matchCount - 1);
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeSearch();
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
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
                  onSubmitted: (text) => _onSearchSubmitted(text, matchCount),
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
                            () => _matchIndex = (current - 1) % matchCount,
                          ),
                  ),
                  IconButton(
                    tooltip: 'Next match',
                    icon: const Icon(Icons.keyboard_arrow_down),
                    onPressed: matchCount == 0
                        ? null
                        : () => setState(
                            () => _matchIndex = (current + 1) % matchCount,
                          ),
                  ),
                ]
              : [
                  if (recording.isVideo)
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
          bottom: TabBar(tabs: [for (final t in tabs) Tab(text: t.label)]),
        ),
        drawer: drawer,
        onDrawerChanged: onDrawerChanged,
        body: _session.loadError != null
            ? _Message(_session.loadError!)
            : Column(
                children: [
                  if (follower != null && _showVideo)
                    VideoPanel(
                      key: ValueKey(recording.relPath),
                      session: _session,
                      follower: follower,
                      pip: widget.pip,
                    ),
                  Expanded(
                    child: TabBarView(
                      children: [for (final t in tabs) _tabBody(recording, t)],
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
            options: LanguageRow(
              label: 'Language',
              languages: _session.languages,
              lookup: _session.languageLookup,
              value: _session.transcribeLang,
              onChanged: _session.settings.setTranscribeLang,
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
      notes: _session.notes,
      noteImage: _session.noteImageOf,
      onPictureTap: (picture) => showPicture(context, picture),
      onNoteTap: (note) => editNote(context, _session, existing: note),
      language: _session.languages.resolve(recording.lang),
      speakerNames: _session.speakerNames,
      speakerOverrides: _session.speakerOverrides,
      activeIndex: _session.activeIndex,
      onSeek: _session.seekAndPlay,
      onLineLongPress: (cue, item) => showLineActions(
        context,
        _session,
        source: Sidecar.transcriptSrt,
        cue: cue,
        item: item,
      ),
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
      language: _session.languages.resolve('en'),
      speakerNames: _session.speakerNames,
      speakerOverrides: _session.speakerOverrides,
      activeIndex: _session.translationActiveIndex,
      onSeek: _session.seekAndPlay,
      onLineLongPress: (cue, item) => showLineActions(
        context,
        _session,
        source: Sidecar.translation,
        cue: cue,
        item: item,
      ),
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
