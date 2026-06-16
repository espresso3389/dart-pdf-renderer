import 'dart:typed_data';

import 'package:dart_pdf_renderer/dart_pdf_renderer.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:test/test.dart';

import 'support/render_test_pdf.dart';

void main() {
  test('fill implicitly closes open subpaths', () {
    final bgra = _renderBgra(
      singlePageContentPdf('0 0.5 0 rg\n2 2 m 14 2 l 14 14 l 2 14 l f\n'),
    );

    expect(_greenPixelsBgra(bgra), greaterThan(80));
  });
}

Uint8List _renderBgra(Uint8List pdf) {
  final document = PdfDocument.open(pdf, password: '');
  final renderer = PdfPageRenderer(document);
  return renderer.renderBgraRegion(
    pageNumber: 1,
    x: 0,
    y: 0,
    width: 16,
    height: 16,
    pixelRatio: 1,
    backgroundColor: 0xffffffff,
    annotations: false,
  );
}

int _greenPixelsBgra(List<int> bgra) {
  var green = 0;
  for (var i = 0; i < bgra.length; i += 4) {
    final b = bgra[i];
    final g = bgra[i + 1];
    final r = bgra[i + 2];
    if (g > 90 && r < 40 && b < 40) green++;
  }
  return green;
}
