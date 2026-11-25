import 'dart:io';

// Generate private end-to-end copies so production code stays untouched.
void main() {
  final source = File('lib/src/pdq.dart').readAsStringSync();
  final kernels = File('benchmark/kernels.dart').readAsStringSync();
  final start = source.indexOf('    for (var y = 0; y < height; y++)');
  final end = source.indexOf('\n    final small =', start);
  if (start < 0 || end < 0) {
    throw StateError('Cannot find production luminance loop');
  }
  final dir = Directory('.dart_tool/luminance_benchmark')
    ..createSync(recursive: true);
  for (final name in ['baseline', 'lut', 'store', 'hoisted', 'simd']) {
    var generated = source.replaceFirst(
      "'pdq_hash.dart'",
      "'../../lib/src/pdq_hash.dart'",
    );
    if (name != 'baseline') {
      final function = kernels.indexOf('void $name(');
      final bodyStart = kernels.indexOf(') {', function) + 3;
      final bodyEnd = kernels.indexOf('\n}', bodyStart);
      var body = kernels.substring(bodyStart, bodyEnd);
      for (final helper in [
        'f32',
        'redLut',
        'greenLut',
        'blueLut',
        'red4',
        'green4',
        'blue4',
        'red',
        'green',
        'blue',
      ]) {
        body = body.replaceAll(RegExp('\\b$helper\\b'), 'k.$helper');
      }
      body = body.replaceAll('channels', 'format.channels');
      // Recompute indices after changing the import length.
      final a = generated.indexOf('    for (var y = 0; y < height; y++)');
      final b = generated.indexOf('\n    final small =', a);
      generated = generated.replaceRange(a, b, body);
      generated = generated.replaceFirst(
        "import 'dart:math' as math;",
        "import 'dart:math' as math;\nimport '../../benchmark/kernels.dart' as k;",
      );
    }
    File('${dir.path}/$name.dart').writeAsStringSync(generated);
  }
  print('Generated end-to-end variants in ${dir.path}');
}
