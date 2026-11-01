import 'package:flutter_test/flutter_test.dart';
import 'package:zero_sum/money.dart';

void main() {
  test('fmt', () {
    expect(fmt(1234500), '1,234.50');
    expect(fmt(-5000), '-5.00');
    expect(fmt(0), '0.00');
    expect(fmt(999), '1.00');
    expect(fmt(1234567890), '1,234,567.89');
  });

  test('parseAmount', () {
    expect(parseAmount('12'), 12000);
    expect(parseAmount('12.5'), 12500);
    expect(parseAmount('1,234.56'), 1234560);
    expect(parseAmount('-3.001'), -3001);
    expect(parseAmount(' .5 '), 500);
    expect(parseAmount(''), isNull);
    expect(parseAmount('abc'), isNull);
    expect(parseAmount('1.2345'), isNull);
    expect(parseAmount('-'), isNull);
    expect(parseAmount('99999999999999999999'), isNull);
    expect(parseAmount('9007199254740.992'), isNull);
  });

  test('shiftMonth', () {
    expect(shiftMonth('2026-12', 1), '2027-01');
    expect(shiftMonth('2026-01', -1), '2025-12');
    expect(shiftMonth('2026-10', 0), '2026-10');
  });
}
