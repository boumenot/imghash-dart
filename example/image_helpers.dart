import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:imghash/imghash.dart';

PdqResult hashEncodedImage(Uint8List encodedBytes) {
  final decoded = img.decodeImage(encodedBytes);
  if (decoded == null) {
    throw FormatException('Unsupported or invalid encoded image');
  }
  // PDQ expects original-resolution, straight (not premultiplied) 8-bit pixels.
  final oriented = img.bakeOrientation(decoded);
  final rgba = oriented.convert(format: img.Format.uint8, numChannels: 4);
  return const Pdq().calculate(
    rgba.getBytes(order: img.ChannelOrder.rgba),
    width: rgba.width,
    height: rgba.height,
  );
}

Future<PdqResult> hashImageStream(Stream<List<int>> encodedChunks) async {
  // Encoded chunks are not pixel rows. Buffer the complete file before decoding.
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in encodedChunks) {
    bytes.add(chunk);
  }
  return hashEncodedImage(bytes.takeBytes());
}

String comparisonVerdict(PdqResult first, PdqResult second) {
  if (first.quality <= 49 || second.quality <= 49) {
    return 'Discard: at least one image has quality <= 49';
  }
  return first.hash.hammingDistance(second.hash) <= 31
      ? 'Match: Hamming distance <= 31'
      : 'No match: Hamming distance > 31';
}

void printComparison(PdqResult first, PdqResult second) {
  print('First PDQ: ${first.hash} (quality ${first.quality})');
  print('Second PDQ: ${second.hash} (quality ${second.quality})');
  print('Hamming distance: ${first.hash.hammingDistance(second.hash)}');
  print(comparisonVerdict(first, second));
}

// Two losslessly encoded versions of the same detailed image, no downloads.
({Uint8List first, Uint8List second}) demoImageBytes() {
  final image = img.Image(width: 128, height: 128, numChannels: 4);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgba(
        x,
        y,
        (x * 17 + y * 31 + x * y * 7) & 255,
        (x * 28 + y * 34 + x * y * 7 + 53) & 255,
        (x * 39 + y * 37 + x * y * 7 + 106) & 255,
        255,
      );
    }
  }
  return (
    first: img.encodePng(image),
    second: img.encodeBmp(image),
  );
}
