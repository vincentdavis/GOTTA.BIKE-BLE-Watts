import 'package:flutter/material.dart';

import 'power_profile.dart';

/// Formats seconds as "m:ss".
String formatClock(num seconds) {
  final s = seconds.round();
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r.toString().padLeft(2, '0')}';
}

/// The profile-player section: a power-vs-time chart with a live playhead,
/// progress, a Run/Stop control, and a segment list. Stateless — playback state
/// is owned by the host page and passed in, so it updates live via setState.
class ProfilePlayerView extends StatelessWidget {
  const ProfilePlayerView({
    super.key,
    required this.profile,
    required this.running,
    required this.elapsedSec,
    required this.canRun,
    required this.onRun,
    required this.onStop,
  });

  final PowerProfile profile;
  final bool running;
  final double elapsedSec;

  /// Whether "Run profile" is allowed (i.e. advertising is on).
  final bool canRun;
  final VoidCallback onRun;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = profile.totalSec;
    final activeIndex = running ? profile.activeIndexAt(elapsedSec) : -1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(profile.name, style: theme.textTheme.titleMedium),
        const SizedBox(height: 2),
        Text(
          '${formatClock(total)} · ${profile.segments.length} segments',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        Text(profile.description, style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ProfileChart(
                  profile: profile,
                  elapsedSec: running ? elapsedSec : null,
                ),
                if (running) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: total == 0
                          ? 0
                          : (elapsedSec / total).clamp(0.0, 1.0),
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${formatClock(elapsedSec)} / ${formatClock(total)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Flexible(
                        child: Text(
                          'Step ${activeIndex + 1}/${profile.segments.length} · '
                          '${profile.segments[activeIndex].label}',
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (running)
          FilledButton.icon(
            onPressed: onStop,
            icon: const Icon(Icons.stop),
            label: const Text('Stop profile'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              backgroundColor: Colors.red.shade700,
            ),
          )
        else
          FilledButton.icon(
            onPressed: canRun ? onRun : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run profile'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        if (!canRun && !running) ...[
          const SizedBox(height: 6),
          Text(
            'Start advertising and connect Zwift first, then run the profile.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 16),
        Text('Segments', style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        for (var i = 0; i < profile.segments.length; i++)
          _SegmentRow(
            index: i,
            segment: profile.segments[i],
            startSec: profile.startOf(i),
            active: i == activeIndex,
          ),
      ],
    );
  }
}

class _SegmentRow extends StatelessWidget {
  const _SegmentRow({
    required this.index,
    required this.segment,
    required this.startSec,
    required this.active,
  });

  final int index;
  final ProfileSegment segment;
  final int startSec;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final range =
        '${formatClock(startSec)}–${formatClock(startSec + segment.durationSec)}';
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: active ? Border.all(color: scheme.primary, width: 1.5) : null,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              range,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Text(
              segment.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Text(
            '${segment.powerLabel}${segment.isCoast ? '' : ' · ${segment.cadence} rpm'}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// A power-vs-time chart of a [PowerProfile]. When [elapsedSec] is non-null a
/// playhead is drawn and the elapsed portion is highlighted.
class ProfileChart extends StatelessWidget {
  const ProfileChart({
    super.key,
    required this.profile,
    this.elapsedSec,
    this.height = 150,
  });

  final PowerProfile profile;
  final double? elapsedSec;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _ProfilePainter(
          profile: profile,
          elapsedSec: elapsedSec,
          lineColor: scheme.primary,
          fillColor: scheme.primary.withValues(alpha: 0.14),
          playedColor: scheme.primary.withValues(alpha: 0.34),
          playheadColor: scheme.secondary,
          gridColor: scheme.onSurface.withValues(alpha: 0.12),
          labelColor: scheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

class _ProfilePainter extends CustomPainter {
  _ProfilePainter({
    required this.profile,
    required this.elapsedSec,
    required this.lineColor,
    required this.fillColor,
    required this.playedColor,
    required this.playheadColor,
    required this.gridColor,
    required this.labelColor,
  });

  final PowerProfile profile;
  final double? elapsedSec;
  final Color lineColor;
  final Color fillColor;
  final Color playedColor;
  final Color playheadColor;
  final Color gridColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    final total = profile.totalSec;
    if (total <= 0 || profile.segments.isEmpty) return;

    const leftPad = 36.0, rightPad = 8.0, topPad = 8.0, bottomPad = 18.0;
    final plot = Rect.fromLTRB(
      leftPad,
      topPad,
      size.width - rightPad,
      size.height - bottomPad,
    );
    final maxP = _niceMax(profile.maxPower);

    double xAt(num t) => plot.left + (t / total) * plot.width;
    double yAt(num p) => plot.bottom - (p / maxP) * plot.height;

    // Horizontal gridlines + Y labels at 0, mid, max.
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final p in [0.0, maxP / 2, maxP]) {
      final y = yAt(p);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _text(
        canvas,
        '${p.round()}',
        Offset(plot.left - 4, y),
        color: labelColor,
        alignRight: true,
        vCenter: true,
      );
    }

    // Faint vertical segment boundaries.
    var tb = 0.0;
    for (final s in profile.segments) {
      tb += s.durationSec;
      if (tb < total) {
        final x = xAt(tb);
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      }
    }

    // Build the profile outline (holds = flat, ramps = sloped, steps at joins).
    final pts = <Offset>[];
    var t = 0.0;
    for (final s in profile.segments) {
      pts.add(Offset(xAt(t), yAt(s.startPower)));
      t += s.durationSec;
      pts.add(Offset(xAt(t), yAt(s.endPower)));
    }

    Path areaTo(List<Offset> p) {
      final path = Path()..moveTo(p.first.dx, plot.bottom);
      for (final o in p) {
        path.lineTo(o.dx, o.dy);
      }
      path
        ..lineTo(p.last.dx, plot.bottom)
        ..close();
      return path;
    }

    // Base fill.
    canvas.drawPath(areaTo(pts), Paint()..color = fillColor);

    // Elapsed highlight (clip to left of playhead).
    if (elapsedSec != null) {
      final px = xAt(elapsedSec!.clamp(0.0, total.toDouble()));
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(plot.left, plot.top - 6, px, plot.bottom));
      canvas.drawPath(areaTo(pts), Paint()..color = playedColor);
      canvas.restore();
    }

    // Outline stroke.
    final line = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final o in pts.skip(1)) {
      line.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );

    // Playhead.
    if (elapsedSec != null) {
      final px = xAt(elapsedSec!.clamp(0.0, total.toDouble()));
      canvas.drawLine(
        Offset(px, plot.top - 6),
        Offset(px, plot.bottom),
        Paint()
          ..color = playheadColor
          ..strokeWidth = 2,
      );
    }

    // X time labels: 0, mid, total.
    for (final frac in [0.0, 0.5, 1.0]) {
      final tt = total * frac;
      _text(
        canvas,
        formatClock(tt),
        Offset(xAt(tt), plot.bottom + 4),
        color: labelColor,
        hCenter: frac == 0.5,
        alignRight: frac == 1.0,
      );
    }
  }

  double _niceMax(int maxPower) {
    if (maxPower <= 0) return 100;
    const step = 50;
    return ((maxPower / step).ceil() * step).toDouble();
  }

  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    required Color color,
    bool alignRight = false,
    bool hCenter = false,
    bool vCenter = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = at.dx;
    if (alignRight) dx -= tp.width;
    if (hCenter) dx -= tp.width / 2;
    var dy = at.dy;
    if (vCenter) dy -= tp.height / 2;
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _ProfilePainter old) =>
      old.elapsedSec != elapsedSec ||
      old.profile != profile ||
      old.lineColor != lineColor;
}
