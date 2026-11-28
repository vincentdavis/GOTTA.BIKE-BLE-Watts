import 'package:cps_emulator/recording_files.dart';
import 'package:cps_emulator/responsive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<EdgeInsets> paddingAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late EdgeInsets padding;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          padding = contentPadding(context, const EdgeInsets.all(16));
          return const SizedBox();
        },
      ),
    );
    return padding;
  }

  testWidgets('phones keep the base padding', (tester) async {
    expect(await paddingAt(tester, 390), const EdgeInsets.all(16));
    // Exactly the cap plus the base padding: still no extra.
    expect(
      await paddingAt(tester, kMaxContentWidth + 32),
      const EdgeInsets.all(16),
    );
  });

  testWidgets('wide windows centre a column of kMaxContentWidth', (
    tester,
  ) async {
    final p = await paddingAt(tester, 1366); // iPad Pro 12.9" landscape
    expect(p.top, 16);
    expect(p.bottom, 16);
    expect(p.left, p.right);
    expect(1366 - p.horizontal, kMaxContentWidth);
  });

  testWidgets('ContentWidth caps and centres its child', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const box = Key('box');
    await tester.pumpWidget(
      const Align(
        alignment: Alignment.topLeft,
        child: ContentWidth(
          child: SizedBox(key: box, height: 10, width: double.infinity),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(box)).width, kMaxContentWidth);
    expect(
      tester.getTopLeft(find.byKey(box)).dx,
      (1200 - kMaxContentWidth) / 2,
    );
  });

  test('"Save as" is offered on desktops only', () {
    const files = RecordingFiles();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final p in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = p;
      expect(
        files.canSaveAs,
        p == TargetPlatform.macOS ||
            p == TargetPlatform.windows ||
            p == TargetPlatform.linux,
        reason: '$p',
      );
    }
  });
}
