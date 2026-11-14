import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:imghash/imghash.dart';
import 'package:test/test.dart';

import '../example/image_helpers.dart';

void main() {
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
