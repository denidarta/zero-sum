/// Milliunits to a display string, e.g. 1234500 -> "1,234.50".
String fmt(int ms) {
  final sign = ms < 0 ? '-' : '';
  final cents = (ms.abs() / 10).round();
  final whole = (cents ~/ 100).toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'),
        (_) => ',',
      );
  return '$sign$whole.${(cents % 100).toString().padLeft(2, '0')}';
}

final _amount = RegExp(r'^(-?)(\d[\d,]*)?(?:\.(\d{0,3}))?$');

/// Parse "12", "12.5", "1,234.56" into milliunits. Returns null when invalid.
int? parseAmount(String s) {
  final m = _amount.firstMatch(s.trim());
  if (m == null || (m[2] == null && m[3] == null)) return null;
  final whole = int.parse((m[2] ?? '0').replaceAll(',', ''));
  final frac = int.parse((m[3] ?? '').padRight(3, '0'));
  final v = whole * 1000 + frac;
  return m[1] == '-' ? -v : v;
}

String _two(int n) => n.toString().padLeft(2, '0');

String isoDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String today() => isoDate(DateTime.now());
String thisMonth() => today().substring(0, 7);

String shiftMonth(String month, int delta) {
  final y = int.parse(month.substring(0, 4));
  final m = int.parse(month.substring(5, 7));
  final d = DateTime(y, m + delta, 1);
  return '${d.year}-${_two(d.month)}';
}
