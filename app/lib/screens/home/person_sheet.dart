import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/tiles.dart';
import '../call/call_actions.dart';
import '../call/call_detail_screen.dart';
import '../commitments/commitment_detail_screen.dart';

/// Everything you can do with someone, from a tap on their name: call (app or phone),
/// message (SMS / WhatsApp), see the commitments between you, open the call, save them.
Future<void> showPersonSheet(
  BuildContext context, {
  required String name,
  String? phone,
  String? userId,
  String? contactId,
  String? callId,
  bool callHasDetail = false,
  bool isClient = false,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PersonSheet(
        name: name,
        phone: phone,
        userId: userId,
        contactId: contactId,
        callId: callId,
        callHasDetail: callHasDetail,
        isClient: isClient,
      ),
    );

class _PersonSheet extends StatelessWidget {
  const _PersonSheet({
    required this.name,
    this.phone,
    this.userId,
    this.contactId,
    this.callId,
    this.callHasDetail = false,
    this.isClient = false,
  });
  final String name;
  final String? phone;
  final String? userId;
  final String? contactId;
  final String? callId;
  final bool callHasDetail;
  final bool isClient;

  Future<void> _open(BuildContext context, Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!ok && context.mounted) toast(context, 'No app on this phone can open that.', icon: Icons.error_outline_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final digits = (phone ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    final first = name.split(' ').first;
    void close() => Navigator.pop(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .62,
      minChildSize: .4,
      maxChildSize: .92,
      builder: (context, scroll) => ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
        Center(child: Avatar(name: name, size: 64)),
        const SizedBox(height: 10),
        Text(name, textAlign: TextAlign.center, style: AppType.display(24, weight: FontWeight.w600)),
        if (phone != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(prettyPhone(phone), textAlign: TextAlign.center, style: AppType.mono(13, color: AppColors.textDim)),
          ),
        if (userId != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Center(child: Pill('On Commit Call', color: app.palette.accent, dense: true, icon: Icons.verified_rounded)),
          ),
        const SizedBox(height: 18),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          if (userId != null)
            _Action(Icons.wifi_calling_3_rounded, 'App call', () {
              close();
              placeCall(context, name: name, calleeUserId: userId, contactId: contactId, isClient: isClient);
            }),
          if (phone != null)
            _Action(Icons.call_rounded, 'Call', () {
              close();
              placeCall(context, name: name, pstn: true, phone: phone, contactId: contactId, isClient: isClient);
            }),
          if (phone != null) _Action(Icons.sms_rounded, 'Message', () => _open(context, Uri(scheme: 'sms', path: phone))),
          if (digits.isNotEmpty) _Action(Icons.chat_rounded, 'WhatsApp', () => _open(context, Uri.parse('https://wa.me/$digits'))),
        ]),
        const SizedBox(height: 22),
        SectionLabel('Commitments with $first', padding: const EdgeInsets.fromLTRB(0, 0, 0, 8)),
        FutureBuilder<List<Commitment>>(
          future: app.backend!.commitments(),
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
            }
            final mine = snap.data!
                .where((c) => (c.clientName ?? '').toLowerCase() == name.toLowerCase() || (callId != null && c.callId == callId))
                .toList();
            if (mine.isEmpty) {
              return Text('Nothing yet. Commitments made on calls with $first will show here.',
                  style: const TextStyle(color: AppColors.textDim, fontSize: 13.5));
            }
            return Column(children: [
              for (final c in mine.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: CommitmentTile(
                    c: c,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CommitmentDetailScreen(commitment: c))),
                  ),
                ),
            ]);
          },
        ),
        const SizedBox(height: 8),
        if (callId != null && callHasDetail)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.receipt_long_rounded),
            title: const Text('Call details and transcript'),
            onTap: () {
              close();
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallDetailScreen(callId: callId!)));
            },
          ),
        if (contactId == null && (userId != null || phone != null))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_add_alt_1_rounded),
            title: const Text('Save to contacts'),
            onTap: () async {
              try {
                if (userId != null) {
                  await app.backend!.addAppUser(name: name, userId: userId!);
                } else {
                  await app.backend!.addContact(name: name, phone: phone);
                }
                if (context.mounted) {
                  close();
                  toast(context, '$first saved', icon: Icons.check_rounded);
                  app.refresh();
                }
              } catch (e) {
                if (context.mounted) toast(context, '$e', icon: Icons.error_outline_rounded);
              }
            },
          ),
      ]),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppScope.of(context).palette.accent;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: accent.withValues(alpha: .14), shape: BoxShape.circle),
            child: Icon(icon, color: accent),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
