import 'dart:math' as math;

/// Capped exponential backoff with jitter for reconnect / retry loops.
///
/// The wait before retry n (n = consecutive failures so far) is
/// `min(maxDelay, initialDelay * 2^n)`, scaled by a random factor in
/// `[1 - jitter, 1 + jitter]` so a fleet of phones that lost the same robot
/// (or backend) does not retry in lock-step. The cap applies before the
/// jitter, so phones sitting at the cap stay spread out too (30 s +-20 %).
///
/// Call [reset] only once a connection has proven healthy, not merely when a
/// socket opens: a server that accepts and then drops would otherwise be
/// retried at the fastest rate forever.
class ReconnectBackoff {
  ReconnectBackoff({
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.jitter = 0.2,
    math.Random? random,
  }) : assert(initialDelay > Duration.zero),
       assert(maxDelay >= initialDelay),
       assert(jitter >= 0 && jitter < 1),
       _random = random ?? math.Random();

  final Duration initialDelay;
  final Duration maxDelay;

  /// Relative spread of each delay, e.g. 0.2 = +-20 %.
  final double jitter;
  final math.Random _random;
  int _failures = 0;

  /// Consecutive failures since the last [reset].
  int get failures => _failures;

  /// The un-jittered wait before the next retry.
  Duration get nominalDelay {
    var delay = initialDelay;
    // Doubling stops at the cap, so a days-long outage cannot overflow.
    for (var i = 0; i < _failures && delay < maxDelay; i++) {
      delay *= 2;
    }
    return delay < maxDelay ? delay : maxDelay;
  }

  /// Count one more failure and return how long to wait before retrying.
  /// [cap] lowers [maxDelay] for this one wait (still jittered); the failure
  /// count grows as usual, so the next uncapped wait picks up where the
  /// doubling would have been.
  Duration nextDelay({Duration? cap}) {
    var nominal = nominalDelay;
    if (cap != null && cap < nominal) {
      nominal = cap;
    }
    _failures += 1;
    final factor = 1 + jitter * (2 * _random.nextDouble() - 1);
    return nominal * factor;
  }

  void reset() {
    _failures = 0;
  }
}
