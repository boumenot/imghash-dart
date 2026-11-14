import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:imghash/imghash.dart';
import 'package:test/test.dart';

import '../example/image_helpers.dart';

void expectFirstImage(Uint8List encoded) {
  final animation = img.decodeImage(encoded)!;
  expect(animation.numFrames, greaterThan(1));
  final selected = decodeFirstImage(encoded);
  expect(selected.numFrames, 1);
  expect(selected.width, animation.width);
  expect(selected.height, animation.height);
  expect(
    selected.getBytes(order: img.ChannelOrder.rgba),
    animation.getBytes(order: img.ChannelOrder.rgba),
  );
  final first = img.Image.from(animation, noAnimation: true);
  final oriented = img.bakeOrientation(first);
  final rgba = oriented.convert(format: img.Format.uint8, numChannels: 4);
  final expected = const Pdq().calculate(
    rgba.getBytes(order: img.ChannelOrder.rgba),
    width: rgba.width,
    height: rgba.height,
  );
  final actual = hashEncodedImage(encoded);
  expect(actual.hash, expected.hash);
  expect(actual.quality, expected.quality);
}

void main() {
  test('complete JPEGs hash from bytes and streams, including trailing padding',
      () async {
    final source = img.decodePng(demoImageBytes().first)!;
    final encoded = img.encodeJpg(source);
    final expected = hashEncodedImage(encoded);
    expect(expected.quality, greaterThan(49));
    final padded = Uint8List.fromList([...encoded, 0, 0, 0]);
    final actual = hashEncodedImage(padded);
    expect(actual.hash, expected.hash);
    expect(actual.quality, expected.quality);
    final streamed = await hashImageStream(
      Stream<List<int>>.fromIterable(
          [padded.sublist(0, 17), padded.sublist(17)]),
    );
    expect(streamed.hash, expected.hash);
    expect(streamed.quality, expected.quality);
  });

  for (final percent in [50, 90]) {
    test(
        'truncated JPEG prefix at $percent% is rejected from bytes and streams',
        () async {
      final encoded = img.encodeJpg(img.decodePng(demoImageBytes().first)!);
      final truncated = Uint8List.sublistView(
        encoded,
        0,
        encoded.length * percent ~/ 100,
      );
      final partial = img.decodeJpg(truncated)!;
      final tolerantResult = const Pdq().calculate(
        partial.getBytes(order: img.ChannelOrder.rgba),
        width: partial.width,
        height: partial.height,
      );
      expect(tolerantResult.quality, greaterThan(49));
      expect(() => hashEncodedImage(truncated), throwsFormatException);
      await expectLater(
        hashImageStream(Stream<List<int>>.fromIterable([
          truncated.sublist(0, 17),
          truncated.sublist(17),
        ])),
        throwsFormatException,
      );
    });
  }

  test('EOI bytes inside JPEG metadata do not satisfy image termination', () {
    final encoded = img.encodeJpg(img.decodePng(demoImageBytes().first)!);
    // APP15 payload with FF D9, like an embedded thumbnail's end marker.
    final withMetadata = Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      0xef,
      0,
      4,
      0xff,
      0xd9,
      ...encoded.sublist(2),
    ]);
    final expected = hashEncodedImage(encoded);
    expect(hashEncodedImage(withMetadata).hash, expected.hash);
    expect(
      () => hashEncodedImage(
        Uint8List.sublistView(withMetadata, 0, withMetadata.length - 2),
      ),
      throwsFormatException,
    );
  });

  for (final transparent in [false, true]) {
    test('GIF first patch retains logical canvas (transparent: $transparent)',
        () {
      final palette = img.PaletteUint8(256, 4);
      for (var i = 0; i < palette.numColors; i++) {
        palette.setRgba(i, 0, 0, 0, 255);
      }
      palette
        ..setRgba(0, 10, 20, 30, transparent ? 0 : 255)
        ..setRgba(1, 220, 110, 60, 255);
      final first = img.Image(
        width: 8,
        height: 6,
        numChannels: 1,
        palette: palette,
      );
      for (final pixel in first) {
        pixel.index = (pixel.x + pixel.y) % 2;
      }
      first.addFrame(img.Image.from(first, noAnimation: true));
      final encoded = img.encodeGif(first);
      // Expand the logical screen and position the first encoded patch.
      final header = ByteData.sublistView(encoded);
      header.setUint16(6, 20, Endian.little);
      header.setUint16(8, 18, Endian.little);
      final descriptor = encoded.indexOf(0x2c, 13);
      expect(descriptor, greaterThan(0));
      header.setUint16(descriptor + 1, 4, Endian.little);
      header.setUint16(descriptor + 3, 2, Endian.little);
      expectFirstImage(encoded);
      final selected = decodeFirstImage(encoded);
      expect(selected.getPixel(0, 0).a, transparent ? 0 : 255);
      expect(selected.getPixel(5, 2).r, 220);
    });
  }

  for (final blend in [false, true]) {
    test('WebP first patch retains logical canvas (blend: $blend)', () {
      final first = img.Image(width: 8, height: 6, numChannels: 4);
      for (final pixel in first) {
        pixel.setRgba(pixel.x * 30, pixel.y * 40, 100, (pixel.x % 3) * 127);
      }
      first.exif.imageIfd.orientation = 6;
      first.backgroundColor = img.ColorRgba8(255, 0, 0, 255);
      first.addFrame(img.Image.from(first, noAnimation: true));
      final encoded = img.encodeWebP(first);
      final data = ByteData.sublistView(encoded);
      var changedFrame = false;
      for (var offset = 12; offset < encoded.length;) {
        final type = String.fromCharCodes(encoded.sublist(offset, offset + 4));
        final size = data.getUint32(offset + 4, Endian.little);
        final payload = offset + 8;
        if (type == 'VP8X') {
          encoded[payload + 4] = 23; // 24x18 canvas, dimensions minus one.
          encoded[payload + 7] = 17;
        } else if (type == 'ANMF' && !changedFrame) {
          encoded[payload] = 2; // Stored coordinates are halved: (4, 2).
          encoded[payload + 3] = 1;
          encoded[payload + 15] = blend ? 0 : 2;
          changedFrame = true;
        }
        offset += 8 + size + (size & 1);
      }
      expect(changedFrame, isTrue);
      expectFirstImage(encoded);
      final selected = decodeFirstImage(encoded);
      expect(selected.getPixel(0, 0).a, 0);
      expect(selected.exif.imageIfd.orientation, 6);
    });
  }

  test('APNG selects only its default IDAT image', () {
    final first = img.decodePng(demoImageBytes().first)!;
    first.addFrame(img.copyRotate(first, angle: 180));
    expectFirstImage(img.encodePng(first));
  });

  test('ICO selects entry zero without decoding a corrupt later entry', () {
    final first = img.copyCrop(
      img.decodePng(demoImageBytes().first)!,
      x: 0,
      y: 0,
      width: 32,
      height: 24,
    );
    final encoded = img.IcoEncoder().encodeImages([
      first,
      img.decodePng(demoImageBytes().first)!,
    ]);
    expectFirstImage(encoded);
    final data = ByteData.sublistView(encoded);
    final secondOffset = data.getUint32(6 + 16 + 12, Endian.little);
    // Corrupt the second entry's IDAT checksum while keeping its PNG header.
    for (var offset = secondOffset + 8; offset < encoded.length;) {
      final size = data.getUint32(offset, Endian.big);
      final type =
          String.fromCharCodes(encoded.sublist(offset + 4, offset + 8));
      if (type == 'IDAT') {
        encoded[offset + 8 + size] ^= 1;
        break;
      }
      offset += 12 + size;
    }
    expect(() => img.decodeIco(encoded), throwsA(isA<img.ImageException>()));
    final actual = hashEncodedImage(encoded);
    final expected = hashEncodedImage(img.encodePng(first));
    expect(actual.hash, expected.hash);
    expect(actual.quality, expected.quality);
    expect(decodeFirstImage(encoded).width, 32);
  });

  test('encoded images and arbitrarily chunked streams hash the same pixels',
      () async {
    final demo = demoImageBytes();
    final expected = hashEncodedImage(demo.first);
    final streamed = await hashImageStream(Stream<List<int>>.fromIterable([
      [],
      demo.second.sublist(0, 1),
      demo.second.sublist(1, 13),
      demo.second.sublist(13),
      [],
    ]));
    expect(streamed.hash, expected.hash);
    expect(streamed.quality, expected.quality);
    expect(expected.quality, greaterThan(49));
    expect(comparisonVerdict(expected, streamed), startsWith('Match:'));
  });

  test('stream chunks are snapshotted when the producer reuses its buffer',
      () async {
    final encoded = demoImageBytes().first;
    final expected = hashEncodedImage(encoded);

    Stream<List<int>> reusedChunks() async* {
      final scratch = Uint8List(1024);
      for (var offset = 0; offset < encoded.length; offset += scratch.length) {
        final end = offset + scratch.length < encoded.length
            ? offset + scratch.length
            : encoded.length;
        scratch.setRange(0, end - offset, encoded, offset);
        yield Uint8List.sublistView(scratch, 0, end - offset);
      }
      scratch.fillRange(0, scratch.length, 0);
    }

    final actual = await hashImageStream(reusedChunks());
    expect(actual.hash, expected.hash);
    expect(actual.quality, expected.quality);
  });

  test('EXIF orientation is applied before hashing JPEG pixels', () {
    final source = img.decodePng(demoImageBytes().first)!;
    final cropped = img.copyCrop(source, x: 0, y: 0, width: 97, height: 73);
    final decoded = img.decodeJpg(img.encodeJpg(cropped))!;
    cropped.exif.imageIfd.orientation = 6;
    final encoded = img.encodeJpg(cropped);
    // Some decoders already bake EXIF during decode; compare against a JPEG
    // without orientation metadata, rotated explicitly, to avoid double baking.
    final rotated = img.copyRotate(decoded, angle: 90);
    final expected = const Pdq().calculate(
      rotated.getBytes(order: img.ChannelOrder.rgba),
      width: rotated.width,
      height: rotated.height,
    );
    final unrotated = const Pdq().calculate(
      decoded.getBytes(order: img.ChannelOrder.rgba),
      width: decoded.width,
      height: decoded.height,
    );
    expect(expected.hash, isNot(unrotated.hash));
    final actual = hashEncodedImage(encoded);
    expect(actual.hash, expected.hash);
    expect(actual.quality, expected.quality);
  });

  test('PNG decoding retains straight RGB even with transparent alpha', () {
    final source = img.decodePng(demoImageBytes().first)!;
    for (final pixel in source) {
      pixel.a = (pixel.x + pixel.y) & 255;
    }
    final expected = const Pdq().calculate(
      source.getBytes(order: img.ChannelOrder.rgba),
      width: source.width,
      height: source.height,
    );
    final actual = hashEncodedImage(img.encodePng(source));
    expect(actual.hash, expected.hash);
    expect(actual.quality, expected.quality);
  });

  test('16-bit grayscale PNG is converted to 8-bit RGBA at original resolution',
      () {
    const width = 97;
    const height = 73;
    final source = img.Image(
      width: width,
      height: height,
      format: img.Format.uint16,
      numChannels: 1,
    );
    final gray = Uint8List(width * height);
    for (final pixel in source) {
      final value = (pixel.x * 17 + pixel.y * 31 + pixel.x * pixel.y * 7) & 255;
      gray[pixel.y * width + pixel.x] = value;
      pixel.r = value * 257;
    }
    final expected = const Pdq().calculate(
      gray,
      width: width,
      height: height,
      format: PdqPixelFormat.grayscale,
    );
    final actual = hashEncodedImage(img.encodePng(source));
    expect(actual.hash, expected.hash);
    expect(actual.quality, expected.quality);
  });

  test('invalid images and stream failures propagate explicitly', () async {
    expect(
      () => hashEncodedImage(Uint8List(0)),
      throwsFormatException,
    );
    expect(
      () => hashEncodedImage(Uint8List.fromList([1, 2, 3, 4])),
      throwsFormatException,
    );
    await expectLater(
      hashImageStream(Stream<List<int>>.empty()),
      throwsFormatException,
    );
    final error = StateError('stream interrupted');
    await expectLater(
      hashImageStream(Stream<List<int>>.error(error)),
      throwsA(same(error)),
    );
  });

  test('quality filtering precedes inclusive distance matching', () {
    final zero = PdqHash.fromBytes(List<int>.filled(32, 0));
    final at31 = PdqHash.fromBytes([127, 255, 255, 255, ...List.filled(28, 0)]);
    final at32 = PdqHash.fromBytes([255, 255, 255, 255, ...List.filled(28, 0)]);
    final first = PdqResult(zero, 50);
    expect(
      comparisonVerdict(first, PdqResult(at31, 50)),
      startsWith('Match:'),
    );
    expect(
      comparisonVerdict(first, PdqResult(at32, 50)),
      startsWith('No match:'),
    );
    expect(
      comparisonVerdict(PdqResult(zero, 49), first),
      startsWith('Discard:'),
    );
    expect(
      comparisonVerdict(first, PdqResult(zero, 49)),
      startsWith('Discard:'),
    );
  });

  test('both entry points compare explicit file paths and reject bad arguments',
      () async {
    final directory = await Directory.systemTemp.createTemp('imghash-test-');
    try {
      final demo = demoImageBytes();
      final first = File('${directory.path}/first image.png');
      final second = File('${directory.path}/second image.bmp');
      await first.writeAsBytes(demo.first);
      await second.writeAsBytes(demo.second);
      for (final example in ['file_images', 'stream_images']) {
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          'example/$example.dart',
          first.path,
          second.path,
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout, contains('Hamming distance: 0'));
        expect(result.stdout, contains('Match: Hamming distance <= 31'));
        final invalid = await Process.run(Platform.resolvedExecutable, [
          'run',
          'example/$example.dart',
          first.path,
        ]);
        expect(invalid.exitCode, isNot(0));
        expect(invalid.stderr, contains('Usage:'));
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
