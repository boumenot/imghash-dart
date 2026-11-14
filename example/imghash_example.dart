import 'dart:typed_data';

import 'package:imghash/imghash.dart';

void main() {
  final pixels = Uint8List(128 * 128 * 3);
  for (var y = 0; y < 128; y++) {
    for (var x = 0; x < 128; x++) {
      final offset = (y * 128 + x) * 3;
      pixels[offset] = x * 2;
      pixels[offset + 1] = y * 2;
      pixels[offset + 2] = (x + y) & 255;
    }
  }
  final result = const Pdq().calculate(
    pixels,
    width: 128,
    height: 128,
    format: PdqPixelFormat.rgb,
  );
  print('PDQ: ${result.hash}');
  print('Quality: ${result.quality}');
}
