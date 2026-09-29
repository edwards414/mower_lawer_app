import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:mower_stdio/services/reconnect_backoff.dart';

void main() {
  test('delays double from the first retry and stop at the cap', () {
    final backoff = ReconnectBackoff(jitter: 0);
    final seconds = [
      for (var i = 0; i < 9; i++) backoff.nextDelay().inMilliseconds / 1000,
    ];
    expect(seconds, [1, 2, 4, 8, 16, 30, 30, 30, 30]);
    expect(backoff.failures, 9);
  });

  test('a days-long outage stays at the cap', () {
    final backoff = ReconnectBackoff(jitter: 0);
    // 3.5 days of 30 s retries.
    for (var i = 0; i < 10080; i++) {
      backoff.nextDelay();
    }
    expect(backoff.nominalDelay, const Duration(seconds: 30));
    expect(backoff.nextDelay(), const Duration(seconds: 30));
  });

  test('jitter keeps every delay within +-20 % of the nominal one', () {
    final backoff = ReconnectBackoff(random: math.Random(7));
    for (var i = 0; i < 500; i++) {
      final nominal = backoff.nominalDelay;
      final delay = backoff.nextDelay();
      expect(delay, greaterThanOrEqualTo(nominal * 0.8));
      expect(delay, lessThanOrEqualTo(nominal * 1.2));
    }
  });

  test('jitter reaches both ends of its range', () {
    expect(
      ReconnectBackoff(random: _FixedRandom(0)).nextDelay(),
      const Duration(milliseconds: 800),
    );
    expect(
      ReconnectBackoff(random: _FixedRandom(0.5)).nextDelay(),
      const Duration(seconds: 1),
    );
    // nextDouble() is < 1, so the top end is approached, never passed.
    final top = ReconnectBackoff(random: _FixedRandom(0.99999)).nextDelay();
    expect(top, greaterThan(const Duration(milliseconds: 1199)));
    expect(top, lessThanOrEqualTo(const Duration(milliseconds: 1200)));

    final capped = ReconnectBackoff(random: _FixedRandom(0));
    for (var i = 0; i < 10; i++) {
      capped.nextDelay();
    }
    expect(capped.nextDelay(), const Duration(seconds: 24));
  });

  test('phones that failed together do not retry together', () {
    final firstRetries = {
      for (var seed = 0; seed < 20; seed++)
        ReconnectBackoff(random: math.Random(seed)).nextDelay(),
    };
    expect(firstRetries.length, greaterThan(15));
  });

  test('a per-wait cap shortens only that wait, jittered', () {
    final backoff = ReconnectBackoff(jitter: 0);
    const cap = Duration(seconds: 2);
    final seconds = [
      for (var i = 0; i < 6; i++)
        backoff.nextDelay(cap: cap).inMilliseconds / 1000,
    ];
    expect(seconds, [1, 2, 2, 2, 2, 2]);
    expect(backoff.failures, 6);
    // Without the cap the doubling is where six failures put it.
    expect(backoff.nextDelay(), const Duration(seconds: 30));

    final early = ReconnectBackoff(random: _FixedRandom(0));
    for (var i = 0; i < 10; i++) {
      early.nextDelay();
    }
    expect(early.nextDelay(cap: cap), const Duration(milliseconds: 1600));
  });

  test('reset starts over at the first delay', () {
    final backoff = ReconnectBackoff(jitter: 0);
    for (var i = 0; i < 6; i++) {
      backoff.nextDelay();
    }
    expect(backoff.nominalDelay, const Duration(seconds: 30));
    backoff.reset();
    expect(backoff.failures, 0);
    expect(backoff.nextDelay(), const Duration(seconds: 1));
    expect(backoff.nextDelay(), const Duration(seconds: 2));
  });
}

class _FixedRandom implements math.Random {
  _FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => value >= 0.5;

  @override
  int nextInt(int max) => (value * max).floor();
}
