import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:transcripts/swipe_back.dart';

void main() {
  testWidgets('dragging right past the first tab swipes back once', (
    tester,
  ) async {
    var back = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: 2,
          child: Scaffold(
            body: SwipeBack(
              onSwipeBack: () => back++,
              child: const TabBarView(
                children: [
                  Center(child: Text('one')),
                  Center(child: Text('two')),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.text('one'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('two'), findsOneWidget);
    expect(back, 0);

    await tester.drag(find.text('two'), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(back, 0);

    await tester.drag(find.text('one'), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(back, 1);
  });
}
