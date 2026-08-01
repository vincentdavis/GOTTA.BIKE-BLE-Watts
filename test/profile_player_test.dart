import 'package:cps_emulator/power_profile.dart';
import 'package:cps_emulator/profile_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  // Widget tests throw on any RenderFlex overflow or paint exception, so these
  // pumps verify the profile UI (including the CustomPaint chart) lays out and
  // renders cleanly in both idle and running states.
  testWidgets('renders idle state without overflow', (tester) async {
    await tester.pumpWidget(
      _host(
        ProfilePlayerView(
          profile: kCdaCrrMassProfile,
          running: false,
          elapsedSec: 0,
          canRun: true,
          onRun: () {},
          onStop: () {},
        ),
      ),
    );

    expect(find.text(kCdaCrrMassProfile.name), findsOneWidget);
    expect(find.text('Run profile'), findsOneWidget);
    expect(find.text('Segments'), findsOneWidget);
    // Every segment label is listed.
    for (final seg in kCdaCrrMassProfile.segments) {
      expect(find.text(seg.label), findsWidgets);
    }
    expect(find.byType(ProfileChart), findsOneWidget);
  });

  testWidgets('renders running state with progress + playhead', (tester) async {
    await tester.pumpWidget(
      _host(
        ProfilePlayerView(
          profile: kCdaCrrMassProfile,
          running: true,
          elapsedSec: 250,
          canRun: true,
          onRun: () {},
          onStop: () {},
        ),
      ),
    );

    expect(find.text('Stop profile'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // Total duration is 10:00; elapsed clock is shown as "m:ss / 10:00".
    expect(find.textContaining('/ 10:00'), findsOneWidget);
  });

  testWidgets('Run is disabled until advertising (canRun=false)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ProfilePlayerView(
          profile: kCdaCrrMassProfile,
          running: false,
          elapsedSec: 0,
          canRun: false,
          onRun: () {},
          onStop: () {},
        ),
      ),
    );

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Run profile'),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('Start advertising'), findsOneWidget);
  });
}
