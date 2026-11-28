import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../models/models.dart';

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 44, this.color, this.icon});
  final String name;
  final double size;
  final Color? color;
  final IconData? icon;

  // Muted, warm tones that sit on the ink background without shouting.
  static const _palette = [
    Color(0xFFE59A6B), Color(0xFF8FB8F2), Color(0xFF6FD3BC), Color(0xFFF2B544),
    Color(0xFFE48BB0), Color(0xFFB9A0F0), Color(0xFF9CCF7A), Color(0xFFF0806B),
  ];

  @override
  Widget build(BuildContext context) {
    final c = color ?? _palette[name.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Color.alphaBlend(c.withValues(alpha: .16), AppColors.surface),
        border: Border.all(color: c.withValues(alpha: .38), width: size > 60 ? 1.6 : 1),
      ),
      child: icon != null
          ? Icon(icon, color: c, size: size * .46)
          : Text(initials(name), style: AppType.display(size * .38, weight: FontWeight.w600, color: c, height: 1)),
    );
  }
}

/// Personal ⇄ Work. A sliding saffron / sea-glass thumb; the whole app re-tints with it.
class ModeSwitch extends StatelessWidget {
  const ModeSwitch({super.key, required this.mode, required this.onChanged, this.busy = false});
  final AppMode mode;
  final ValueChanged<AppMode> onChanged;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final work = mode == AppMode.corporate;
    final active = work ? ModePalette.corporate : ModePalette.personal;
    const w = 188.0;
    return Container(
      width: w,
      height: 42,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: .8),
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: AppColors.outline),
      ),
      child: Stack(children: [
        AnimatedAlign(
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutBack,
          alignment: work ? Alignment.centerRight : Alignment.centerLeft,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 380),
            width: w / 2 - 4,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              gradient: LinearGradient(colors: active.gradient, begin: Alignment.topLeft, end: Alignment.bottomRight),
              boxShadow: [BoxShadow(color: active.accent.withValues(alpha: .35), blurRadius: 16, offset: const Offset(0, 4))],
            ),
          ),
        ),
        Row(children: [
          _seg(AppMode.personal, ModePalette.personal, !work),
          _seg(AppMode.corporate, ModePalette.corporate, work),
        ]),
      ]),
    );
  }

  Widget _seg(AppMode m, ModePalette p, bool selected) => Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: '${p.name} mode',
          child: InkWell(
            borderRadius: BorderRadius.circular(17),
            onTap: busy || selected ? null : () => onChanged(m),
            child: Center(
              child: busy && !selected
                  ? SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: p.accent))
                  : AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 250),
                      style: GoogleFonts.manrope(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .2,
                          color: selected ? p.onAccent : AppColors.textFaint),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(p.icon, size: 15, color: selected ? p.onAccent : AppColors.textFaint),
                        const SizedBox(width: 6),
                        Text(p.name),
                      ]),
                    ),
            ),
          ),
        ),
      );
}

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, required this.color, this.icon, this.dense = false});
  final String label;
  final Color color;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 10, vertical: dense ? 3 : 5),
        decoration: BoxDecoration(color: color.withValues(alpha: .14), borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: dense ? 11 : 13, color: color), const SizedBox(width: 4)],
          Text(label, style: TextStyle(color: color, fontSize: dense ? 11 : 12, fontWeight: FontWeight.w700)),
        ]),
      );
}

({String label, Color color, IconData icon}) statusStyle(Commitment c) {
  if (c.status == CommitmentStatus.pendingReview) return (label: 'Review', color: AppColors.info, icon: Icons.fact_check_rounded);
  if (c.isOverdue) return (label: 'Overdue', color: AppColors.danger, icon: Icons.error_rounded);
  return switch (c.status) {
    CommitmentStatus.open => (label: 'Open', color: AppColors.warning, icon: Icons.radio_button_unchecked_rounded),
    CommitmentStatus.inProgress => (label: 'In progress', color: const Color(0xFFA78BFA), icon: Icons.timelapse_rounded),
    CommitmentStatus.fulfilled => (label: 'Kept', color: AppColors.success, icon: Icons.check_circle_rounded),
    CommitmentStatus.disputed => (label: 'Disputed', color: const Color(0xFFF472B6), icon: Icons.gavel_rounded),
    CommitmentStatus.cancelled => (label: 'Cancelled', color: AppColors.textFaint, icon: Icons.block_rounded),
    _ => (label: 'Missed', color: AppColors.danger, icon: Icons.error_rounded),
  };
}

IconData categoryIcon(String category) => switch (category) {
      'deliverable' => Icons.inventory_2_rounded,
      'follow_up' => Icons.phone_callback_rounded,
      'pricing' => Icons.sell_rounded,
      'meeting' => Icons.event_rounded,
      'information' => Icons.info_rounded,
      'support' => Icons.build_rounded,
      _ => Icons.handshake_rounded,
    };

String categoryLabel(String category) => switch (category) {
      'deliverable' => 'Deliverable',
      'follow_up' => 'Follow-up',
      'pricing' => 'Pricing',
      'meeting' => 'Meeting',
      'information' => 'Information',
      'support' => 'Support',
      _ => 'Other',
    };

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(20, 28, 20, 12)});
  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(children: [
          Container(width: 14, height: 1.5, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
          const Spacer(),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Big serif page title with an optional small-caps kicker above it.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.kicker, this.trailing, this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 0)});
  final String title;
  final String? kicker;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (kicker != null) ...[
                Text(kicker!.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
                const SizedBox(height: 6),
              ],
              Text(title, style: AppType.display(28, weight: FontWeight.w600)),
            ]),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

/// A tab's heading: one size everywhere, with room for an action on the right.
class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
        child: Row(children: [
          Expanded(child: Text(title, style: AppType.display(28, weight: FontWeight.w600))),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Ambient, mode-tinted light behind a screen.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.palette, required this.child});
  final ModePalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(children: [
        const Positioned.fill(child: ColoredBox(color: AppColors.bg)),
        Positioned(
          top: -220,
          right: -160,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 600),
            width: 520,
            height: 520,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [palette.glow.withValues(alpha: .28), palette.glow.withValues(alpha: 0)]),
            ),
          ),
        ),
        Positioned(
          bottom: -260,
          left: -200,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 600),
            width: 480,
            height: 480,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [palette.glow.withValues(alpha: .10), palette.glow.withValues(alpha: 0)]),
            ),
          ),
        ),
        Positioned.fill(child: child),
      ]);
}

class DockItem {
  const DockItem(this.label, this.icon, this.selectedIcon, {this.badge = 0});
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final int badge;
}

/// Floating pill navigation. The selected tab expands to show its label.
class Dock extends StatelessWidget {
  const Dock({super.key, required this.items, required this.index, required this.onSelect});
  final List<DockItem> items;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final onAccent = Theme.of(context).colorScheme.onPrimary;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 12),
      child: Center(
        heightFactor: 1,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: .96),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: AppColors.outline),
            boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 30, offset: Offset(0, 12))],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < items.length; i++)
              Semantics(
                button: true,
                selected: i == index,
                label: items[i].label,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    height: 48,
                    padding: EdgeInsets.symmetric(horizontal: i == index ? 18 : 14),
                    decoration: BoxDecoration(
                      color: i == index ? accent : Colors.transparent,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Badge(
                        isLabelVisible: items[i].badge > 0 && i != index,
                        backgroundColor: AppColors.danger,
                        smallSize: 8,
                        child: Icon(i == index ? items[i].selectedIcon : items[i].icon,
                            size: 22, color: i == index ? onAccent : AppColors.textDim),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOutCubic,
                        child: i == index
                            ? Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Text(items[i].label,
                                    style: GoogleFonts.manrope(fontSize: 14, fontWeight: FontWeight.w800, color: onAccent)),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Concentric "ripple" rings around an icon: the empty-state illustration.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  static const _rings = [(168.0, .05), (124.0, .09), (84.0, .16)];

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 168,
          height: 168,
          child: Stack(alignment: Alignment.center, children: [
            for (final (size, alpha) in _rings)
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: accent.withValues(alpha: alpha * 2.2)),
                  color: accent.withValues(alpha: alpha * .5),
                ),
              ),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                    colors: [accent, Color.lerp(accent, Colors.white, .3)!], begin: Alignment.topLeft, end: Alignment.bottomRight),
                boxShadow: [BoxShadow(color: accent.withValues(alpha: .4), blurRadius: 24)],
              ),
              child: Icon(icon, color: Theme.of(context).colorScheme.onPrimary, size: 26),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        Text(title, style: AppType.display(24, weight: FontWeight.w500), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Text(body, style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
        ),
        if (action != null) ...[const SizedBox(height: 22), action!],
      ]),
    );
  }
}

/// A small pulsing red dot with a soft halo: "this is on the record".
class RecordingDot extends StatefulWidget {
  const RecordingDot({super.key, this.size = 8});
  final double size;

  @override
  State<RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<RecordingDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size * 2.2,
        height: widget.size * 2.2,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => Stack(alignment: Alignment.center, children: [
            Container(
              width: widget.size * (1 + 1.2 * _c.value),
              height: widget.size * (1 + 1.2 * _c.value),
              decoration: BoxDecoration(
                  shape: BoxShape.circle, color: AppColors.recording.withValues(alpha: .35 * (1 - _c.value))),
            ),
            Container(
              width: widget.size,
              height: widget.size,
              decoration: const BoxDecoration(color: AppColors.recording, shape: BoxShape.circle),
            ),
          ]),
        ),
      );
}

/// Pulsing red dot + label. (The pulse lives in [RecordingDot].)
class RecordingBadge extends StatelessWidget {
  const RecordingBadge({super.key, this.label = 'Recording · Commit Call is listening'});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(color: AppColors.recording.withValues(alpha: .12), borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const RecordingDot(size: 7),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: AppColors.recording, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      );
}

/// Circular score (0–100), e.g. reliability.
class ScoreRing extends StatelessWidget {
  const ScoreRing({super.key, required this.value, this.size = 46, this.stroke = 5, this.label});
  final int? value;
  final double size;
  final double stroke;
  final String? label;

  static Color colorFor(int? v) => v == null
      ? AppColors.textFaint
      : v >= 85
          ? AppColors.success
          : v >= 65
              ? AppColors.warning
              : AppColors.danger;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter((value ?? 0) / 100, colorFor(value), stroke),
          child: Center(
            child: Text(label ?? (value == null ? '–' : '$value'),
                style: AppType.display(size * .32, weight: FontWeight.w600)),
          ),
        ),
      );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.t, this.color, this.stroke);
  final double t;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    canvas.drawArc(r, 0, math.pi * 2, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = AppColors.outline);
    canvas.drawArc(r, -math.pi / 2, math.pi * 2 * t.clamp(0.0, 1.0), false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke
      ..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.t != t || old.color != color;
}

/// Weekly made / kept / missed chart: bars for kept vs missed, a line for made.
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.points, required this.accent});
  final List<WeekPoint> points;
  final Color accent;

  @override
  Widget build(BuildContext context) => Column(children: [
        SizedBox(height: 150, child: CustomPaint(size: Size.infinite, painter: _TrendPainter(points, accent))),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _legend(AppColors.success, 'Kept'),
          const SizedBox(width: 16),
          _legend(AppColors.danger, 'Missed'),
          const SizedBox(width: 16),
          _legend(accent, 'Made', line: true),
        ]),
      ]);

  Widget _legend(Color c, String label, {bool line = false}) => Row(children: [
        Container(width: line ? 14 : 9, height: line ? 3 : 9, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
      ]);
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.points, this.accent);
  final List<WeekPoint> points;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    const bottomPad = 18.0;
    final h = size.height - bottomPad;
    final maxV = points.fold<int>(1, (m, p) => math.max(m, math.max(p.made, p.kept + p.missed))).toDouble();
    final slot = size.width / points.length;
    final grid = Paint()..color = AppColors.outline..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = h - h * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final label = TextPainter(textDirection: TextDirection.ltr);
    final linePts = <Offset>[];
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final x = slot * i + slot / 2;
      final bw = math.min(18.0, slot * .45);
      final keptH = h * p.kept / maxV;
      final missH = h * p.missed / maxV;
      final rr = RRect.fromRectAndCorners(Rect.fromLTWH(x - bw / 2, h - keptH, bw, keptH), topLeft: const Radius.circular(4), topRight: const Radius.circular(4));
      canvas.drawRRect(rr, Paint()..color = AppColors.success.withValues(alpha: .85));
      if (p.missed > 0) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(Rect.fromLTWH(x - bw / 2, h - keptH - missH - 2, bw, missH),
              topLeft: const Radius.circular(4), topRight: const Radius.circular(4)),
          Paint()..color = AppColors.danger.withValues(alpha: .85),
        );
      }
      linePts.add(Offset(x, h - h * p.made / maxV));
      if (i.isEven || i == points.length - 1) {
        label.text = TextSpan(text: '${p.weekStart.day}/${p.weekStart.month}', style: const TextStyle(fontSize: 10, color: AppColors.textFaint));
        label.layout();
        label.paint(canvas, Offset(x - label.width / 2, h + 4));
      }
    }
    final path = Path()..moveTo(linePts.first.dx, linePts.first.dy);
    for (var i = 1; i < linePts.length; i++) {
      final a = linePts[i - 1], b = linePts[i];
      final mid = (a.dx + b.dx) / 2;
      path.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = accent);
    for (final o in linePts) {
      canvas.drawCircle(o, 3.5, Paint()..color = AppColors.bg);
      canvas.drawCircle(o, 2.5, Paint()..color = accent);
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.points != points;
}

void toast(BuildContext context, String message, {IconData? icon}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [
        if (icon != null) ...[Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary), const SizedBox(width: 10)],
        Expanded(child: Text(message)),
      ]),
    ));
}
