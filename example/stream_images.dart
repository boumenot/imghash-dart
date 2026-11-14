import 'dart:io';
import 'dart:typed_data';

import 'image_helpers.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.length != 2) {
    throw ArgumentError(
      'Usage: dart run example/stream_images.dart [first-image second-image]',
    );
  }

  if (args.isEmpty) {
    final demo = demoImageBytes();
    // In-memory encoded bytes (e.g. an HTTP response body), not raw RGBA.
    final first = hashEncodedImage(demo.first);
    // A Stream<List<int>> can instead come from HTTP, stdin, or File.openRead().
    final chunks = Stream<List<int>>.fromIterable([
      for (var offset = 0; offset < demo.second.length; offset += 1024)
        Uint8List.sublistView(
          demo.second,
          offset,
          offset + 1024 < demo.second.length
              ? offset + 1024
              : demo.second.length,
        ),
    ]);
    final second = await hashImageStream(chunks);
    print('Demo: comparing in-memory PNG bytes and a chunked BMP stream');
    printComparison(first, second);
  } else {
    final first = await hashImageStream(File(args[0]).openRead());
    final second = await hashImageStream(File(args[1]).openRead());
    printComparison(first, second);
  }
}
