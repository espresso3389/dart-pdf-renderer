import 'dart:typed_data';

import 'package:dart_pdf_renderer/dart_pdf_renderer.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:test/test.dart';

import 'support/render_test_pdf.dart';

void main() {
  test('can clear one page display-list cache entry', () {
    final document = PdfDocument.open(
      twoPageContentPdf(
        '0 1 0 rg\n2 2 12 12 re f\n',
        '1 0 0 rg\n2 2 12 12 re f\n',
      ),
      password: '',
    );
    final renderer = PdfPageRenderer(document);

    _render(renderer, 1);
    _render(renderer, 2);
    expect(renderer.displayListCacheEntryCount, 2);

    renderer.clearPageCache(1);
    expect(renderer.displayListCacheEntryCount, 1);

    _render(renderer, 2);
    expect(renderer.displayListCacheEntryCount, 1);

    _render(renderer, 1);
    expect(renderer.displayListCacheEntryCount, 2);
  });

  test('can clear all display-list cache entries', () {
    final document = PdfDocument.open(
      twoPageContentPdf(
        '0 1 0 rg\n2 2 12 12 re f\n',
        '1 0 0 rg\n2 2 12 12 re f\n',
      ),
      password: '',
    );
    final renderer = PdfPageRenderer(document);

    _render(renderer, 1);
    _render(renderer, 2);
    renderer.clearDisplayListCache();

    expect(renderer.displayListCacheEntryCount, 0);
  });
}

Uint8List _render(PdfPageRenderer renderer, int pageNumber) {
  return renderer.renderRgbaRegion(
    pageNumber: pageNumber,
    x: 0,
    y: 0,
    width: 16,
    height: 16,
    pixelRatio: 1,
    backgroundColor: 0xffffffff,
    annotations: false,
  );
}
