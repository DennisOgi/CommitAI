import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../call/call_controller.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import 'post_call_review_screen.dart';

class InCallScreen extends StatefulWidget {
  const InCallScreen({super.key});

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> with SingleTickerProviderStateMixin {
  late final CallController calls;
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    calls = AppScope.read(context).calls!;
    calls.addListener(_onCall);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCall()); // in case it ended before we listened
  }

  void _onCall() {
    if (calls.phase != CallPhase.ended || _closing) return;
    _closing = true;
    final flagged = List<String>.of(calls.flagged);
    final app = AppScope.read(context);
    // Linger a little longer when there's an error, so the reason can be read.
    Timer(Duration(milliseconds: calls.error != null ? 2500 : 900), () {
      if (!mounted) return;
      final review = calls.reviewReady.value;
      calls.reviewReady.value = null;
      final peer = calls.peerName;
      calls.dismiss();
      app.refresh();
      final messenger = ScaffoldMessenger.maybeOf(context);
      final nav = Navigator.of(context);
      nav.pop();
      if (review != null) {
        messenger?.showSnackBar(SnackBar(
          duration: const Duration(seconds: 8),
          content: Text('Pulling the commitments out of your call with $peer…'),
          action: SnackBarAction(
            label: 'Review',
            onPressed: () => nav.push(MaterialPageRoute(builder: (_) => PostCallReviewScreen(callId: review, flagged: flagged))),
          ),
        ));
      }
    });
  }

  @override
  void dispose() {
    calls.removeListener(_onCall);
    _pulse.dispose();
    super.dispose();
  }

  String _status() => switch (calls.phase) {
        CallPhase.idle || CallPhase.connecting => 'Connecting…',
        CallPhase.ringing => 'Ringing…',
        CallPhase.active => duration(calls.elapsed),
        CallPhase.ended => calls.error ?? 'Call ended',
      };

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = calls.call?.mode == AppMode.corporate ? ModePalette.corporate : calls.call == null ? app.palette : ModePalette.personal;
    return PopScope(
      canPop: !calls.busy,
      child: ListenableBuilder(
        listenable: calls,
        builder: (context, _) {
          final active = calls.phase == CallPhase.active;
          return Scaffold(
            body: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -.55),
                  radius: 1.1,
                  colors: [p.accent.withValues(alpha: .28), AppColors.bg],
                ),
              ),
              child: SafeArea(
                child: Column(children: [
                  const SizedBox(height: 12),
                  calls.recorded
                      ? RecordingBadge(
                          label: calls.call?.mode == AppMode.personal
                              ? 'Personal · recorded temporarily for commitments'
                              : 'Recording · Commit AI is listening')
                      : const Pill('Personal · not recorded', color: AppColors.textDim, icon: Icons.lock_rounded),
                  const SizedBox(height: 28),
                  _PulsingAvatar(name: calls.peerName, animation: _pulse, pulsing: !active && calls.phase != CallPhase.ended, accent: p.accent),
                  const SizedBox(height: 18),
                  Text(calls.peerName.isEmpty ? 'Calling' : calls.peerName,
                      style: AppType.display(34, weight: FontWeight.w500)),
                  if (calls.peerDetail.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(calls.peerDetail, style: const TextStyle(fontSize: 15, color: AppColors.textDim)),
                    ),
                  const SizedBox(height: 8),
                  Text(_status(),
                      style: TextStyle(
                        fontSize: 16,
                        color: calls.phase == CallPhase.ended && calls.error != null ? AppColors.danger : AppColors.textDim,
                        fontWeight: calls.phase == CallPhase.active ? FontWeight.w700 : FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )),
                  const SizedBox(height: 18),
                  Expanded(child: calls.recorded ? _LivePanel(calls: calls, accent: p.accent) : const SizedBox()),
                  _Controls(calls: calls, accent: p.accent),
                  const SizedBox(height: 28),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PulsingAvatar extends StatelessWidget {
  const _PulsingAvatar({required this.name, required this.animation, required this.pulsing, required this.accent});
  final String name;
  final Animation<double> animation;
  final bool pulsing;
  final Color accent;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 170,
        height: 130,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, child) => CustomPaint(
            painter: pulsing ? _PulsePainter(animation.value, accent) : null,
            child: child,
          ),
          child: Center(child: Avatar(name: name.isEmpty ? '?' : name, size: 104)),
        ),
      );
}

class _PulsePainter extends CustomPainter {
  _PulsePainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1;
      canvas.drawCircle(c, 52 + phase * 34, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: (1 - phase) * .45));
    }
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.t != t;
}

/// Live captions + "commitment detected" cards sent by the bot.
class _LivePanel extends StatelessWidget {
  const _LivePanel({required this.calls, required this.accent});
  final CallController calls;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final hints = calls.hints;
    final captions = calls.captions.length > 2 ? calls.captions.sublist(calls.captions.length - 2) : calls.captions;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(children: [
        if (calls.phase == CallPhase.active && calls.disclosure != null && calls.elapsed.inSeconds < 6)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.surface.withValues(alpha: .7), borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              const Icon(Icons.campaign_rounded, size: 18, color: AppColors.textDim),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Announced to both sides: “${calls.disclosure}”',
                    style: const TextStyle(fontSize: 12, color: AppColors.textDim, fontStyle: FontStyle.italic)),
              ),
            ]),
          ),
        Expanded(
          child: hints.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.auto_awesome_rounded, color: accent.withValues(alpha: .7)),
                    const SizedBox(height: 8),
                    const Text('Commitments you make will appear here',
                        style: TextStyle(color: AppColors.textFaint, fontSize: 13)),
                  ]),
                )
              : ListView.builder(
                  itemCount: hints.length,
                  itemBuilder: (context, i) => _HintCard(key: ValueKey(hints[i]), hint: hints[i], accent: accent, fresh: i == 0),
                ),
        ),
        if (captions.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8, bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: .25), borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final c in captions)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: RichText(
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(style: const TextStyle(fontSize: 13, color: AppColors.text, height: 1.35), children: [
                      TextSpan(
                        text: c.speaker == 'employee' ? 'You  ' : '${calls.peerName.split(' ').first}  ',
                        style: TextStyle(fontWeight: FontWeight.w700, color: c.speaker == 'employee' ? accent : AppColors.info),
                      ),
                      TextSpan(text: c.text),
                    ]),
                  ),
                ),
            ]),
          ),
      ]),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard({super.key, required this.hint, required this.accent, required this.fresh});
  final LiveHint hint;
  final Color accent;
  final bool fresh;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: fresh ? 0 : 1, end: 1),
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutBack,
        builder: (context, v, child) => Opacity(
          opacity: v.clamp(0.0, 1.0).toDouble(),
          child: Transform.translate(offset: Offset(0, (1 - v) * 24), child: child),
        ),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: .85),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: .45)),
          ),
          child: Row(children: [
            Icon(categoryIcon(hint.category), size: 20, color: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(hint.title, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.text, fontSize: 14)),
                if (hint.dueText != null)
                  Text(hint.dueText!, style: const TextStyle(fontSize: 12, color: AppColors.warning, fontWeight: FontWeight.w600)),
              ]),
            ),
            Text('Logged', style: TextStyle(fontSize: 11, color: accent, fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}

class _Controls extends StatelessWidget {
  const _Controls({required this.calls, required this.accent});
  final CallController calls;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final live = calls.phase == CallPhase.active;
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _RoundButton(icon: calls.muted ? Icons.mic_off_rounded : Icons.mic_rounded, label: calls.muted ? 'Unmute' : 'Mute', on: calls.muted, onTap: calls.toggleMute),
        _RoundButton(icon: Icons.volume_up_rounded, label: 'Speaker', on: calls.speaker, onTap: calls.toggleSpeaker),
        if (calls.recorded)
          _RoundButton(
            icon: Icons.flag_rounded,
            label: calls.flagged.isEmpty ? 'Flag commitment' : 'Flagged ${calls.flagged.length}',
            on: calls.flagged.isNotEmpty,
            onColor: accent,
            onTap: live ? calls.flagMoment : null,
          ),
      ]),
      const SizedBox(height: 26),
      GestureDetector(
        onTap: calls.phase == CallPhase.ended ? null : calls.hangUp,
        child: Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: AppColors.danger,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: AppColors.danger.withValues(alpha: .45), blurRadius: 22)],
          ),
          child: Transform.rotate(angle: math.pi * .75, child: const Icon(Icons.call_rounded, color: Colors.white, size: 34)),
        ),
      ),
    ]);
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.label, required this.on, required this.onTap, this.onColor});
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback? onTap;
  final Color? onColor;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? .45 : 1,
        child: Column(children: [
          Material(
            color: on ? (onColor ?? Colors.white) : Colors.white.withValues(alpha: .1),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(width: 64, height: 64, child: Icon(icon, color: on && onColor == null ? AppColors.bg : Colors.white, size: 26)),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
        ]),
      );
}
