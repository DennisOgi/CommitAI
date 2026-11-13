import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../models/models.dart';
import 'common.dart';

class CommitmentTile extends StatelessWidget {
  const CommitmentTile({super.key, required this.c, this.onTap, this.showEmployee = false, this.trailing});
  final Commitment c;
  final VoidCallback? onTap;
  final bool showEmployee;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final s = statusStyle(c);
    final dueColor = c.isOverdue
        ? AppColors.danger
        : c.dueAt != null && c.dueAt!.difference(DateTime.now()).inHours < 24 && c.isLive
            ? AppColors.warning
            : AppColors.textDim;
    final done = c.status == CommitmentStatus.fulfilled || c.status == CommitmentStatus.cancelled;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Status rail: the colour of the promise's state, readable at a glance down a list.
            Container(width: 3.5, color: done ? AppColors.outline : s.color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: s.color.withValues(alpha: .10),
                      shape: BoxShape.circle,
                      border: Border.all(color: s.color.withValues(alpha: .28)),
                    ),
                    child: Icon(categoryIcon(c.category), color: s.color, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15.5,
                            height: 1.3,
                            fontWeight: FontWeight.w700,
                            color: done ? AppColors.textDim : AppColors.text,
                            decoration: c.status == CommitmentStatus.cancelled ? TextDecoration.lineThrough : null,
                          )),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (c.byClient) 'Client committed' else if (showEmployee && c.employeeName != null) c.employeeName!,
                          if (c.clientName != null) c.clientName!,
                        ].join(' · '),
                        style: const TextStyle(fontSize: 13, color: AppColors.textDim),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Pill(s.label, color: s.color, icon: s.icon, dense: true),
                        if (!done)
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.schedule_rounded, size: 13, color: dueColor),
                            const SizedBox(width: 3),
                            Text(dueLabel(c.dueAt), style: AppType.mono(11.5, color: dueColor, weight: FontWeight.w600)),
                          ]),
                        if (c.priority == 'high' && !done)
                          const Pill('High', color: AppColors.danger, icon: Icons.priority_high_rounded, dense: true),
                      ]),
                    ]),
                  ),
                  if (trailing != null) trailing!,
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class CallTile extends StatelessWidget {
  const CallTile({super.key, required this.call, this.onTap, this.onCall});
  final CallRecord call;
  final VoidCallback? onTap;
  final VoidCallback? onCall;

  @override
  Widget build(BuildContext context) {
    final inbound = call.direction == 'inbound';
    final (IconData icon, Color color, String what) = switch (call.status) {
      'blocked_mode' => (Icons.do_not_disturb_on_rounded, AppColors.warning, 'Held while you were at work'),
      'off_duty' => (Icons.voicemail_rounded, AppColors.warning, 'Off duty · went to voicemail'),
      'missed' || 'rejected' => (Icons.call_missed_rounded, AppColors.danger, inbound ? 'Missed' : 'No answer'),
      _ => (inbound ? Icons.call_received_rounded : Icons.call_made_rounded, AppColors.textFaint, ''),
    };
    final channel = switch (call.channel) {
      CallChannel.app => 'App',
      CallChannel.pstnMobile => 'Mobile',
      CallChannel.pstnLandline => 'Landline',
      CallChannel.sip => 'SIP',
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: Row(children: [
          Avatar(name: call.counterpartName, size: 44),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(call.counterpartName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: call.missed ? color : AppColors.text)),
              const SizedBox(height: 3),
              Row(children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    [what.isEmpty ? channel : what, if (call.length != null) duration(call.length!)].join(' · '),
                    style: const TextStyle(fontSize: 13, color: AppColors.textDim),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(whenLabel(call.startedAt), style: AppType.mono(11.5, color: AppColors.textFaint)),
            const SizedBox(height: 6),
            if (call.mode == AppMode.corporate && call.commitmentCount > 0)
              Pill('${call.commitmentCount}', color: Theme.of(context).colorScheme.primary, icon: Icons.handshake_rounded, dense: true)
            else if (call.processing == 'pending' || call.processing == 'processing')
              const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6)),
          ]),
          if (onCall != null) IconButton(onPressed: onCall, icon: Icon(Icons.call_rounded, color: Theme.of(context).colorScheme.primary)),
        ]),
      ),
    );
  }
}
