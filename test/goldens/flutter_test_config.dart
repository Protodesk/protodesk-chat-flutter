import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Glyph anti-aliasing differs slightly between macOS releases (baselines
/// from macOS 27 differ by at most 0.5% of pixels on the macOS 15 CI runner).
/// Layout, color and missing-content regressions change far more than this.
const double _goldenTolerance = 0.01;

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final comparator = goldenFileComparator;
  if (comparator is LocalFileComparator) {
    goldenFileComparator = _TolerantComparator(comparator.basedir);
  }
  await testMain();
}

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(Uri basedir) : super(basedir.resolve('placeholder'));

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _goldenTolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}
