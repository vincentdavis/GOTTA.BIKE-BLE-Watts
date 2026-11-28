import 'package:flutter/widgets.dart';

/// Widest a screen's content column gets. Phones are narrower than this, so
/// they are unchanged; on an iPad, a Mac window or a desktop window the
/// column is centred instead of stretching edge to edge.
const double kMaxContentWidth = 720;

/// Padding for a scrollable screen body: at least [base] on every side, and
/// on a wide window extra horizontal padding so the content is at most
/// [maxWidth] wide and centred. Padding (rather than a centred box) keeps the
/// scrollbar at the window edge and works for every scroll view.
EdgeInsets contentPadding(
  BuildContext context,
  EdgeInsets base, {
  double maxWidth = kMaxContentWidth,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final extra = (width - maxWidth - base.horizontal) / 2;
  if (extra <= 0) return base;
  return base.copyWith(left: base.left + extra, right: base.right + extra);
}

/// Centres [child] and caps its width at [maxWidth]; for fixed (non-scroll)
/// parts such as the bottom bar.
class ContentWidth extends StatelessWidget {
  const ContentWidth({
    super.key,
    required this.child,
    this.maxWidth = kMaxContentWidth,
  });

  final Widget child;
  final double maxWidth;

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
