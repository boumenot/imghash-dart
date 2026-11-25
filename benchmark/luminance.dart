import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../.dart_tool/luminance_benchmark/baseline.dart' as base;
import '../.dart_tool/luminance_benchmark/lut.dart' as lut;
import '../.dart_tool/luminance_benchmark/store.dart' as store;
import '../.dart_tool/luminance_benchmark/hoisted.dart' as hoisted;
import '../.dart_tool/luminance_benchmark/simd.dart' as simd;
import '../lib/src/pdq_hash.dart';
import 'kernels.dart' as k;

typedef Calculate = PdqResult Function(
  Uint8List pixels,
  int width,
  int height,
  int channels,
  int stride,
);

final calculates = <String, Calculate>{
  'baseline': (p, w, h, c, s) => const base.Pdq().calculate(
        p,
        width: w,
        height: h,
        rowStride: s,
        format: base.PdqPixelFormat.values[c == 1 ? 0 : c - 2],
      ),
  'lut': (p, w, h, c, s) => const lut.Pdq().calculate(
        p,
        width: w,
        height: h,
        rowStride: s,
        format: lut.PdqPixelFormat.values[c == 1 ? 0 : c - 2],
      ),
  'store': (p, w, h, c, s) => const store.Pdq().calculate(
        p,
        width: w,
        height: h,
        rowStride: s,
        format: store.PdqPixelFormat.values[c == 1 ? 0 : c - 2],
      ),
  'hoisted': (p, w, h, c, s) => const hoisted.Pdq().calculate(
        p,
        width: w,
        height: h,
        rowStride: s,
        format: hoisted.PdqPixelFormat.values[c == 1 ? 0 : c - 2],
      ),
  'simd': (p, w, h, c, s) => const simd.Pdq().calculate(
        p,
        width: w,
        height: h,
        rowStride: s,
        format: simd.PdqPixelFormat.values[c == 1 ? 0 : c - 2],
      ),
};

int sink = 0;

Uint8List fixture(int width, int height, int mode) {
  final channels = mode == 0 ? 1 : 3;
  return Uint8List.fromList(
    List.generate(width * height * channels, (i) {
      final x = i ~/ channels % width;
      final y = i ~/ channels ~/ width;
      final c = i % channels;
      return switch (mode) {
        2 => 127,
        3 => ((x ~/ 3 + y ~/ 5) % 2) * 255,
        _ =>
          (x * 17 + y * 31 + x * y * 7 + c * 53 + c * x * 11 + c * y * 3) & 255,
      };
    }),
  );
}

void checkLuma(Uint8List pixels, int w, int h, int c, int stride) {
  final expected = Float32List(w * h);
  k.baseline(pixels, w, h, stride, c, expected);
  final bits = expected.buffer.asUint32List();
  for (final entry in k.kernels.entries) {
    final actual = Float32List(w * h);
    entry.value(pixels, w, h, stride, c, actual);
    final actualBits = actual.buffer.asUint32List();
    for (var i = 0; i < bits.length; i++) {
      if (bits[i] != actualBits[i]) {
        throw StateError(
          '${entry.key}: luma mismatch $w x $h/$c at $i: '
          '${bits[i]} != ${actualBits[i]}',
        );
      }
    }
  }
}

void verify() {
  final vectors = jsonDecode(
    File('test/fixtures/meta_vectors.json').readAsStringSync(),
  ) as List<dynamic>;
  for (final raw in vectors) {
    final v = raw as Map<String, dynamic>;
    final w = v['width'] as int;
    final h = v['height'] as int;
    final mode = v['mode'] as int;
    final c = mode == 0 ? 1 : 3;
    final p = fixture(w, h, mode);
    checkLuma(p, w, h, c, w * c);
    for (final entry in calculates.entries) {
      final result = entry.value(p, w, h, c, w * c);
      if (result.hash.toHex() != v['hash'] || result.quality != v['quality']) {
        throw StateError('${entry.key}: reference mismatch $w x $h mode $mode');
      }
    }
  }
  final random = Random(7834);
  for (var trial = 0; trial < 100; trial++) {
    final w = 5 + random.nextInt(132);
    final h = 5 + random.nextInt(132);
    for (final c in [1, 3, 4]) {
      final stride = w * c + random.nextInt(19);
      final backing = Uint8List(7 + stride * h);
      final p = Uint8List.sublistView(backing, 7);
      for (var i = 0; i < p.length; i++) {
        p[i] = random.nextInt(256);
      }
      checkLuma(p, w, h, c, stride);
      final expected = calculates['baseline']!(p, w, h, c, stride);
      for (final entry in calculates.entries) {
        final result = entry.value(p, w, h, c, stride);
        if (result.hash != expected.hash ||
            result.quality != expected.quality) {
          throw StateError(
            '${entry.key}: randomized result mismatch trial $trial/$c',
          );
        }
      }
    }
  }
  // All 16,777,216 RGB triples, partitioned to limit peak memory.
  for (var r = 0; r < 256; r++) {
    final p = Uint8List(256 * 256 * 3);
    for (var g = 0; g < 256; g++) {
      for (var b = 0; b < 256; b++) {
        final i = (g * 256 + b) * 3;
        p[i] = r;
        p[i + 1] = g;
        p[i + 2] = b;
      }
    }
    checkLuma(p, 256, 256, 3, 256 * 3);
  }
  print(
    'Verified ${vectors.length} reference fixtures, 300 randomized '
    'padded/view images, and all 16,777,216 RGB triples for all variants.',
  );
}

double measure(void Function() operation, int iterations) {
  final watch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    operation();
  }
  return watch.elapsedMicroseconds / iterations / 1000;
}

void main(List<String> args) {
  if (args.contains('--verify')) {
    verify();
    return;
  }
  final samples = int.parse(Platform.environment['SAMPLES'] ?? '11');
  final warmupMs = int.parse(Platform.environment['WARMUP_MS'] ?? '500');
  final targetMs = int.parse(Platform.environment['SAMPLE_MS'] ?? '100');
  final names =
      (Platform.environment['VARIANTS'] ?? k.kernels.keys.join(',')).split(',');
  if (names.isEmpty || names.any((name) => !k.kernels.containsKey(name))) {
    throw ArgumentError.value(names, 'VARIANTS', 'Unknown benchmark variant');
  }
  final random = Random(913);
  print(
    'runtime,phase,width,height,channels,variant,n,median_ms,p10_ms,p90_ms,min_ms,max_ms',
  );
  for (final size in [(64, 64), (512, 512), (1920, 1080), (4000, 3000)]) {
    final (w, h) = size;
    for (final c in [3, 4]) {
      final p = Uint8List(w * h * c);
      for (var i = 0; i < p.length; i++) {
        p[i] = random.nextInt(256);
      }
      final output = Float32List(w * h);
      for (final phase in ['luma', 'calculate']) {
        final operations = <String, void Function()>{};
        for (final name in names) {
          if (phase == 'luma') {
            final kernel = k.kernels[name]!;
            operations[name] = () {
              kernel(p, w, h, w * c, c, output);
              sink ^= output[(sink & 0x7fffffff) % output.length].toInt();
            };
          } else {
            final calculate = calculates[name]!;
            operations[name] = () {
              final result = calculate(p, w, h, c, w * c);
              sink ^= result.quality ^ result.hash.hashCode;
            };
          }
        }
        final iterations = <String, int>{};
        final results = <String, List<double>>{};
        for (final entry in operations.entries) {
          final watch = Stopwatch()..start();
          do {
            entry.value();
          } while (watch.elapsedMilliseconds < warmupMs);
          final estimate = measure(entry.value, 3);
          iterations[entry.key] = max(
            1,
            (targetMs / max(estimate, 0.001)).ceil(),
          );
          results[entry.key] = [];
        }
        // Interleave shuffled variants to reduce order/thermal bias.
        for (var sample = 0; sample < samples; sample++) {
          final order = operations.keys.toList()..shuffle(random);
          for (final name in order) {
            results[name]!.add(measure(operations[name]!, iterations[name]!));
          }
        }
        for (final name in operations.keys) {
          final values = results[name]!..sort();
          final runtime = Platform.environment['RUNTIME'] ?? 'unknown';
          print(
            '$runtime,$phase,$w,$h,$c,$name,$samples,'
            '${values[samples ~/ 2]},${values[((samples - 1) * 0.1).round()]},'
            '${values[((samples - 1) * 0.9).round()]},${values.first},${values.last}',
          );
        }
      }
    }
  }
  stderr.writeln('sink=$sink');
}
