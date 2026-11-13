import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/backend.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import 'in_call_screen.dart';

/// Foreground incoming-call UI. (Background calls use the native screen via CallKit.)
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({super.key, required this.call});
  final IncomingCall call;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> with SingleTickerProviderStateMixin {
  late final _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    _timeout = Timer(const Duration(seconds: 45), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _wave.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    _timeout?.cancel();
    final calls = AppScope.read(context).calls!;
    Navigator.of(context).pushReplacement(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const InCallScreen()));
    await calls.accept(widget.call);
  }

  Future<void> _decline() async {
    _timeout?.cancel();
    final app = AppScope.read(context);
    await app.calls!.decline(widget.call);
    app.refresh();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final work = widget.call.mode == AppMode.corporate;
    final p = work ? ModePalette.corporate : ModePalette.personal;
    final parts = widget.call.callerName.split(' · ');
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [p.gradient.first.withValues(alpha: .55), AppColors.bg]),
        ),
        child: SafeArea(
          child: Column(children: [
            const SizedBox(height: 24),
            Pill(work ? 'Work call · will be recorded' : 'Personal call', color: work ? const Color(0xFFC4BDFF) : p.accent,
                icon: work ? Icons.business_center_rounded : Icons.person_rounded),
            const Spacer(),
            AnimatedBuilder(
              animation: _wave,
              builder: (context, child) => Transform.scale(scale: 1 + _wave.value * .05, child: child),
              child: Avatar(name: parts.first, size: 120),
            ),
            const SizedBox(height: 22),
            Text(parts.first, style: AppType.display(38, weight: FontWeight.w500)),
            if (parts.length > 1) Text(parts.last, style: const TextStyle(fontSize: 16, color: AppColors.textDim)),
            const SizedBox(height: 6),
            const Text('Commit AI call…', style: TextStyle(color: AppColors.textDim)),
            const Spacer(flex: 2),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _Action(color: AppColors.danger, icon: Icons.call_end_rounded, label: 'Decline', onTap: _decline, rotate: false),
              _Action(color: AppColors.success, icon: Icons.call_rounded, label: 'Accept', onTap: _accept, rotate: false),
            ]),
            const SizedBox(height: 48),
          ]),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.color, required this.icon, required this.label, required this.onTap, required this.rotate});
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool rotate;

  @override
  Widget build(BuildContext context) => Column(children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: [BoxShadow(color: color.withValues(alpha: .5), blurRadius: 24)]),
            child: Transform.rotate(angle: rotate ? math.pi * .75 : 0, child: Icon(icon, color: Colors.white, size: 34)),
          ),
        ),
        const SizedBox(height: 10),
        Text(label, style: const TextStyle(color: AppColors.textDim, fontWeight: FontWeight.w600)),
      ]);
}
