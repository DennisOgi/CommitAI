import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// Add or change the user's own phone number (how contacts who have it saved find them).
Future<void> showPhoneNumberSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _PhoneSheet(),
    );

class _PhoneSheet extends StatefulWidget {
  const _PhoneSheet();

  @override
  State<_PhoneSheet> createState() => _PhoneSheetState();
}

class _PhoneSheetState extends State<_PhoneSheet> {
  late final _phone = TextEditingController(text: AppScope.read(context).myPhone ?? '');
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await AppScope.read(context).setMyPhone(_phone.text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(content: Text(_phone.text.trim().isEmpty ? 'Phone number removed.' : 'Phone number saved.')));
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Your phone number', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
              'People who have this number saved will see you on Commit Call and can call you free. '
              'It isn’t shown to anyone else.',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 18),
          TextField(
            controller: _phone,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
                labelText: 'Phone number', hintText: 'e.g. 0803 123 4567', prefixIcon: Icon(Icons.phone_iphone_rounded)),
            onSubmitted: (_) => _save(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
        ]),
      );
}

/// A one-line nudge on the Contacts tab when the user hasn't added their number.
class AddPhoneNudge extends StatelessWidget {
  const AddPhoneNudge({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (app.myPhone != null || app.isDemo) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        child: ListTile(
          leading: Icon(Icons.phone_iphone_rounded, color: app.palette.accent),
          title: const Text('Add your phone number', style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(app.phoneProblem ?? 'So friends who have your number find you here.'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showPhoneNumberSheet(context),
        ),
      ),
    );
  }
}
