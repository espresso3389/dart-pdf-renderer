import 'dart:typed_data';

import 'package:dart_pdf_renderer/dart_pdf_renderer.dart';
import 'package:test/test.dart';

import 'support/render_test_pdf.dart';

void main() {
  test('render with an uncancelled token returns image pixels', () async {
    final worker = await PdfPageAsyncRendererWorker.create();
    try {
      final renderer = await worker.openData(_testPdf());
      final token = renderer.createCancellationToken();
      final bgra = await _render(renderer, cancellationToken: token);

      expect(token.isCancelled, isFalse);
      expect(bgra, isNotNull);
      expect(_nonWhitePixelsBgra(bgra!), greaterThan(0));
    } finally {
      await worker.dispose();
    }
  });

  test('render with an already cancelled token returns null', () async {
    final worker = await PdfPageAsyncRendererWorker.create();
    try {
      final renderer = await worker.openData(_testPdf());
      final token = renderer.createCancellationToken()..cancel();
      final bgra = await _render(renderer, cancellationToken: token);

      expect(bgra, isNull);
    } finally {
      await worker.dispose();
    }
  });

  test('render cancelled after queueing returns null', () async {
    final worker = await PdfPageAsyncRendererWorker.create();
    try {
      final renderer = await worker.openData(_testPdf());
      final blocker = renderer.renderBgraRegion(
        pageNumber: 1,
        x: 0,
        y: 0,
        width: 2048,
        height: 2048,
        pixelRatio: 128,
        backgroundColor: 0xffffffff,
        annotations: false,
      );
      final token = renderer.createCancellationToken();
      final rendering = _render(renderer, cancellationToken: token);
      token.cancel();

      final bgra = await rendering;
      await blocker;
      expect(token.isCancelled, isTrue);
      expect(bgra, isNull);
    } finally {
      await worker.dispose();
    }
  });

  test('one worker can render multiple documents', () async {
    final worker = await PdfPageAsyncRendererWorker.create();
    try {
      final first = await worker.openData(_testPdf());
      final second = await worker.openData(_testPdf());

      final firstBgra = await _render(first);
      final secondBgra = await _render(second);

      expect(_nonWhitePixelsBgra(firstBgra!), greaterThan(0));
      expect(_nonWhitePixelsBgra(secondBgra!), greaterThan(0));
    } finally {
      await worker.dispose();
    }
  });

  test('rejects a cancellation token from another renderer', () async {
    final worker = await PdfPageAsyncRendererWorker.create();
    try {
      final first = await worker.openData(_testPdf());
      final second = await worker.openData(_testPdf());
      final token = first.createCancellationToken();

      await expectLater(
        _render(second, cancellationToken: token),
        throwsArgumentError,
      );
    } finally {
      await worker.dispose();
    }
  });
}

Uint8List _testPdf() => imageXObjectPdf(
  '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 '
  '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 12 >>',
  <int>[
    255, 0, 0, 255, 0, 0, //
    255, 0, 0, 255, 0, 0,
  ],
);

Future<Uint8List?> _render(
  PdfPageAsyncRenderer renderer, {
  PdfRenderCancellationToken? cancellationToken,
}) {
  return renderer.renderBgraRegion(
    pageNumber: 1,
    x: 0,
    y: 0,
    width: 16,
    height: 16,
    pixelRatio: 1,
    backgroundColor: 0xffffffff,
    annotations: false,
    cancellationToken: cancellationToken,
  );
}

int _nonWhitePixelsBgra(List<int> bgra) {
  var nonWhite = 0;
  for (var i = 0; i < bgra.length; i += 4) {
    final b = bgra[i];
    final g = bgra[i + 1];
    final r = bgra[i + 2];
    if (r != 255 || g != 255 || b != 255) nonWhite++;
  }
  return nonWhite;
}
