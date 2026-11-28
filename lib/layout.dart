import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Widest a single column of controls gets. On a phone the content fills
/// the screen; on a tablet, a foldable's inner screen, a desktop window or a
/// phone in landscape it is centred, so steppers, cards and buttons don't
/// stretch edge to edge.
const double kContentMaxWidth = 720;

/// For screens that gain from more width: the profile editor's chart and
/// the two side-by-side Dual record cards.
const double kWideContentMaxWidth = 960;

/// Padding for a scroll view that fills a page body: [base] plus enough
/// side padding to centre the content at [maxWidth], plus the system insets
/// (display cutout, side navigation bar in landscape, gesture bar) that a
/// scroll view with explicit padding would otherwise ignore. The padding is
/// on the scroll view, not around it, so the gutters still scroll.
///
/// [width] is the scroll view's own width (from a [LayoutBuilder]).
EdgeInsets readablePadding(
  BuildContext context,
  double width, {
  EdgeInsets base = const EdgeInsets.all(16),
  double maxWidth = kContentMaxWidth,
}) {
  final insets = MediaQuery.paddingOf(context);
  final gutter = math.max(0.0, (width - maxWidth) / 2);
  return EdgeInsets.fromLTRB(
    math.max(base.left + insets.left, gutter),
    base.top,
    math.max(base.right + insets.right, gutter),
    base.bottom + insets.bottom,
  );
}

/// Centres [child] and caps its width at [maxWidth]: for content that is
/// not a scroll view, such as the bar pinned to the bottom of a screen.
class ReadableWidth extends StatelessWidget {
  const ReadableWidth({
    super.key,
    this.maxWidth = kContentMaxWidth,
    required this.child,
  });

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
