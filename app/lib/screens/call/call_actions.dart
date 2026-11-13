import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';
import 'in_call_screen.dart';

/// Opens the in-call screen and dials. If the callee can't take the call
/// (they're in Work mode, or off duty), shows why instead of ringing forever.
Future<void> placeCall(
  BuildContext context, {
  required String name,
  String? detail,
  bool pstn = false,
  String? phone,
  String? calleeUserId,
  String? contactId,
  bool isClient = false,
}) async {
  final app = AppScope.read(context);
  final calls = app.calls!;
  if (calls.busy) return;
  final nav = Navigator.of(context);
  nav.push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const InCallScreen()));
  final blocked = await calls.dial(
    name: name,
    detail: detail,
    pstn: pstn,
    phone: phone,
    calleeUserId: calleeUserId,
    contactId: contactId,
    isClient: isClient,
  );
  if (blocked != null && calls.phase.index <= 1 && context.mounted) {
    nav.pop();
    calls.dismiss();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        icon: const Icon(Icons.do_not_disturb_on_rounded, color: AppColors.warning, size: 36),
        title: Text(blocked.toLowerCase().contains('microphone') ? 'Microphone needed' : '$name can\'t take this call'),
        content: Text(blocked, textAlign: TextAlign.center),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
    app.refresh();
  }
}
