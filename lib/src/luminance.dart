import 'dart:typed_data';

/// Converts a validated pixel buffer to reference-compatible luminance.
void computeLuminance(
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
    var out = 0;
    for (var y = 0; y < height; y++) {
      var offset = y * stride;
      final end = offset + width * channels;
      for (; offset < end; offset += channels) {
        // The intermediate sum must be rounded; the output store rounds the
        // final sum to float32.
        luma[out++] =
            _f32(_redLut[pixels[offset]] + _greenLut[pixels[offset + 1]]) +
                _blueLut[pixels[offset + 2]];
      }
    }
  }
}

final _rounding = Float32List(1);
double _f32(double value) {
  _rounding[0] = value;
  return _rounding[0];
}

final _red = _f32(0.299);
final _green = _f32(0.587);
final _blue = _f32(0.114);
final _redLut = Float32List.fromList(List.generate(256, (i) => _red * i));
final _greenLut = Float32List.fromList(List.generate(256, (i) => _green * i));
final _blueLut = Float32List.fromList(List.generate(256, (i) => _blue * i));
