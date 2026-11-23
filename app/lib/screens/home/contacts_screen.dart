import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as phone;
import 'package:permission_handler/permission_handler.dart' as perm;

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/loader.dart';
import '../../widgets/phone_sheet.dart';
import '../call/call_actions.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  String _q = '';
  bool _importing = false;

  /// The round button: everyone, or only contacts who are on Commit AI (free app calls).
  bool _onAppOnly = false;

  // "On Commit AI": everyone with an account, found by name or email.
  Timer? _debounce;
  List<PlatformUser> _people = [];
  bool _searching = false;
  String _searchedFor = '';
  final Set<String> _saving = {};

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onQuery(String v) {
    setState(() => _q = v);
    _debounce?.cancel();
    final q = v.trim();
    if (q.length < 2) {
      setState(() => _people = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _searchPeople(q));
  }

  Future<void> _searchPeople(String q) async {
    final app = AppScope.read(context);
    if (app.backend == null) return;
    setState(() => _searching = true);
    try {
      final r = await app.backend!.searchUsers(q);
      if (mounted && _q.trim() == q) {
        setState(() {
          _people = r;
          _searchedFor = q;
        });
      }
    } catch (_) {
      // Search is best-effort; the local list still works.
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _savePerson(PlatformUser u) async {
    final app = AppScope.read(context);
    setState(() => _saving.add(u.userId));
    try {
      await app.backend!.addAppUser(name: u.fullName, userId: u.userId);
      if (!mounted) return;
      toast(context, '${u.fullName} saved to your contacts.', icon: Icons.check_rounded);
      app.refresh();
      await _searchPeople(_q.trim());
    } catch (e) {
      if (mounted) toast(context, '$e', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _saving.remove(u.userId));
    }
  }

  List<Widget> _peopleSection(AppState app, List<Contact> contacts) {
    final q = _q.trim();
    if (q.length < 2 || app.isDemo) return const [];
    final mine = {
      for (final c in contacts)
        if (c.appUserId != null) c.appUserId!
    };
    final people = [
      for (final u in _people)
        if (!mine.contains(u.userId)) u
    ];
    final theme = Theme.of(context);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
        child: Row(children: [
          Icon(Icons.public_rounded, size: 16, color: app.palette.accent),
          const SizedBox(width: 6),
          Text('ON COMMIT AI', style: theme.textTheme.labelMedium?.copyWith(letterSpacing: 1.2, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (_searching) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
      ),
      if (people.isEmpty && !_searching && _searchedFor == q)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
          child: Text(
            q.contains('@')
                ? 'No account uses that email yet. Ask them to download Commit AI.'
                : 'No one named "$q" yet. Try their full name or their email.',
            style: const TextStyle(fontSize: 13, color: AppColors.textFaint),
          ),
        ),
      for (final u in people)
        ListTile(
          contentPadding: const EdgeInsets.fromLTRB(20, 2, 12, 2),
          leading: Avatar(name: u.fullName),
          title: Text(u.fullName, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(u.emailHint ?? 'On Commit AI'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (u.contactId == null)
              IconButton(
                tooltip: 'Save contact',
                onPressed: _saving.contains(u.userId) ? null : () => _savePerson(u),
                icon: _saving.contains(u.userId)
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.person_add_alt_rounded),
              ),
            IconButton.filledTonal(
              tooltip: 'Free app call',
              onPressed: () => placeCall(context, name: u.fullName, calleeUserId: u.userId, contactId: u.contactId),
              icon: const Icon(Icons.wifi_calling_3_rounded),
            ),
          ]),
        ),
    ];
  }

  static bool get _phoneContactsAvailable =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  /// Personal mode: bring the phone's address book in, after explaining why and asking permission.
  Future<void> _importFromPhone() async {
    final app = AppScope.read(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.contacts_rounded, size: 32),
        title: const Text('Import your phone contacts?'),
        content: const Text(
          'Commit AI will copy the names, numbers and emails from your phone so you can call them here, '
          'and show which contacts are on Commit AI (free app calls).\n\n'
          'They go into your Personal contacts only: never shared with your company, managers or colleagues.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Continue')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    if (!await _contactsAllowed()) return;
    setState(() => _importing = true);
    try {
      final r = await app.syncContacts(force: true);
      if (!mounted) return;
      if (r == null) {
        toast(context, 'Couldn’t import right now. Check your connection and try again.', icon: Icons.error_outline_rounded);
        return;
      }
      toast(
        context,
        r.imported == 0
            ? 'Your contacts are up to date${r.onApp > 0 ? ' · ${r.onApp} on Commit AI' : ''}.'
            : 'Imported ${r.imported} contact${r.imported == 1 ? '' : 's'}'
                '${r.onApp > 0 ? ' · ${r.onApp} on Commit AI' : ''}'
                '${app.corporate ? '. Switch to Personal to see them' : ''}.',
        icon: Icons.check_circle_rounded,
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Shows Android's / iOS's contacts permission prompt. If the user blocked it earlier
  /// (no prompt can be shown any more), offers to open the app's settings instead.
  Future<bool> _contactsAllowed() async {
    var status = await perm.Permission.contacts.status;
    if (status.isGranted || status.isLimited) return true;
    if (!status.isPermanentlyDenied && !status.isRestricted) {
      try {
        status = await perm.Permission.contacts.request();
      } catch (_) {
        // Another permission prompt was still open; ask once more.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        status = await perm.Permission.contacts.request();
      }
      if (status.isGranted || status.isLimited) return true;
    }
    if (!mounted) return false;
    if (status.isPermanentlyDenied || status.isRestricted) {
      final open = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Allow access to contacts'),
          content: const Text('Contacts access is turned off for Commit AI. Open Settings → Permissions → '
              'Contacts and choose Allow, then come back and try again.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Open Settings')),
          ],
        ),
      );
      if (open == true) await perm.openAppSettings();
    } else {
      toast(context, 'Contacts permission was not given.', icon: Icons.lock_outline_rounded);
    }
    return false;
  }

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
    final phoneCtl = TextEditingController();
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
            if (_phoneContactsAvailable) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.contacts_rounded),
                label: const Text('Pick from phone contacts'),
                onPressed: () async {
                  if (!await _contactsAllowed()) return;
                  final picked = await phone.FlutterContacts.native
                      .showPicker(properties: {phone.ContactProperty.name, phone.ContactProperty.phone, phone.ContactProperty.email});
                  if (picked == null) return;
                  name.text = picked.displayName ?? name.text;
                  if (picked.phones.isNotEmpty) phoneCtl.text = picked.phones.first.number;
                  if (picked.emails.isNotEmpty) email.text = picked.emails.first.address;
                },
              ),
              const SizedBox(height: 10),
            ],
            TextField(
                controller: phoneCtl,
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
    if (name.text.trim().isEmpty || (phoneCtl.text.trim().isEmpty && email.text.trim().isEmpty)) {
      if (mounted) toast(context, 'Add a name and a phone number or email.', icon: Icons.info_outline_rounded);
      return;
    }
    try {
      final c = await app.backend!.addContact(
        name: name.text.trim(),
        company: company.text.trim().isEmpty ? null : company.text.trim(),
        phone: phoneCtl.text.trim().isEmpty ? null : toE164(phoneCtl.text.trim()),
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
      body: Loader<List<Contact>>(
        load: (b) => b.contacts(),
        builder: (context, contacts, reload) {
          final q = _q.toLowerCase();
          final onAppCount = contacts.where((c) => c.onApp).length;
          final shown = contacts
              .where((c) =>
                  (!_onAppOnly || c.onApp) &&
                  (q.isEmpty ||
                      c.name.toLowerCase().contains(q) ||
                      (c.company ?? '').toLowerCase().contains(q) ||
                      (c.phone ?? '').contains(q)))
              .toList();
          final people = _peopleSection(app, contacts);
          return Stack(children: [
            RefreshIndicator(
              onRefresh: () async {
                await app.syncContacts(force: true); // pull-to-refresh also picks up new phone contacts
                await reload();
              },
              child: CustomScrollView(slivers: [
                SliverToBoxAdapter(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            _onAppOnly ? 'On Commit AI' : (app.corporate ? 'Clients' : 'Contacts'),
                            style: AppType.display(36, weight: FontWeight.w500),
                          ),
                        ),
                        IconButton.filledTonal(
                          tooltip: app.corporate ? 'Add a client' : 'Add a contact',
                          onPressed: _add,
                          icon: const Icon(Icons.person_add_alt_1_rounded),
                        ),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        onChanged: _onQuery,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: app.corporate ? 'Search clients, or anyone on Commit AI' : 'Search contacts or anyone on Commit AI',
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
                    if (!app.corporate) const AddPhoneNudge(),
                    // Offered until the first import; after that the app keeps contacts in sync by itself.
                    if (_phoneContactsAvailable && !app.isDemo && !app.contactsSynced)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Card(
                          child: ListTile(
                            leading: Icon(Icons.contacts_rounded, color: app.palette.accent),
                            title: const Text('Import your phone contacts', style: TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text(app.corporate
                                ? 'Saved to your private Personal contacts (switch to Personal to see them).'
                                : 'See who’s on Commit AI and call them free. Private to you.'),
                            trailing: _importing
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.chevron_right_rounded),
                            onTap: _importing ? null : _importFromPhone,
                          ),
                        ),
                      ),
                    if (_onAppOnly && shown.isEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(24, 32, 24, 0),
                        child: Text(
                          'None of your contacts are on Commit AI yet. When someone you have saved joins, they’ll show up here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textDim),
                        ),
                      ),
                    const SizedBox(height: 8),
                  ]),
                ),
                SliverList.builder(
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final c = shown[i];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                      leading: Avatar(name: c.name),
                      title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text([if (c.company != null) c.company!, prettyPhone(c.phone)].where((s) => s.isNotEmpty).join(' · ')),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (c.onApp) Pill('On Commit AI', color: app.palette.accent, dense: true),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
                      ]),
                      onTap: () => _open(c),
                    );
                  },
                ),
                SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: people)),
                const SliverToBoxAdapter(child: SizedBox(height: 110)),
              ]),
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.extended(
                heroTag: 'contacts-filter',
                onPressed: () => setState(() => _onAppOnly = !_onAppOnly),
                icon: Icon(_onAppOnly ? Icons.people_alt_rounded : Icons.wifi_calling_3_rounded),
                label: Text(_onAppOnly ? 'All contacts' : 'On Commit AI · $onAppCount'),
              ),
            ),
          ]);
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
