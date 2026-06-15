import 'package:dart_pdf_renderer/src/pdfium_cmyk.dart';
import 'package:test/test.dart';

void main() {
  test('matches PDFium AdobeCmykToStandardRgb sample values', () {
    expect(_pdfiumCmyk(0, 0, 0, 0), [255, 255, 255]);
    expect(_pdfiumCmyk(237, 224, 227, 204), [3, 3, 3]);
    expect(_pdfiumCmyk(219, 134, 14, 0), [26, 114, 178]);
    expect(_pdfiumCmyk(116, 7, 96, 0), [139, 202, 176]);
    expect(_pdfiumCmyk(46, 159, 99, 0), [206, 121, 129]);
  });
}

List<int> _pdfiumCmyk(int c, int m, int y, int k) {
  final rgb = List<int>.filled(3, 0);
  pdfiumCmykToRgb(c, m, y, k, rgb);
  return rgb;
}
