import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/loader.dart';
import '../call/call_actions.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  String _q = '';

  void _open(Contact c) {
    final kind = c.phone == null ? NumberKind.unknown : numberKind(c.phone!);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Avatar(name: c.name, size: 64),
            const SizedBox(height: 12),
            Text(c.name, style: Theme.of(context).textTheme.titleLarge),
            if (c.company != null) Text(c.company!, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 18),
            if (c.onApp)
              _CallOption(
                icon: Icons.wifi_calling_3_rounded,
                title: 'App call',
                subtitle: 'HD voice over the internet · free',
                onTap: () {
                  Navigator.pop(sheet);
                  placeCall(context, name: c.name, detail: c.company, calleeUserId: c.appUserId, contactId: c.id, isClient: c.isClient);
                },
              ),
            if (c.phone != null)
              _CallOption(
                icon: kind == NumberKind.landline ? Icons.phone_rounded : Icons.phone_android_rounded,
                title: kind == NumberKind.landline ? 'Call landline' : 'Call mobile',
                subtitle: prettyPhone(c.phone),
                onTap: () {
                  Navigator.pop(sheet);
                  placeCall(context, name: c.name, detail: c.company, pstn: true, phone: c.phone, contactId: c.id, isClient: c.isClient);
                },
              ),
          ]),
        ),
      ),
    );
  }

  Future<void> _add() async {
    final name = TextEditingController();
    final company = TextEditingController();
    final phone = TextEditingController();
    final email = TextEditingController();
    final app = AppScope.read(context);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(sheet).bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(app.corporate ? 'New client' : 'New contact', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 10),
            if (app.corporate) ...[
              TextField(controller: company, decoration: const InputDecoration(labelText: 'Company')),
              const SizedBox(height: 10),
            ],
            TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone', hintText: '0803 123 4567', prefixIcon: Icon(Icons.phone_rounded))),
            const SizedBox(height: 10),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Email (for free app calls)',
                helperText: 'If they use Commit AI, you can call them over the internet',
                prefixIcon: Icon(Icons.wifi_calling_3_rounded),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(sheet, true), child: const Text('Save')),
          ]),
        ),
      ),
    );
    if (ok != true) return;
    if (name.text.trim().isEmpty || (phone.text.trim().isEmpty && email.text.trim().isEmpty)) {
      if (mounted) toast(context, 'Add a name and a phone number or email.', icon: Icons.info_outline_rounded);
      return;
    }
    try {
      final c = await app.backend!.addContact(
        name: name.text.trim(),
        company: company.text.trim().isEmpty ? null : company.text.trim(),
        phone: phone.text.trim().isEmpty ? null : toE164(phone.text.trim()),
        email: email.text.trim().isEmpty ? null : email.text.trim(),
      );
      if (mounted) {
        toast(context, c.onApp ? '${c.name} is on Commit AI: app calls are free.' : '${c.name} saved.',
            icon: c.onApp ? Icons.wifi_calling_3_rounded : Icons.check_rounded);
      }
      app.refresh();
    } catch (e) {
      if (mounted) toast(context, '$e', icon: Icons.error_outline_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.person_add_alt_1_rounded)),
      body: Loader<List<Contact>>(
        load: (b) => b.contacts(),
        builder: (context, contacts, reload) {
          final q = _q.toLowerCase();
          final shown = contacts
              .where((c) => q.isEmpty || c.name.toLowerCase().contains(q) || (c.company ?? '').toLowerCase().contains(q) || (c.phone ?? '').contains(q))
              .toList();
          return RefreshIndicator(
            onRefresh: reload,
            child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Text(app.corporate ? 'Clients' : 'Contacts',
                    style: AppType.display(36, weight: FontWeight.w500)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  decoration: InputDecoration(
                    hintText: app.corporate ? 'Search clients and companies' : 'Search contacts',
                    prefixIcon: const Icon(Icons.search_rounded),
                  ),
                ),
              ),
              if (app.corporate)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text('Shared company directory. Personal contacts are hidden in Work mode.',
                      style: TextStyle(fontSize: 12, color: AppColors.textFaint)),
                ),
              const SizedBox(height: 8),
              for (final c in shown)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                  leading: Avatar(name: c.name),
                  title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text([if (c.company != null) c.company!, prettyPhone(c.phone)].where((s) => s.isNotEmpty).join(' · ')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (c.onApp) Pill('App', color: app.palette.accent, dense: true),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
                  ]),
                  onTap: () => _open(c),
                ),
            ]),
          );
        },
      ),
    );
  }
}

class _CallOption extends StatelessWidget {
  const _CallOption({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Card(
          child: ListTile(
            onTap: onTap,
            leading: CircleAvatar(backgroundColor: AppColors.success.withValues(alpha: .15), child: Icon(icon, color: AppColors.success)),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(subtitle),
            trailing: const Icon(Icons.call_rounded, color: AppColors.success),
          ),
        ),
      );
}
