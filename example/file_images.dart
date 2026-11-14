import 'dart:io';

import 'image_helpers.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.length != 2) {
    throw ArgumentError(
      'Usage: dart run example/file_images.dart [first-image second-image]',
    );
  }

  Directory? demoDirectory;
  try {
    final List<String> paths;
    if (args.isEmpty) {
      final demo = demoImageBytes();
      final directory = await Directory.systemTemp.createTemp('imghash-demo-');
      demoDirectory = directory;
      final first = File('${directory.path}/first.png');
      final second = File('${directory.path}/second.bmp');
      await first.writeAsBytes(demo.first);
      await second.writeAsBytes(demo.second);
      paths = [first.path, second.path];
      print('Demo: comparing PNG and BMP files of the same image');
    } else {
      paths = args;
    }

    final first = hashEncodedImage(await File(paths[0]).readAsBytes());
    final second = hashEncodedImage(await File(paths[1]).readAsBytes());
    printComparison(first, second);
  } finally {
    if (demoDirectory != null) {
      await demoDirectory.delete(recursive: true);
    }
  }
}
