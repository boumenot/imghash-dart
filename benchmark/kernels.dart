import 'dart:typed_data';

import '../lib/src/luminance.dart' as production;

typedef Kernel = void Function(
  Uint8List pixels,
  int width,
  int height,
  int stride,
  int channels,
  Float32List luma,
);

final rounding = Float32List(1);
double f32(double value) {
  rounding[0] = value;
  return rounding[0];
}

final red = f32(0.299);
final green = f32(0.587);
final blue = f32(0.114);
final redLut = Float32List.fromList(List.generate(256, (i) => red * i));
final greenLut = Float32List.fromList(List.generate(256, (i) => green * i));
final blueLut = Float32List.fromList(List.generate(256, (i) => blue * i));
final red4 = Float32x4.splat(red);
final green4 = Float32x4.splat(green);
final blue4 = Float32x4.splat(blue);

void baseline(
  Uint8List pixels,
  int width,
  int height,
  int stride,
  int channels,
  Float32List luma,
) {
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = y * stride + x * channels;
      if (channels == 1) {
        luma[y * width + x] = pixels[offset].toDouble();
      } else {
        luma[y * width + x] = f32(
          f32(f32(red * pixels[offset]) + f32(green * pixels[offset + 1])) +
              f32(blue * pixels[offset + 2]),
        );
      }
    }
  }
}

void lut(
  Uint8List pixels,
  int width,
  int height,
  int stride,
  int channels,
  Float32List luma,
) {
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = y * stride + x * channels;
      if (channels == 1) {
        luma[y * width + x] = pixels[offset].toDouble();
      } else {
        luma[y * width + x] = f32(
          f32(redLut[pixels[offset]] + greenLut[pixels[offset + 1]]) +
              blueLut[pixels[offset + 2]],
        );
      }
    }
  }
}

void store(
  Uint8List pixels,
  int width,
  int height,
  int stride,
  int channels,
  Float32List luma,
) {
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = y * stride + x * channels;
      if (channels == 1) {
        luma[y * width + x] = pixels[offset].toDouble();
      } else {
        luma[y * width + x] =
            f32(redLut[pixels[offset]] + greenLut[pixels[offset + 1]]) +
                blueLut[pixels[offset + 2]];
      }
    }
  }
}

void simd(
  Uint8List pixels,
  int width,
  int height,
  int stride,
  int channels,
  Float32List luma,
) {
  if (channels == 1) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        luma[y * width + x] = pixels[y * stride + x].toDouble();
      }
    }
  } else {
    final vectors = Float32x4List.view(
      luma.buffer,
      luma.offsetInBytes,
      luma.length ~/ 4,
    );
    var out = 0;
    for (var y = 0; y < height; y++) {
      var offset = y * stride;
      for (var x = 0; x < width; x++) {
        if (out % 4 == 0 && x + 3 < width) {
          final r = Float32x4(
            pixels[offset].toDouble(),
            pixels[offset + channels].toDouble(),
            pixels[offset + channels * 2].toDouble(),
            pixels[offset + channels * 3].toDouble(),
          );
          final g = Float32x4(
            pixels[offset + 1].toDouble(),
            pixels[offset + channels + 1].toDouble(),
            pixels[offset + channels * 2 + 1].toDouble(),
            pixels[offset + channels * 3 + 1].toDouble(),
          );
          final b = Float32x4(
            pixels[offset + 2].toDouble(),
            pixels[offset + channels + 2].toDouble(),
            pixels[offset + channels * 2 + 2].toDouble(),
            pixels[offset + channels * 3 + 2].toDouble(),
          );
          vectors[out ~/ 4] = (r * red4 + g * green4) + b * blue4;
          out += 4;
          offset += channels * 4;
          x += 3;
        } else {
          luma[out++] =
              f32(f32(red * pixels[offset]) + f32(green * pixels[offset + 1])) +
                  f32(blue * pixels[offset + 2]);
          offset += channels;
        }
      }
    }
  }
}

final kernels = <String, Kernel>{
  'baseline': baseline,
  'lut': lut,
  'store': store,
  'hoisted': production.computeLuminance,
  'simd': simd,
};
