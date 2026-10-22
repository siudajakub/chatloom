// SPDX-License-Identifier: AGPL-3.0-or-later
// Host side of integration_test/perf/smoothness_test.dart: writes the frame
// summaries to build/perf/chatloom_smoothness.json.
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) => writeResponseData(
    data,
    testOutputFilename: 'chatloom_smoothness',
    destinationDirectory: 'build/perf',
  ),
);
