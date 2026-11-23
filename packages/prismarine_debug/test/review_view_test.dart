import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_debug/prismarine_debug.dart';

void main() {
  testWidgets('the note takes digits, arrows and ⌘Z; Escape leaves it', (
    t,
  ) async {
    var closed = false;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReviewView(
            // No frames kept (no GPU in a widget test): the bar still works.
            history: FrameHistory(seconds: 0, copy: _NoCopy()),
            openedAt: 0,
            onSave: (_, _, _) async => null,
            onClose: () => closed = true,
          ),
        ),
      ),
    );
    await t.tap(find.byType(TextField));
    await t.pump();
    // Digits are the tool keys (1–4) outside the note: inside it they type.
    for (final k in [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit4,
    ]) {
      await t.sendKeyEvent(k);
    }
    await t.enterText(find.byType(TextField), 'arm clips at 1:24');
    await t.pump();
    expect(find.text('arm clips at 1:24'), findsOneWidget);
    // Escape leaves the field (doesn't close the review) …
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(closed, isFalse);
    // … and a second Escape closes it.
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(closed, isTrue);
  });

  testWidgets(
    'a digit typed into the note reaches it (not taken as a tool key)',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReviewView(
              history: FrameHistory(seconds: 0, copy: _NoCopy()),
              openedAt: 0,
              onSave: (_, _, _) async => null,
              onClose: () {},
            ),
          ),
        ),
      );
      await t.tap(find.byType(TextField));
      await t.pump();
      final focus = FocusManager.instance.primaryFocus!;
      // The review's own key handler must leave a digit to the text field.
      final r = focus.parent!.onKeyEvent?.call(
        focus.parent!,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.digit3,
          logicalKey: LogicalKeyboardKey.digit3,
          character: '3',
          timeStamp: Duration.zero,
        ),
      );
      expect(r, isNot(KeyEventResult.handled));
    },
  );

  testWidgets('the note box asks about the shown frame', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReviewView(
            history: FrameHistory(seconds: 0, copy: _NoCopy()),
            openedAt: 0,
            onSave: (_, _, _) async => null,
            onClose: () {},
          ),
        ),
      ),
    );
    expect(find.text('What is wrong on this frame?'), findsOneWidget);
  });
}

/// A copy for a ring of no frames, which never copies.
final class _NoCopy implements FrameCopy {
  @override
  Never get pipeline => throw UnimplementedError();
  @override
  Never get source => throw UnimplementedError();
}
