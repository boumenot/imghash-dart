// Copyright (c) Meta Platforms, Inc. and affiliates.
// Dart adaptation of ThreatExchange PDQ; see LICENSE.

import 'dart:math' as math;
import 'dart:typed_data';

import 'pdq_hash.dart';

/// Channel layout of an unpacked, 8-bit pixel buffer.
enum PdqPixelFormat {
  /// One byte of luminance per pixel.
  grayscale(1),

  /// Red, green, blue; three bytes per pixel.
  rgb(3),

  /// Red, green, blue, alpha; four bytes per pixel.
  ///
  /// Alpha is ignored, matching Meta's RGB input. Supply straight
  /// (unpremultiplied) RGB, not premultiplied pixels.
  rgba(4);

  const PdqPixelFormat(this.channels);
  final int channels;
}

/// Meta's reference PDQ: luminance, Jarosz blur and decimation to 64x64,
/// DCT frequencies 1 through 16 on each axis, and lower-median thresholding.
///
/// This is synchronous CPU work. In Flutter, hash large buffers in an isolate.
/// Image decoding and EXIF orientation are the caller's responsibility.
final class Pdq {
  const Pdq();

  /// Hashes row-major 8-bit pixels without modifying [pixels].
  ///
  /// [rowStride] is the number of bytes between row starts; defaults to tightly
  /// packed rows. Trailing bytes and padding are ignored. Dimensions must be
  /// positive and the buffer must contain all pixels.
  ///
  /// As in Meta's reference, dimensions below 5 produce a zero hash and quality
  /// 0. Exactly 64x64 input bypasses blur and decimation.
  PdqResult calculate(
    Uint8List pixels, {
    required int width,
    required int height,
    PdqPixelFormat format = PdqPixelFormat.rgba,
    int? rowStride,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Width and height must be positive');
    }
    final rowBytes = width * format.channels;
    final stride = rowStride ?? rowBytes;
    if (stride < rowBytes) {
      throw ArgumentError.value(rowStride, 'rowStride', 'Row is too short');
    }
    final requiredBytes = (height - 1) * stride + rowBytes;
    if (pixels.length < requiredBytes) {
      throw ArgumentError.value(
        pixels.length,
        'pixels.length',
        'Expected at least $requiredBytes bytes',
      );
    }
    if (width < 5 || height < 5) {
      return PdqResult(PdqHash.fromBytes(List<int>.filled(32, 0)), 0);
    }

    final luma = Float32List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final offset = y * stride + x * format.channels;
        if (format == PdqPixelFormat.grayscale) {
          luma[y * width + x] = pixels[offset].toDouble();
        } else {
          luma[y * width + x] = _f32(
            _f32(_f32(_red * pixels[offset]) +
                    _f32(_green * pixels[offset + 1])) +
                _f32(_blue * pixels[offset + 2]),
          );
        }
      }
    }

    final small = Float32List(64 * 64);
    if (width == 64 && height == 64) {
      small.setAll(0, luma);
    } else {
      final scratch = Float32List(luma.length);
      final windowX = (width + 127) ~/ 128;
      final windowY = (height + 127) ~/ 128;
      for (var pass = 0; pass < 2; pass++) {
        for (var y = 0; y < height; y++) {
          _box(luma, scratch, y * width, width, 1, windowX);
        }
        for (var x = 0; x < width; x++) {
          _box(scratch, luma, x, height, width, windowY);
        }
      }
      for (var y = 0; y < 64; y++) {
        final sourceY = ((y + 0.5) * height / 64).toInt();
        for (var x = 0; x < 64; x++) {
          final sourceX = ((x + 0.5) * width / 64).toInt();
          small[y * 64 + x] = luma[sourceY * width + sourceX];
        }
      }
    }

    final quality = _quality(small);
    final coefficients = _dct(small);
    // Torben's median in the reference is the lower middle value, not the
    // average of the two middle values for an even-length collection.
    final sorted = coefficients.toList()..sort();
    final median = sorted[127];
    final bytes = Uint8List(32);
    for (var bit = 0; bit < 256; bit++) {
      if (coefficients[bit] > median) {
        bytes[31 - bit ~/ 8] |= 1 << (bit % 8);
      }
    }
    return PdqResult(PdqHash.fromBytes(bytes), quality);
  }
}

// Explicit float32 arithmetic preserves the reference's intermediate rounding.
// Each Dart isolate has its own scratch storage; calculate never yields.
final _rounding = Float32List(1);
double _f32(double value) {
  _rounding[0] = value;
  return _rounding[0];
}

final _red = _f32(0.299);
final _green = _f32(0.587);
final _blue = _f32(0.114);

void _box(
  Float32List input,
  Float32List output,
  int start,
  int length,
  int stride,
  int window,
) {
  final half = (window + 2) ~/ 2;
  var left = start;
  var right = start;
  var out = start;
  var sum = 0.0;
  var count = 0;
  for (var i = 0; i < half - 1; i++) {
    sum = _f32(sum + input[right]);
    count++;
    right += stride;
  }
  for (var i = 0; i < window - half + 1; i++) {
    sum = _f32(sum + input[right]);
    count++;
    output[out] = sum / count;
    right += stride;
    out += stride;
  }
  for (var i = 0; i < length - window; i++) {
    sum = _f32(sum + input[right]);
    sum = _f32(sum - input[left]);
    output[out] = sum / count;
    left += stride;
    right += stride;
    out += stride;
  }
  for (var i = 0; i < half - 1; i++) {
    sum = _f32(sum - input[left]);
    count--;
    output[out] = sum / count;
    left += stride;
    out += stride;
  }
}

int _quality(Float32List image) {
  var gradients = 0;
  int difference(double a, double b) =>
      _f32(_f32(_f32(a - b) * 100) / 255).toInt().abs();
  for (var y = 0; y < 63; y++) {
    for (var x = 0; x < 64; x++) {
      gradients += difference(image[y * 64 + x], image[(y + 1) * 64 + x]);
    }
  }
  for (var y = 0; y < 64; y++) {
    for (var x = 0; x < 63; x++) {
      gradients += difference(image[y * 64 + x], image[y * 64 + x + 1]);
    }
  }
  return math.min(100, gradients ~/ 90);
}

final _dctMatrix = () {
  final matrix = Float32List(16 * 64);
  final scale = _f32(math.sqrt(2.0 / 64));
  for (var i = 0; i < 16; i++) {
    for (var j = 0; j < 64; j++) {
      matrix[i * 64 + j] =
          scale * math.cos((math.pi / 2.0 / 64) * (i + 1) * (2 * j + 1));
    }
  }
  return matrix;
}();

Float32List _dct(Float32List image) {
  final intermediate = Float32List(16 * 64);
  final result = Float32List(16 * 16);
  for (var i = 0; i < 16; i++) {
    for (var j = 0; j < 64; j++) {
      var sum = 0.0;
      for (var k = 0; k < 64; k++) {
        sum = _f32(sum + _f32(_dctMatrix[i * 64 + k] * image[k * 64 + j]));
      }
      intermediate[i * 64 + j] = sum;
    }
  }
  for (var i = 0; i < 16; i++) {
    for (var j = 0; j < 16; j++) {
      var sum = 0.0;
      for (var k = 0; k < 64; k++) {
        sum = _f32(
          sum + _f32(intermediate[i * 64 + k] * _dctMatrix[j * 64 + k]),
        );
      }
      result[i * 16 + j] = sum;
    }
  }
  return result;
}
