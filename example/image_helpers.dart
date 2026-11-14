import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:imghash/imghash.dart';

PdqResult hashEncodedImage(Uint8List encodedBytes) {
  final decoded = decodeFirstImage(encodedBytes);
  // PDQ expects original-resolution, straight (not premultiplied) 8-bit pixels.
  final oriented = img.bakeOrientation(decoded);
  final rgba = oriented.convert(format: img.Format.uint8, numChannels: 4);
  return const Pdq().calculate(
    rgba.getBytes(order: img.ChannelOrder.rgba),
    width: rgba.width,
    height: rgba.height,
  );
}

img.Image decodeFirstImage(Uint8List encodedBytes) {
  final decoder = img.findDecoderForData(encodedBytes);
  final img.Image? decoded;
  if (decoder is img.GifDecoder) {
    final info = decoder.startDecode(encodedBytes);
    final patch = info == null ? null : decoder.decodeFrame(0);
    decoded =
        info == null || patch == null ? null : _firstGifCanvas(patch, info);
  } else if (decoder is img.WebPDecoder) {
    final info = decoder.startDecode(encodedBytes);
    final patch = info == null ? null : decoder.decodeFrame(0);
    if (info == null || patch == null) {
      decoded = null;
    } else if (!info.hasAnimation) {
      decoded = patch;
    } else {
      // WebP starts with a zeroed canvas, not the ANIM background color.
      final canvas = img.Image(
        width: info.width,
        height: info.height,
        numChannels: patch.numChannels,
        format: patch.format,
        exif: info.exif.isEmpty
            ? null
            : img.ExifData.fromInputBuffer(
                img.InputBuffer(info.exif.codeUnits)),
      );
      final frame = info.frames.first;
      decoded = img.compositeImage(
        canvas,
        patch,
        dstX: frame.x,
        dstY: frame.y,
        blend: frame.blendFrame ? img.BlendMode.alpha : img.BlendMode.direct,
      );
    }
  } else {
    // Includes ICO entry zero and PNG's IDAT/default image.
    decoded = decoder?.decode(encodedBytes, frame: 0);
  }
  if (decoded == null) {
    throw FormatException('Unsupported or invalid first image');
  }
  return decoded;
}

img.Image _firstGifCanvas(img.Image patch, img.GifInfo info) {
  final palette = patch.palette!;
  var clearIndex = 0;
  num? closestDistance;
  final global = info.globalColorMap;
  final background = info.backgroundColor?.r.toInt() ?? 0;
  // Match the decoder's canvas policy: first transparent palette entry, or
  // the nearest opaque color to the global background in this local palette.
  for (var i = 0; i < palette.numColors; i++) {
    if (palette.getAlpha(i) == 0) {
      clearIndex = i;
      break;
    }
    if (global != null && background < global.numColors) {
      final dr = palette.getRed(i) - global.red(background);
      final dg = palette.getGreen(i) - global.green(background);
      final db = palette.getBlue(i) - global.blue(background);
      final distance = dr * dr + dg * dg + db * db;
      if (closestDistance == null || distance < closestDistance) {
        clearIndex = i;
        closestDistance = distance;
      }
    }
  }
  final canvas = img.Image(
    width: info.width,
    height: info.height,
    numChannels: 1,
    palette: palette,
  );
  final pixels = canvas.toUint8List()
    ..fillRange(0, info.width * info.height, clearIndex);
  final frame = info.frames.first;
  for (final pixel in patch) {
    if (pixel.a != 0) {
      pixels[(pixel.y + frame.y) * info.width + pixel.x + frame.x] =
          pixel.index.toInt();
    }
  }
  return canvas;
}

Future<PdqResult> hashImageStream(Stream<List<int>> encodedChunks) async {
  // Encoded chunks are not pixel rows. Buffer the complete file before decoding.
  // Snapshot each chunk because producers may reuse their buffers.
  final bytes = BytesBuilder();
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
