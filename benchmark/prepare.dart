import 'dart:io';

// Generate end-to-end copies with alternative luminance kernels.
void main() {
  final source = File('lib/src/pdq.dart').readAsStringSync();
  final kernels = File('benchmark/kernels.dart').readAsStringSync();
  const marker = '    final luma = Float32List(width * height);';
  final start = source.indexOf(marker);
  final end = start < 0 ? -1 : source.indexOf('\n    final small =', start);
  if (start < 0 || end < 0) {
    throw StateError('Cannot find production luminance conversion');
  }
  final dir = Directory('.dart_tool/luminance_benchmark')
    ..createSync(recursive: true);
  for (final name in ['baseline', 'lut', 'store', 'simd']) {
    var generated = source
        .replaceFirst("'pdq_hash.dart'", "'../../lib/src/pdq_hash.dart'")
        .replaceFirst("import 'luminance.dart';\n", '');
    final function = kernels.indexOf('void $name(');
    final signatureEnd = function < 0 ? -1 : kernels.indexOf(') {', function);
    final bodyEnd =
        signatureEnd < 0 ? -1 : kernels.indexOf('\n}', signatureEnd);
    if (function < 0 || signatureEnd < 0 || bodyEnd < 0) {
      throw StateError('Cannot find $name benchmark kernel');
    }
    var body = kernels.substring(signatureEnd + 3, bodyEnd);
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
      final replacement = name == 'baseline' ? '_$helper' : 'k.$helper';
      body = body.replaceAll(RegExp('\\b$helper\\b'), replacement);
    }
    body = body.replaceAll(RegExp(r'\bchannels\b'), 'format.channels');
    if (name == 'baseline') {
      const grayscale = 'if (format.channels == 1)';
      if (!body.contains(grayscale)) {
        throw StateError('Cannot find baseline grayscale branch');
      }
      body = body.replaceFirst(
        grayscale,
        'if (format == PdqPixelFormat.grayscale)',
      );
    }
    final a = generated.indexOf(marker);
    final b = generated.indexOf('\n    final small =', a);
    generated = generated.replaceRange(a + marker.length, b, body);
    if (name == 'baseline') {
      generated += '''
final _red = _f32(0.299);
final _green = _f32(0.587);
final _blue = _f32(0.114);
''';
    } else {
      generated = generated.replaceFirst(
        "import 'dart:math' as math;",
        "import 'dart:math' as math;\nimport '../../benchmark/kernels.dart' as k;",
      );
    }
    File('${dir.path}/$name.dart').writeAsStringSync(generated);
  }
  final driver = File('benchmark/luminance.dart.template').readAsStringSync();
  File('${dir.path}/luminance.dart').writeAsStringSync(driver);
  print('Generated end-to-end variants in ${dir.path}');
}
