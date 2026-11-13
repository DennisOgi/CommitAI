const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String two(int n) => n.toString().padLeft(2, '0');

String clock(DateTime d) {
  final l = d.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h:${two(l.minute)} ${l.hour < 12 ? 'AM' : 'PM'}';
}

String shortDate(DateTime d) {
  final l = d.toLocal();
  return '${_days[l.weekday - 1]} ${l.day} ${_months[l.month - 1]}';
}

/// "2:14 PM", "Yesterday", "Mon", "3 Nov".
String whenLabel(DateTime d) {
  final now = DateTime.now();
  final l = d.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(l.year, l.month, l.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return clock(l);
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return _days[l.weekday - 1];
  return '${l.day} ${_months[l.month - 1]}';
}

/// Human deadline: "Overdue 2d", "Due in 3h", "Due tomorrow", "Due Fri 6 Nov".
String dueLabel(DateTime? due) {
  if (due == null) return 'No deadline';
  final now = DateTime.now();
  final diff = due.difference(now);
  if (diff.isNegative) {
    final ago = now.difference(due);
    if (ago.inHours < 24) return 'Overdue ${ago.inHours}h';
    return 'Overdue ${ago.inDays}d';
  }
  if (diff.inMinutes < 60) return 'Due in ${diff.inMinutes}m';
  if (diff.inHours < 12) return 'Due in ${diff.inHours}h';
  final l = due.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final dayDiff = DateTime(l.year, l.month, l.day).difference(today).inDays;
  if (dayDiff == 0) return 'Due today ${clock(l)}';
  if (dayDiff == 1) return 'Due tomorrow';
  if (dayDiff < 7) return 'Due ${_days[l.weekday - 1]}';
  return 'Due ${shortDate(l)}';
}

String duration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(p[0])).toList();
  if (parts.isEmpty) return '#';
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// Nigerian numbering heuristics (mirrors the server): +234 70x/80x/81x/90x/91x are mobile.
enum NumberKind { mobile, landline, unknown }

NumberKind numberKind(String raw) {
  var p = raw.replaceAll(RegExp(r'[^\d+]'), '');
  if (p.startsWith('0')) p = '+234${p.substring(1)}';
  if (!p.startsWith('+') || p.length < 8) return NumberKind.unknown;
  if (p.startsWith('+234')) {
    final rest = p.substring(4);
    if (rest.length >= 2 && '789'.contains(rest[0]) && '01'.contains(rest[1])) return NumberKind.mobile;
    return NumberKind.landline;
  }
  return NumberKind.mobile;
}

String toE164(String raw) {
  var p = raw.replaceAll(RegExp(r'[^\d+]'), '');
  if (p.startsWith('0')) p = '+234${p.substring(1)}';
  if (!p.startsWith('+')) p = '+$p';
  return p;
}

String prettyPhone(String? e164) {
  if (e164 == null || e164.isEmpty) return '';
  if (e164.startsWith('+234') && e164.length >= 13) {
    final r = e164.substring(4);
    return '+234 ${r.substring(0, 3)} ${r.substring(3, 6)} ${r.substring(6)}';
  }
  return e164;
}
