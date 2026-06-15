import 'dart:typed_data';

import 'package:dart_pdf_renderer/dart_pdf_renderer.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:test/test.dart';

import 'support/render_test_pdf.dart';

void main() {
  test('renders an image XObject', () {
    final bgra = _renderBgra(
      imageXObjectPdf(
        '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 12 >>',
        <int>[
          255, 0, 0, 255, 0, 0, //
          255, 0, 0, 255, 0, 0,
        ],
      ),
    );
    expect(_redPixelsBgra(bgra), greaterThan(200));
  });

  test('renders a DeviceCMYK image XObject', () {
    final bgra = _renderBgra(
      imageXObjectPdf(
        '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 '
        '/ColorSpace /DeviceCMYK /BitsPerComponent 8 /Length 16 >>',
        <int>[
          0, 255, 255, 0, 0, 255, 255, 0, //
          0, 255, 255, 0, 0, 255, 255, 0,
        ],
      ),
    );
    expect(_redPixelsBgra(bgra), greaterThan(200));
  });

  test('uses process-ink fallback for DeviceCMYK image XObjects', () {
    final bgra = _renderBgra(
      imageXObjectPdf(
        '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 '
        '/ColorSpace /DeviceCMYK /BitsPerComponent 8 /Length 16 >>',
        <int>[
          255, 0, 0, 0, 255, 0, 0, 0, //
          255, 0, 0, 0, 255, 0, 0, 0,
        ],
      ),
    );
    expect(_processCyanPixelsBgra(bgra), greaterThan(200));
  });

  test('renders an Indexed DeviceCMYK image XObject', () {
    final bgra = _renderBgra(
      imageXObjectPdf(
        '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 '
        '/ColorSpace [/Indexed /DeviceCMYK 1 <0000000000FFFF00>] '
        '/BitsPerComponent 8 /Length 4 >>',
        <int>[1, 1, 1, 1],
      ),
    );
    expect(_redPixelsBgra(bgra), greaterThan(200));
  });

  test('applies image XObject soft masks', () {
    final bgra = _renderBgra(
      imageXObjectPdf(
        '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask 6 0 R '
        '/Length 12 >>',
        <int>[
          255, 0, 0, 255, 0, 0, //
          255, 0, 0, 255, 0, 0,
        ],
        extraObjects: const [
          TestPdfStreamObject(
            6,
            '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 '
            '/ColorSpace /DeviceGray /BitsPerComponent 8 /Length 4 >>',
            <int>[255, 0, 255, 0],
          ),
        ],
      ),
    );
    expect(_redPixelsBgra(bgra), inInclusiveRange(64, 160));
    expect(_whitePixelsBgra(bgra), inInclusiveRange(64, 160));
  });

  test('renders a named DeviceCMYK image color space', () {
    final bgra = _renderBgra(
      imageXObjectPdf(
        '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 '
        '/ColorSpace /CS0 /BitsPerComponent 8 /Length 16 >>',
        <int>[
          0, 255, 255, 0, 0, 255, 255, 0, //
          0, 255, 255, 0, 0, 255, 255, 0,
        ],
        extraPageResources: '/ColorSpace << /CS0 /DeviceCMYK >>',
      ),
    );
    expect(_redPixelsBgra(bgra), greaterThan(200));
  });

  test('applies DefaultCMYK ICC profile to image XObjects', () {
    final icc = constantCmykXyzIccProfile([38, 77, 13]);
    final bgra = _renderBgra(
      imageXObjectPdf(
        '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 '
        '/ColorSpace /DeviceCMYK /BitsPerComponent 8 /Length 16 >>',
        <int>[
          0, 255, 255, 0, 0, 255, 255, 0, //
          0, 255, 255, 0, 0, 255, 255, 0,
        ],
        extraPageResources: '/ColorSpace << /DefaultCMYK [/ICCBased 6 0 R] >>',
        extraObjects: [
          TestPdfStreamObject(6, '<< /N 4 /Length ${icc.length} >>', icc),
        ],
      ),
    );
    expect(_greenPixelsBgra(bgra), greaterThan(200));
  });

  test('applies CMYK OutputIntent profile to image XObjects', () {
    final icc = constantCmykXyzIccProfile([38, 77, 13]);
    final bgra = _renderBgra(
      imageXObjectPdf(
        '<< /Type /XObject /Subtype /Image /Width 2 /Height 2 '
        '/ColorSpace /DeviceCMYK /BitsPerComponent 8 /Length 16 >>',
        <int>[
          0, 255, 255, 0, 0, 255, 255, 0, //
          0, 255, 255, 0, 0, 255, 255, 0,
        ],
        extraCatalogEntries: '/OutputIntents [6 0 R]',
        extraDictionaryObjects: const [
          TestPdfDictionaryObject(
            6,
            '<< /Type /OutputIntent /S /GTS_PDFX /DestOutputProfile 7 0 R >>',
          ),
        ],
        extraObjects: [
          TestPdfStreamObject(7, '<< /N 4 /Length ${icc.length} >>', icc),
        ],
      ),
    );
    expect(_greenPixelsBgra(bgra), greaterThan(200));
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

int _redPixelsBgra(List<int> bgra) {
  var red = 0;
  for (var i = 0; i < bgra.length; i += 4) {
    final b = bgra[i];
    final g = bgra[i + 1];
    final r = bgra[i + 2];
    if (r > 180 && g < 90 && b < 90) red++;
  }
  return red;
}

int _greenPixelsBgra(List<int> bgra) {
  var green = 0;
  for (var i = 0; i < bgra.length; i += 4) {
    final b = bgra[i];
    final g = bgra[i + 1];
    final r = bgra[i + 2];
    if (g > 180 && r < 80 && b < 100) green++;
  }
  return green;
}

int _processCyanPixelsBgra(List<int> bgra) {
  var cyan = 0;
  for (var i = 0; i < bgra.length; i += 4) {
    final b = bgra[i];
    final g = bgra[i + 1];
    final r = bgra[i + 2];
    if (r < 25 && g > 170 && g < 205 && b > 220 && b < 245) cyan++;
  }
  return cyan;
}

int _whitePixelsBgra(List<int> bgra) {
  var white = 0;
  for (var i = 0; i < bgra.length; i += 4) {
    final b = bgra[i];
    final g = bgra[i + 1];
    final r = bgra[i + 2];
    if (r > 230 && g > 230 && b > 230) white++;
  }
  return white;
}
