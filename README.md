# imghash

Pure Dart implementation of **Meta's reference PDQ** for Flutter and Dart.
The runtime has no package dependencies, FFI, native plugins, `dart:io`, or
`dart:ui` imports.

The initial source investigated was [ajdnik/imghash](https://github.com/ajdnik/imghash).
Its PDQ variant is **not** the algorithm implemented here. This port follows
[Meta ThreatExchange](https://github.com/facebook/ThreatExchange/tree/c91e539d0654fae57e553160c15060dfa10cddb8/pdq),
pinned to `c91e539d0654fae57e553160c15060dfa10cddb8`, under the BSD license
retained in `LICENSE`.

## Use

Add a local dependency in your Flutter project's `pubspec.yaml`, pointing to
the directory containing this package:

```yaml
dependencies:
  imghash:
    path: /path/to/imghash
```

```dart
import 'package:imghash/imghash.dart';

final result = const Pdq().calculate(
  rgbaBytes, // Uint8List of decoded, straight-alpha RGBA pixels
  width: width,
  height: height,
);
print(result.hash.toHex()); // 64 lowercase hexadecimal digits
print(result.quality);      // 0..100

final stored = PdqHash.fromHex(storedHex);
final distance = result.hash.hammingDistance(stored); // 0..256
```

`PdqPixelFormat.rgb` and `.grayscale` accept three-byte RGB and one-byte
luminance pixels respectively. `rowStride` supports row padding; buffers can
also be `Uint8List` views. The input is never modified.

Hash bytes use **canonical big-endian hexadecimal order**, matching Meta's
`Hash256.format()`. `toBytes()` returns a copy. They are not a dump of Meta's
native little-endian 16-bit word array.

## Encoded images: files, bytes, and streams

JPEG/PNG bytes are **encoded images**, not the decoded pixel buffers accepted
by `Pdq.calculate`. These runnable examples use `package:image` to decode,
apply EXIF orientation, and extract straight 8-bit RGBA pixels at original
resolution before hashing and comparing two images:

```sh
dart pub get
# No arguments: generate and compare PNG/BMP versions of the same image.
dart run example/file_images.dart
dart run example/stream_images.dart
# Your own files (any format supported by package:image):
dart run example/file_images.dart first.jpg second.png
dart run example/stream_images.dart first.jpg second.png
```

- [`file_images.dart`](example/file_images.dart) reads files with
  `File.readAsBytes()`. Its generated demo files are deleted afterward.
- [`stream_images.dart`](example/stream_images.dart) demonstrates in-memory
  encoded `Uint8List` data and a chunked `Stream<List<int>>`; with paths, it
  uses `File.openRead()`. HTTP response streams or `stdin` can be passed to
  the same `hashImageStream` helper.
- [`image_helpers.dart`](example/image_helpers.dart) shares decoding and
  comparison logic. It prints hashes, quality scores, and Hamming distance,
  discards either image with quality <= 49, then treats distance <= 31 as a
  suggested match. Tune these thresholds for your application.

The decoder is a **dev dependency only**; the core runtime remains
dependency-free. To reuse these helpers in your application, add `image` to
that application's dependencies. The stream example buffers the entire encoded
image before decoding; it is not incremental decoding or constant-memory
hashing. Bound input sizes for untrusted data. Unsupported images, decoder
failures, and file/stream errors propagate to the caller instead of returning
a fallback hash. However, decoders can tolerate malformed or incomplete files,
so a successful decode does **not** guarantee image integrity.

JPEG inputs (identified by SOI `FF D8`) must contain a complete end-of-image
marker (`FF D9`) before they are decoded. The check skips marker-segment
payloads, so an EXIF thumbnail's EOI cannot substitute for the main image's
termination, and allows bytes after the main EOI (such as trailing padding).
Missing termination throws `FormatException`, preventing a truncated JPEG
from becoming a plausible high-quality hash through the decoder's tolerant
partial decoding. EOI presence does **not** prove that all image data is intact;
other formats still rely on the decoder's validation.

A stream ending normally does not prove a complete download. Before hashing
downloaded bytes, verify the expected byte count (for example, an HTTP
`Content-Length` when available and applicable to the delivered bytes); use a
trusted checksum when integrity matters. The helpers do not fetch URLs or
validate transport metadata.

Only the selected first image is decoded, oriented, converted, and hashed;
later animation frames and ICO entries are not pixel-decoded or converted.
GIF and animated WebP frame zero are placed on the logical canvas using the
decoder's background, transparency, offset, and blending policy, rather than
hashing a cropped frame patch. Disposal affects subsequent frames, not this
first displayed canvas. ICO uses **directory entry zero**, not the largest
entry, preserving the example's original selection for valid files. A corrupt
selected image is an error; the helper does not fall back to later frames.

PNG/APNG uses the decoder's **IDAT/default image**. If an APNG has a separate
static preview excluded from its animation, that preview is hashed:
`package:image` 4.13.0 does not expose that animation's first FDAT image through
its frame-zero API. Container parsing can still scan later frame metadata and
retain compressed data; selective decoding is not constant-memory streaming.
Only the first image is compared, so identical first images do not imply
identical animations or icon sets. Alpha is ignored by PDQ, not composited
onto an application-chosen background.

## Flutter

Decode images using your application's existing decoder. Apply EXIF orientation
before hashing and always use the same orientation/color conversion policy.
Pass original-resolution pixels: resizing beforehand changes the algorithm.

For a decoded `dart:ui.Image`, request `rawStraightRgba`, **not** the
premultiplied `rawRgba` format. Alpha is ignored, matching the reference RGB
API; transparent RGB values are not composited onto a background. If your
application wants compositing, perform it explicitly and consistently first.

This example runs hashing off the UI isolate on native Flutter platforms:

```dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:imghash/imghash.dart';

typedef HashInput = ({Uint8List pixels, int width, int height});

PdqResult hashPixels(HashInput input) => const Pdq().calculate(
  input.pixels,
  width: input.width,
  height: input.height,
);

Future<PdqResult> hashImage(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  if (data == null) {
    throw StateError('Unable to read decoded image pixels');
  }
  return compute(hashPixels, (
    pixels: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    width: image.width,
    height: image.height,
  ));
}
```

The caller owns and disposes the `ui.Image`. Flutter's `compute` runs on the
current event loop on web, not a background isolate. The core itself works on
web as well, but large images require an appropriate worker strategy there.

## Algorithm and matching

The pipeline preserves reference float32 arithmetic:

1. Convert RGB to luminance (`0.299 R + 0.587 G + 0.114 B`).
2. Apply two alternating horizontal/vertical Jarosz box-filter passes at
   original resolution, with windows `ceil(dimension / 128)`, then sample
   pixel centers into a 64x64 buffer. Exactly 64x64 input bypasses this step.
3. Compute the quality score from quantized horizontal and vertical gradients.
4. Compute DCT frequencies **1..16** on both axes, excluding DC, and threshold
   the 256 coefficients strictly above their lower median.

Images with either dimension below 5 return a zero hash and quality 0, as in
the reference. Invalid dimensions, short buffers, malformed hashes and invalid
strides throw rather than returning plausible hashes.

Lower Hamming distance means greater similarity, not an identity guarantee.
Filter low-quality images before matching and calibrate distance/quality
thresholds for your corpus; uniform images can have numerical-noise-driven
hashes despite quality 0. Different image decoders, color management, orientation,
or floating-point implementations can affect borderline bits. Do not compare
these hashes with ajdnik's different PDQ variant.

Meta's [PDQ guidance](https://github.com/facebook/ThreatExchange/blob/c91e539d0654fae57e553160c15060dfa10cddb8/pdq/README.md)
suggests starting with Hamming distance **at most 31** for a match and
discarding hashes with quality **at most 49**. These are starting points, not
universal thresholds; tune them against the images and error costs of your
application.

### Matching options to consider later

- **Dihedral hashes:** Meta's implementation can hash eight image
  orientations (four rotations and their flips). Comparing the minimum Hamming
  distance across those variants can help with rotated or mirrored images.
  This Dart package currently computes only the original orientation; exact
  rotational invariance is not guaranteed by PDQ.
- **PDQF:** A related approach retains the 256 DCT coefficients as floating-point
  values instead of thresholding them into a standard PDQ hash. Euclidean or
  cosine distance are possible comparison choices, but require a separate
  representation and matching calibration; these values are not interchangeable
  with PDQ hashes.
- **Large-scale search:** Multi-index hashing and binary-vector indexes can
  speed up finding nearby hashes in a large collection while retaining Hamming
  distance as the metric.

Memory usage is O(width * height): for non-64x64 input, two float32 image buffers
use about 8 bytes per pixel, in addition to the caller's decoded pixels.

## Development and reference verification

```sh
dart pub get
dart analyze
dart test
dart run example/imghash_example.dart
```

`test/fixtures/meta_vectors.json` contains 44 deterministic fixtures generated
by the **unmodified C++ reference**, not the Dart implementation. Tests require
exact equality for canonical hash strings and quality scores. They cover
grayscale/color, uniform/checkerboard patterns, tiny images, the 64x64 fast path,
non-square images, and window-size boundaries.

To regenerate them, obtain the pinned ThreatExchange checkout and set `META`
to its root directory. Only the `pdq/cpp/common` headers, `pdqhashing.{h,cpp}`,
`torben.{h,cpp}`, and `downscaling.{h,cpp}` are needed:

```sh
clang++ -std=c++17 -O2 -ffp-contract=off -I "$META" \
  tool/reference_vectors.cpp \
  "$META/pdq/cpp/hashing/pdqhashing.cpp" \
  "$META/pdq/cpp/hashing/torben.cpp" \
  "$META/pdq/cpp/downscaling/downscaling.cpp" \
  -o /tmp/imghash-reference-vectors
/tmp/imghash-reference-vectors > test/fixtures/meta_vectors.json
```

`-ffp-contract=off` makes the oracle use separate float32 multiplication and
addition, matching this port. No C++ tools or upstream source are required to
use the Dart package or run its checked-in tests.
