import 'dart:io';
import 'dart:math' as math;

// Reference evaluator for the PDFium CMYK conversion that backs
// lib/src/pdfium_cmyk.dart.
//
// This script extracts PDFium's kCMYK table from
// core/fxge/dib/cfx_cmyk_to_srgb.cpp, runs a Dart mirror of
// AdobeCmykToStandardRgb(), and prints sample values used while validating the
// generated implementation. It is not part of the normal test suite because it
// requires a local PDFium checkout.
//
// Usage from the dart_pdf_renderer package root:
//   dart run tool/source_gen/eval_pdfium_cmyk.dart
//   dart run tool/source_gen/eval_pdfium_cmyk.dart <pdfium-source>
const _defaultPdfiumCmykSource =
    r'D:\pdfium\core\fxge\dib\cfx_cmyk_to_srgb.cpp';

void main(List<String> args) {
  if (args.length > 1) {
    stderr.writeln(
      'usage: dart run tool/source_gen/eval_pdfium_cmyk.dart '
      '[pdfium-cfx_cmyk_to_srgb.cpp]',
    );
    exitCode = 64;
    return;
  }

  final sourcePath = args.isEmpty ? _defaultPdfiumCmykSource : args[0];
  final source = File(sourcePath).readAsStringSync();
  final tableText = source.substring(
    source.indexOf('constexpr std::array'),
    source.indexOf('}};', source.indexOf('constexpr std::array')),
  );
  final table = <List<int>>[
    for (final match in RegExp(
      r'\{(\d+),\s*(\d+),\s*(\d+)\}',
    ).allMatches(tableText))
      [
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
      ],
  ];
  stdout.writeln('source=$sourcePath table=${table.length}');
  for (final cmyk in const [
    [237, 224, 227, 204],
    [219, 134, 14, 0],
    [116, 7, 96, 0],
    [46, 159, 99, 0],
    [4, 44, 74, 0],
    [104, 4, 85, 0],
    [37, 135, 80, 0],
    [3, 38, 61, 0],
    [194, 96, 24, 0],
    [42, 147, 89, 0],
    [209, 66, 241, 0],
    [214, 83, 246, 0],
    [91, 143, 0, 0],
  ]) {
    stdout.writeln('$cmyk -> ${adobeCmykToStandardRgb(table, cmyk)}');
  }
}

// Mirrors PDFium AdobeCmykToStandardRgb(uint8_t, ...) using the kCMYK table
// extracted above. Keep this intentionally close to the PDFium algorithm; it is
// reference code for checking lib/src/pdfium_cmyk.dart, not a separate design.
List<int> adobeCmykToStandardRgb(List<List<int>> table, List<int> cmyk) {
  final c = cmyk[0];
  final m = cmyk[1];
  final y = cmyk[2];
  final k = cmyk[3];
  final fixC = c << 8;
  final fixM = m << 8;
  final fixY = y << 8;
  final fixK = k << 8;
  final cIndex = (fixC + 4096) >> 13;
  final mIndex = (fixM + 4096) >> 13;
  final yIndex = (fixY + 4096) >> 13;
  final kIndex = (fixK + 4096) >> 13;
  final start = table[index(cIndex, mIndex, yIndex, kIndex)];
  var fixR = start[0] << 8;
  var fixG = start[1] << 8;
  var fixB = start[2] << 8;

  var c1Index = fixC >> 13;
  if (c1Index == cIndex) c1Index = c1Index == 8 ? c1Index - 1 : c1Index + 1;
  var m1Index = fixM >> 13;
  if (m1Index == mIndex) m1Index = m1Index == 8 ? m1Index - 1 : m1Index + 1;
  var y1Index = fixY >> 13;
  if (y1Index == yIndex) y1Index = y1Index == 8 ? y1Index - 1 : y1Index + 1;
  var k1Index = fixK >> 13;
  if (k1Index == kIndex) k1Index = k1Index == 8 ? k1Index - 1 : k1Index + 1;

  final c1 = table[index(c1Index, mIndex, yIndex, kIndex)];
  final cRate = (fixC - (cIndex << 13)) * (cIndex - c1Index);
  fixR += (start[0] - c1[0]) * cRate ~/ 32;
  fixG += (start[1] - c1[1]) * cRate ~/ 32;
  fixB += (start[2] - c1[2]) * cRate ~/ 32;

  final m1 = table[index(cIndex, m1Index, yIndex, kIndex)];
  final mRate = (fixM - (mIndex << 13)) * (mIndex - m1Index);
  fixR += (start[0] - m1[0]) * mRate ~/ 32;
  fixG += (start[1] - m1[1]) * mRate ~/ 32;
  fixB += (start[2] - m1[2]) * mRate ~/ 32;

  final y1 = table[index(cIndex, mIndex, y1Index, kIndex)];
  final yRate = (fixY - (yIndex << 13)) * (yIndex - y1Index);
  fixR += (start[0] - y1[0]) * yRate ~/ 32;
  fixG += (start[1] - y1[1]) * yRate ~/ 32;
  fixB += (start[2] - y1[2]) * yRate ~/ 32;

  final k1 = table[index(cIndex, mIndex, yIndex, k1Index)];
  final kRate = (fixK - (kIndex << 13)) * (kIndex - k1Index);
  fixR += (start[0] - k1[0]) * kRate ~/ 32;
  fixG += (start[1] - k1[1]) * kRate ~/ 32;
  fixB += (start[2] - k1[2]) * kRate ~/ 32;

  return [
    math.max(fixR, 0) >> 8,
    math.max(fixG, 0) >> 8,
    math.max(fixB, 0) >> 8,
  ];
}

int index(int c, int m, int y, int k) => 9 * 9 * 9 * c + 9 * 9 * m + 9 * y + k;
