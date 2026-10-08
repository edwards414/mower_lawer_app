import 'package:integration_test/integration_test_driver.dart';

/// Host side of `flutter drive` for integration tests (needed for --profile
/// runs, e.g. integration_test/ai_basemap_benchmark_test.dart).
Future<void> main() => integrationDriver();
