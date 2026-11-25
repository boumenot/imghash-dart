import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:imghash/imghash.dart';
import 'package:imghash/src/luminance.dart';
import 'package:test/test.dart';

Uint8List fixturePixels(int width, int height, int mode) {
  final channels = mode == 0 ? 1 : 3;
  final pixels = Uint8List(width * height * channels);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      for (var c = 0; c < channels; c++) {
        final int value;
        if (mode == 2) {
          value = 127;
        } else if (mode == 3) {
          value = ((x ~/ 3 + y ~/ 5) % 2) * 255;
        } else {
          value =
              (x * 17 + y * 31 + x * y * 7 + c * 53 + c * x * 11 + c * y * 3) &
                  255;
        }
        pixels[(y * width + x) * channels + c] = value;
      }
    }
  }
  return pixels;
}

void main() {
  const pdq = Pdq();
  final vectors =
      jsonDecode(File('test/fixtures/meta_vectors.json').readAsStringSync())
          as List<Object?>;
  group('Meta C++ reference compatibility', () {
    for (final entry in vectors) {
      final vector = entry as Map<String, Object?>;
      final width = vector['width'] as int;
      final height = vector['height'] as int;
      final mode = vector['mode'] as int;
      test('$width x $height, mode $mode', () {
        final pixels = fixturePixels(width, height, mode);
        final original = Uint8List.fromList(pixels);
        final result = pdq.calculate(
          pixels,
          width: width,
          height: height,
          format: mode == 0 ? PdqPixelFormat.grayscale : PdqPixelFormat.rgb,
        );
        expect(result.hash.toHex(), vector['hash']);
        expect(result.quality, vector['quality']);
        expect(pixels, original);
      });
    }
  });

  test('RGB and RGBA luminance preserves reference float32 rounding', () {
    const colors = <(int, int, int, int)>[
      (0, 0, 0, 0x00000000),
      (255, 255, 255, 0x437f0000),
      (255, 0, 0, 0x42987d70),
      (0, 255, 0, 0x4315af5c),
      (0, 0, 255, 0x41e88f5c),
      (1, 1, 1, 0x3f800000),
      (15, 91, 222, 0x42a66b85),
      (250, 100, 5, 0x4306051f),
      (128, 128, 129, 0x43001d2f),
      (3, 47, 251, 0x42646666),
      (37, 173, 29, 0x42e7d70a),
      (254, 1, 127, 0x42b605a1),
    ];
    const width = 6;
    const height = 2;
    for (final channels in [3, 4]) {
      final stride = width * channels + 5;
      final backing = Uint8List(7 + (height - 1) * stride + width * channels);
      backing.fillRange(0, backing.length, 0xcc);
      final pixels = Uint8List.sublistView(backing, 7);
      for (var i = 0; i < colors.length; i++) {
        final offset = (i ~/ width) * stride + (i % width) * channels;
        pixels[offset] = colors[i].$1;
        pixels[offset + 1] = colors[i].$2;
        pixels[offset + 2] = colors[i].$3;
        if (channels == 4) pixels[offset + 3] = i * 19;
      }
      final actual = Float32List(width * height);
      computeLuminance(pixels, width, height, stride, channels, actual);
      expect(
          actual.buffer.asUint32List(), [for (final color in colors) color.$4]);
    }
  });

  test('RGBA ignores alpha and respects row stride and buffer views', () {
    const width = 129;
    const height = 67;
    const stride = width * 4 + 13;
    final rgb = fixturePixels(width, height, 1);
    final expected = pdq.calculate(
      rgb,
      width: width,
      height: height,
      format: PdqPixelFormat.rgb,
    );
    final backing = Uint8List((height - 1) * stride + width * 4 + 7);
    final rgba = Uint8List.sublistView(backing, 7);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        for (var c = 0; c < 3; c++) {
          rgba[y * stride + x * 4 + c] = rgb[(y * width + x) * 3 + c];
        }
        rgba[y * stride + x * 4 + 3] = (x + y) & 255;
      }
    }
    final actual = pdq.calculate(
      rgba,
      width: width,
      height: height,
      rowStride: stride,
    );
    expect(actual.hash, expected.hash);
    expect(actual.quality, expected.quality);
  });

  test('grayscale padding and trailing bytes are ignored', () {
    const width = 19;
    const height = 21;
    const stride = width + 4;
    final gray = fixturePixels(width, height, 0);
    final padded = Uint8List(stride * height + 5)
      ..fillRange(0, stride * height + 5, 255);
    for (var y = 0; y < height; y++) {
      padded.setRange(y * stride, y * stride + width, gray, y * width);
    }
    final packed = pdq.calculate(
      gray,
      width: width,
      height: height,
      format: PdqPixelFormat.grayscale,
    );
    final actual = pdq.calculate(
      padded,
      width: width,
      height: height,
      format: PdqPixelFormat.grayscale,
      rowStride: stride,
    );
    expect(actual.hash, packed.hash);
    expect(actual.quality, packed.quality);
  });

  test('invalid dimensions, stride and truncated buffers fail explicitly', () {
    for (final dimensions in [(0, 10), (10, 0), (-1, 10), (10, -1)]) {
      expect(
        () => pdq.calculate(
          Uint8List(400),
          width: dimensions.$1,
          height: dimensions.$2,
        ),
        throwsArgumentError,
      );
    }
    for (final stride in [-1, 0, 39]) {
      expect(
        () => pdq.calculate(
          Uint8List(400),
          width: 10,
          height: 10,
          rowStride: stride,
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => pdq.calculate(Uint8List(399), width: 10, height: 10),
      throwsArgumentError,
    );
    // The reference's tiny-image sentinel must not hide invalid input.
    expect(
      () => pdq.calculate(Uint8List(0), width: 1, height: 1),
      throwsArgumentError,
    );
  });

  test('a valid tiny image returns the reference sentinel', () {
    final result = pdq.calculate(Uint8List(4), width: 1, height: 1);
    expect(result.hash.toHex(), '0' * 64);
    expect(result.quality, 0);
  });

  test('Hamming distance, canonical byte order and immutable storage', () {
    final zero = PdqHash.fromHex('0' * 64);
    final all = PdqHash.fromHex('f' * 64);
    final bytes = Uint8List(32);
    bytes[0] = 0x80;
    bytes[31] = 0x01;
    final hash = PdqHash.fromBytes(bytes);
    bytes.fillRange(0, 32, 0);
    hash.toBytes().fillRange(0, 32, 0);
    expect(hash.toHex(), '80${'0' * 60}01');
    expect(hash.hammingDistance(zero), 2);
    expect(zero.hammingDistance(all), 256);
    expect(all.hammingDistance(zero), 256);
    final parsed = PdqHash.fromHex(hash.toHex().toUpperCase());
    expect(parsed, hash);
    expect(parsed.hashCode, hash.hashCode);
    expect({hash, parsed}.length, 1);
    expect(hash.hammingDistance(hash), 0);
  });

  test('rejects malformed serialized hashes', () {
    for (final text in [
      '',
      '0' * 63,
      '0' * 65,
      'g' * 64,
      ' ${'0' * 64}',
      '${'0' * 64}\n',
      '0x${'0' * 64}',
    ]) {
      expect(() => PdqHash.fromHex(text), throwsFormatException);
    }
    expect(
        () => PdqHash.fromBytes(List<int>.filled(31, 0)), throwsArgumentError);
    for (final value in [-1, 256]) {
      final invalid = List<int>.filled(32, 0)..[0] = value;
      expect(() => PdqHash.fromBytes(invalid), throwsArgumentError);
    }
  });
}
