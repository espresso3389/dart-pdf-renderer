import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:pdfrx_engine/pdfrx_engine.dart' as pdfrx;
import 'package:pdfrx_dart_pdf/pdfrx_dart_pdf.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart run tool/debug_render.dart input.pdf output.png',
    );
    exitCode = 64;
    return;
  }

  pdfrxUseDartPdf();
  final doc = await pdfrx.PdfDocument.openFile(args[0]);
  try {
    final page = doc.pages.first;
    final fullWidth = 1600.0;
    final fullHeight = fullWidth * page.height / page.width;
    final rendered = await page.render(
      width: fullWidth.round(),
      height: fullHeight.round(),
      fullWidth: fullWidth,
      fullHeight: fullHeight,
    );
    if (rendered == null) throw StateError('render returned null');
    try {
      final rgba = Uint8List(rendered.pixels.length);
      for (var i = 0; i < rendered.pixels.length; i += 4) {
        rgba[i] = rendered.pixels[i + 2];
        rgba[i + 1] = rendered.pixels[i + 1];
        rgba[i + 2] = rendered.pixels[i];
        rgba[i + 3] = rendered.pixels[i + 3];
      }
      final png = image.Image.fromBytes(
        width: rendered.width,
        height: rendered.height,
        bytes: rgba.buffer,
        numChannels: 4,
      );
      await File(args[1]).writeAsBytes(image.encodePng(png));
      stdout.writeln(
        'rendered ${rendered.width}x${rendered.height} to ${args[1]}',
      );
    } finally {
      rendered.dispose();
    }
  } finally {
    doc.dispose();
  }
}
