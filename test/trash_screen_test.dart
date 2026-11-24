import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:transcripts/library.dart';
import 'package:transcripts/trash.dart';
import 'package:transcripts/trash_screen.dart';

void main() {
  late Directory root;
  late Library library;

  setUp(() {
    root = Directory.systemTemp.createTempSync('trash_screen_test');
    library = Library(root);
    final trash = Trash(library);
    for (final name in ['alpha', 'beta', 'gamma']) {
      trash.trashRecording(
        File(p.join(root.path, '$name.mp3'))..writeAsStringSync(name),
      );
    }
  });

  tearDown(() => root.deleteSync(recursive: true));

  bool exists(String name) => File(p.join(root.path, name)).existsSync();

  Future<void> show(WidgetTester tester) =>
      tester.pumpWidget(MaterialApp(home: TrashScreen(library: library)));

  testWidgets('selected items are restored together', (tester) async {
    await show(tester);
    await tester.longPress(find.text('alpha'));
    await tester.pump();
    await tester.tap(find.text('beta'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Restore'));
    await tester.pump();
    expect(exists('alpha.mp3') && exists('beta.mp3'), isTrue);
    expect(exists('gamma.mp3'), isFalse);
    expect(find.text('gamma'), findsOneWidget);
    expect(find.text('Trash'), findsOneWidget);
  });

  testWidgets('select all deletes everything after asking', (tester) async {
    await show(tester);
    await tester.longPress(find.text('gamma'));
    await tester.pump();
    await tester.tap(find.byTooltip('Select all'));
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete permanently'));
    await tester.pumpAndSettle();
    expect(find.text('Permanently delete 3 items?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(Trash(library).items(), isEmpty);
    expect(find.text('Trash is empty'), findsOneWidget);
  });
}
