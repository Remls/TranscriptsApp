import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'folder_screen.dart';
import 'library.dart';
import 'library_actions.dart' as actions;
import 'library_list.dart';
import 'library_search.dart';
import 'library_search_screen.dart';
import 'mini_player.dart';
import 'pip.dart';
import 'recording_actions.dart';
import 'recording_screen.dart';
import 'session.dart';
import 'settings_screen.dart';
import 'share_receiver.dart';
import 'share_sheet.dart';
import 'trash_screen.dart';
import 'menu.dart';

/// The app's first screen: every folder and recording in the library.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.session, required this.pip});

  final Session session;
  final PipController pip;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver, RouteAware {
  late List<LibrarySection> _sections;

  /// The titles of the sections the user has open.
  final _expanded = <String>{};

  /// Whether the recording screen is open above this one.
  bool _recordingOpen = false;

  Session get _session => widget.session;

  /// How far the loaded recording has played, from 0 to 1.
  late final Stream<double> _progress = _session.player.positionStream.map((
    position,
  ) {
    final total = _session.player.duration?.inMilliseconds ?? 0;
    return total == 0 ? 0.0 : (position.inMilliseconds / total).clamp(0.0, 1.0);
  }).asBroadcastStream();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sections = _session.library.scan();
    _probeDurations();
    _session.restore();
    listenForSharedFiles(_importShared);
    _session.addListener(_onSessionChanged);
  }

  /// The open recording's path when the library was last scanned.
  String? _scannedWith;

  void _onSessionChanged() {
    final open = _session.recording?.relPath;
    if (open != _scannedWith) _rescan();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) pipRouteObserver.subscribe(this, route);
  }

  @override
  void didPopNext() => _rescan();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _session.persistPosition();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pipRouteObserver.unsubscribe(this);
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _rescan() {
    if (!mounted) return;
    _scannedWith = _session.recording?.relPath;
    setState(() => _sections = _session.library.scan());
    _probeDurations();
  }

  void _probeDurations() {
    _session.durations.probe([
      for (final section in _sections) ...section.recordings,
    ]);
  }

  /// Opens [recording] in the recording screen, at [hit] with [query] when
  /// given.
  Future<void> _open(
    Recording recording, {
    LibraryHit? hit,
    String query = '',
  }) async {
    if (_session.recording?.relPath != recording.relPath) {
      await _session.open(recording);
    }
    if (!mounted) return;
    await _showRecording(hit: hit, query: query);
  }

  /// Pushes the recording screen for the open recording, unless it is open.
  Future<void> _showRecording({LibraryHit? hit, String query = ''}) async {
    if (_recordingOpen || _session.recording == null) return;
    _recordingOpen = true;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RecordingScreen(
          session: _session,
          pip: widget.pip,
          onLibraryChanged: _rescan,
          hit: hit,
          query: query,
        ),
      ),
    );
    _recordingOpen = false;
  }

  /// Opens [file] when a flow produced it.
  Future<void> _openProduced(File? file) async {
    if (file == null || !mounted) return;
    await _open(_session.library.describe(file));
  }

  Future<void> _importPicked() async {
    final picked = await FilePicker.pickFiles();
    if (!mounted) return;
    await _importFrom([
      for (final f in picked)
        if (f.path != null) (file: File(f.path!), name: f.name),
    ]);
    await FilePicker.clearTemporaryFiles();
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
    await _importFrom([
      for (final f in files) (file: f, name: p.basename(f.path)),
    ]);
    for (final f in files) {
      if (f.parent.existsSync()) f.parent.deleteSync(recursive: true);
    }
  }

  /// Imports [sources], then shows the recording the import opened.
  Future<void> _importFrom(List<actions.ImportSource> sources) async {
    final before = _session.recording?.relPath;
    await actions.importSources(context, _session, sources);
    _rescan();
    final after = _session.recording?.relPath;
    if (mounted && after != null && after != before) await _showRecording();
  }

  Future<void> _search() async {
    final picked = await Navigator.push<PickedHit>(
      context,
      MaterialPageRoute(
        builder: (_) => LibrarySearchScreen(
          rootPath: _session.library.root.path,
          languageOf: _session.languages.resolve,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final file = _session.library.recordingAt(picked.hit.relPath);
    if (file == null) return;
    await _open(
      _session.library.describe(file),
      hit: picked.hit,
      query: picked.query,
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(session: _session),
      ),
    );
  }

  Future<void> _onLibraryAction(LibraryAction action) async {
    switch (action) {
      case LibraryAction.search:
        await _search();
      case LibraryAction.import:
        await _importPicked();
      case LibraryAction.newFolder:
        await actions.createFolder(context, _session);
      case LibraryAction.trash:
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => TrashScreen(library: _session.library),
          ),
        );
      case LibraryAction.settings:
        _openSettings();
    }
    _rescan();
  }

  Future<void> _onFolderAction(
    LibrarySection section,
    FolderAction action,
  ) async {
    final folder = section.folder!;
    switch (action) {
      case FolderAction.summary:
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
        final combined = await combineInFolder(
          context,
          _session,
          folder,
          allIfOneFormat(section),
        );
        _rescan();
        await _openProduced(combined);
      case FolderAction.shareZip:
        await shareFolderZip(context, _session, folder);
      case FolderAction.rename:
        await actions.renameFolder(context, _session, folder);
      case FolderAction.trash:
        await actions.trashFolder(context, _session, folder, _rescan);
    }
    _rescan();
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
      _rescan,
    );
    _rescan();
    await _openProduced(produced);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_session, _session.durations]),
      builder: (context, _) => Scaffold(
        bottomNavigationBar: switch (_session.recording) {
          final recording? => MiniPlayer(
            recording: recording,
            playing: _session.player.playingStream,
            progress: _progress,
            onPlay: _session.player.play,
            onPause: _session.player.pause,
            onOpen: _showRecording,
          ),
          null => null,
        },
        appBar: AppBar(
          title: const Text('Transcripts'),
          actions: [
            IconButton(
              tooltip: 'Search all recordings',
              icon: const Icon(Icons.search),
              onPressed: () => _onLibraryAction(LibraryAction.search),
            ),
            IconButton(
              tooltip: 'Import files',
              icon: const Icon(Icons.add),
              onPressed: () => _onLibraryAction(LibraryAction.import),
            ),
            MenuButton(
              tooltip: 'More options',
              groups: [
                [
                  menuEntry(
                    Icons.create_new_folder_outlined,
                    'New folder',
                    () => _onLibraryAction(LibraryAction.newFolder),
                  ),
                ],
                [
                  menuEntry(
                    Icons.delete_outline,
                    'Trash',
                    () => _onLibraryAction(LibraryAction.trash),
                  ),
                  menuEntry(
                    Icons.settings_outlined,
                    'Settings',
                    () => _onLibraryAction(LibraryAction.settings),
                  ),
                ],
              ],
            ),
          ],
        ),
        body: _sections.isEmpty
            ? EmptyLibrary(
                onImport: () => _onLibraryAction(LibraryAction.import),
              )
            : LibraryList(
                sections: _sections,
                selected: _session.recording?.relPath,
                expanded: _expanded,
                durationOf: _session.durations.of,
                isBusy: (r) => _session.recordingBusy(r.relPath),
                onSelect: _open,
                onFolderAction: _onFolderAction,
                onRecordingAction: _onRecordingAction,
              ),
      ),
    );
  }
}

/// What the library shows with no recordings in it.
class EmptyLibrary extends StatelessWidget {
  const EmptyLibrary({super.key, required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: .min,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('No recordings yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Import audio or video files, or share them into the app from '
              'another one.',
              textAlign: .center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.add),
              label: const Text('Import files'),
            ),
          ],
        ),
      ),
    );
  }
}
