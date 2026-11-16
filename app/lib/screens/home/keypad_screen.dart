import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../call/call_actions.dart';

/// Dial any mobile or landline. In Work mode the call goes out from the
/// company's number and is recorded.
class KeypadScreen extends StatefulWidget {
  const KeypadScreen({super.key});

  @override
  State<KeypadScreen> createState() => _KeypadScreenState();
}

class _KeypadScreenState extends State<KeypadScreen> {
  String _number = '';
  List<Contact> _contacts = const [];
  Object? _loadedFor;

  static const _keys = [
    ('1', ''),
    ('2', 'ABC'),
    ('3', 'DEF'),
    ('4', 'GHI'),
    ('5', 'JKL'),
    ('6', 'MNO'),
    ('7', 'PQRS'),
    ('8', 'TUV'),
    ('9', 'WXYZ'),
    ('*', ''),
    ('0', '+'),
    ('#', ''),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    if (_loadedFor != app.mode) {
      _loadedFor = app.mode;
      app.backend!.contacts().then((c) {
        if (mounted) setState(() => _contacts = c);
      });
    }
  }

  Contact? get _match {
    if (_number.length < 7) return null;
    final e164 = toE164(_number);
    for (final c in _contacts) {
      if (c.phone == e164) return c;
    }
    return null;
  }

  void _press(String k) {
    HapticFeedback.selectionClick();
    if (_number.length < 16) setState(() => _number += k);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = app.palette;
    final kind = numberKind(_number);
    final match = _match;
    final kindLabel = switch (kind) {
      NumberKind.mobile => 'Mobile (GSM)',
      NumberKind.landline => 'Landline',
      NumberKind.unknown => '',
    };
    return LayoutBuilder(builder: (context, box) {
      // Fit the pad to the space: number display + 4 key rows + call row + caption.
      final compact = box.maxHeight < 560;
      final displayH = compact ? 64.0 : 88.0;
      final gap = compact ? 3.0 : 6.0;
      final keySize = ((box.maxHeight - displayH - 70 - 10 * gap) / 5).clamp(40.0, 76.0).toDouble();
      // Scrolls only if even the smallest keys don't fit (very short windows / split screen).
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            SizedBox(
              height: displayH,
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                FittedBox(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(_number.isEmpty ? ' ' : _number, style: AppType.mono(32, letterSpacing: 1.5)),
                  ),
                ),
                const SizedBox(height: 6),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    match != null ? '${match.name}${match.company != null ? ' · ${match.company}' : ''}' : kindLabel,
                    key: ValueKey('${match?.id}$kindLabel'),
                    style: TextStyle(fontSize: 14, color: match != null ? p.accent : AppColors.textDim, fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ),
            SizedBox(height: gap * 2),
            for (var row = 0; row < 4; row++)
              Padding(
                padding: EdgeInsets.symmetric(vertical: gap),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (final (digit, letters) in _keys.sublist(row * 3, row * 3 + 3))
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: _Key(
                        size: keySize,
                        digit: digit,
                        letters: letters,
                        onTap: () => _press(digit),
                        onLongPress: digit == '0' ? () => _press('+') : null,
                      ),
                    ),
                ]),
              ),
            SizedBox(height: gap * 2),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(width: keySize + 28),
              GestureDetector(
                onTap: kind == NumberKind.unknown
                    ? null
                    : () => placeCall(
                          context,
                          name: match?.name ?? prettyPhone(toE164(_number)),
                          detail: match?.company ?? kindLabel,
                          pstn: true,
                          phone: toE164(_number),
                          contactId: match?.id,
                          isClient: match?.isClient ?? app.corporate,
                        ),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: keySize,
                  height: keySize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                        colors: kind == NumberKind.unknown
                            ? [AppColors.surfaceHigh, AppColors.surfaceHigh]
                            : const [Color(0xFF16A34A), Color(0xFF22C55E)]),
                    boxShadow:
                        kind == NumberKind.unknown ? null : [BoxShadow(color: AppColors.success.withValues(alpha: .35), blurRadius: 18)],
                  ),
                  child: Icon(Icons.call_rounded, color: Colors.white, size: keySize * .42),
                ),
              ),
              SizedBox(
                width: keySize + 28,
                child: _number.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () => setState(() => _number = _number.substring(0, _number.length - 1)),
                        icon: const Icon(Icons.backspace_outlined, color: AppColors.textDim),
                      ),
              ),
            ]),
            SizedBox(height: gap * 2),
            Text(
              app.corporate
                  ? 'Calls go out from ${app.session?.organization?.name ?? 'your company'} · recorded'
                  : app.recordsPersonalCalls
                      ? 'Personal call · recorded for you only'
                      : 'Personal call · not recorded',
              style: TextStyle(fontSize: 12, color: app.corporate ? p.accent : AppColors.textFaint, fontWeight: FontWeight.w600),
            ),
          ]),
        ),
      );
    });
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.size, required this.digit, required this.letters, required this.onTap, this.onLongPress});
  final double size;
  final String digit;
  final String letters;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.surfaceHigh,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(
            width: size,
            height: size,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(digit, style: TextStyle(fontSize: size * .4, fontWeight: FontWeight.w500, color: AppColors.text, height: 1)),
              if (letters.isNotEmpty)
                Text(letters,
                    style: TextStyle(fontSize: size * .14, letterSpacing: 1.5, color: AppColors.textFaint, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
}
