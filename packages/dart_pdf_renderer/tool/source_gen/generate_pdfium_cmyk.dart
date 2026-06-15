import 'dart:convert';
import 'dart:io';

// Reference generator for lib/src/pdfium_cmyk.dart.
//
// This script is intentionally kept as source-generation documentation rather
// than as part of the normal build. It records how the PDFium-derived CMYK
// lookup table and interpolation routine were copied into Dart.
//
// PDFium source correspondence:
// - core/fxge/dib/cfx_cmyk_to_srgb.cpp kCMYK
//     -> _pdfiumCmykTable in lib/src/pdfium_cmyk.dart
// - IndexFromCMYK()
//     -> _pdfiumCmykTableOffset()
// - AdobeCmykToStandardRgb(uint8_t, ...)
//     -> pdfiumCmykToRgb()
//
// Usage from the dart_pdf_renderer package root:
//   dart run tool/source_gen/generate_pdfium_cmyk.dart
//   dart run tool/source_gen/generate_pdfium_cmyk.dart <pdfium-source> <output>
//
// The default PDFium path is the local checkout path used during development.
const _defaultPdfiumCmykSource =
    r'D:\pdfium\core\fxge\dib\cfx_cmyk_to_srgb.cpp';
const _defaultOutput = 'lib/src/pdfium_cmyk.dart';

void main(List<String> args) {
  if (args.length > 2) {
    stderr.writeln(
      'usage: dart run tool/source_gen/generate_pdfium_cmyk.dart '
      '[pdfium-cfx_cmyk_to_srgb.cpp] [output-dart-file]',
    );
    exitCode = 64;
    return;
  }

  final sourcePath = args.isEmpty ? _defaultPdfiumCmykSource : args[0];
  final outputPath = args.length < 2 ? _defaultOutput : args[1];
  final source = File(sourcePath).readAsStringSync();
  final tableStart = source.indexOf('constexpr std::array');
  final tableEnd = source.indexOf('}};', tableStart);
  if (tableStart < 0 || tableEnd < 0) {
    throw StateError('PDFium CMYK table not found.');
  }
  final tableText = source.substring(tableStart, tableEnd);
  final bytes = <int>[];
  for (final match in RegExp(
    r'\{(\d+),\s*(\d+),\s*(\d+)\}',
  ).allMatches(tableText)) {
    bytes.add(int.parse(match.group(1)!));
    bytes.add(int.parse(match.group(2)!));
    bytes.add(int.parse(match.group(3)!));
  }
  if (bytes.length != 9 * 9 * 9 * 9 * 3) {
    throw StateError('Unexpected PDFium CMYK table size: ${bytes.length}');
  }

  final base64 = base64Encode(bytes);
  final chunks = <String>[];
  for (var i = 0; i < base64.length; i += 76) {
    final end = (i + 76).clamp(0, base64.length);
    chunks.add(base64.substring(i, end));
  }

  final out = StringBuffer()
    ..writeln("import 'dart:convert';")
    ..writeln("import 'dart:math' as math;")
    ..writeln("import 'dart:typed_data';")
    ..writeln()
    ..writeln('// Generated from PDFium core/fxge/dib/cfx_cmyk_to_srgb.cpp.')
    ..writeln('// Direct PDFium source correspondence:')
    ..writeln(
      '// - PDFium kCMYK -> _pdfiumCmykTable, flattened in the same c,m,y,k order.',
    )
    ..writeln('// - PDFium IndexFromCMYK() -> _pdfiumCmykTableOffset().')
    ..writeln(
      '// - PDFium AdobeCmykToStandardRgb(uint8_t, ...) -> pdfiumCmykToRgb().',
    )
    ..writeln(
      '// PDFium uses a BSD-style license; the original table/function are',
    )
    ..writeln('// Copyright 2019 The PDFium Authors and include original Foxit')
    ..writeln('// Software Inc. code.')
    ..writeln('final Uint8List _pdfiumCmykTable = base64Decode(');
  for (final chunk in chunks) {
    out.writeln("  '$chunk'");
  }
  out
    ..writeln(');')
    ..writeln()
    ..writeln('void pdfiumCmykToRgb(')
    ..writeln('  int c,')
    ..writeln('  int m,')
    ..writeln('  int y,')
    ..writeln('  int k,')
    ..writeln('  List<int> rgb,')
    ..writeln(') {')
    ..writeln('  final fixC = c << 8;')
    ..writeln('  final fixM = m << 8;')
    ..writeln('  final fixY = y << 8;')
    ..writeln('  final fixK = k << 8;')
    ..writeln('  final cIndex = (fixC + 4096) >> 13;')
    ..writeln('  final mIndex = (fixM + 4096) >> 13;')
    ..writeln('  final yIndex = (fixY + 4096) >> 13;')
    ..writeln('  final kIndex = (fixK + 4096) >> 13;')
    ..writeln(
      '  final start = _pdfiumCmykTableOffset(cIndex, mIndex, yIndex, kIndex);',
    )
    ..writeln('  var fixR = _pdfiumCmykTable[start] << 8;')
    ..writeln('  var fixG = _pdfiumCmykTable[start + 1] << 8;')
    ..writeln('  var fixB = _pdfiumCmykTable[start + 2] << 8;')
    ..writeln()
    ..writeln('  var c1Index = fixC >> 13;')
    ..writeln(
      '  if (c1Index == cIndex) c1Index = c1Index == 8 ? c1Index - 1 : c1Index + 1;',
    )
    ..writeln('  var m1Index = fixM >> 13;')
    ..writeln(
      '  if (m1Index == mIndex) m1Index = m1Index == 8 ? m1Index - 1 : m1Index + 1;',
    )
    ..writeln('  var y1Index = fixY >> 13;')
    ..writeln(
      '  if (y1Index == yIndex) y1Index = y1Index == 8 ? y1Index - 1 : y1Index + 1;',
    )
    ..writeln('  var k1Index = fixK >> 13;')
    ..writeln(
      '  if (k1Index == kIndex) k1Index = k1Index == 8 ? k1Index - 1 : k1Index + 1;',
    )
    ..writeln()
    ..writeln(
      '  final c1 = _pdfiumCmykTableOffset(c1Index, mIndex, yIndex, kIndex);',
    )
    ..writeln('  final cRate = (fixC - (cIndex << 13)) * (cIndex - c1Index);')
    ..writeln(
      '  fixR += (_pdfiumCmykTable[start] - _pdfiumCmykTable[c1]) * cRate ~/ 32;',
    )
    ..writeln(
      '  fixG += (_pdfiumCmykTable[start + 1] - _pdfiumCmykTable[c1 + 1]) * cRate ~/ 32;',
    )
    ..writeln(
      '  fixB += (_pdfiumCmykTable[start + 2] - _pdfiumCmykTable[c1 + 2]) * cRate ~/ 32;',
    )
    ..writeln()
    ..writeln(
      '  final m1 = _pdfiumCmykTableOffset(cIndex, m1Index, yIndex, kIndex);',
    )
    ..writeln('  final mRate = (fixM - (mIndex << 13)) * (mIndex - m1Index);')
    ..writeln(
      '  fixR += (_pdfiumCmykTable[start] - _pdfiumCmykTable[m1]) * mRate ~/ 32;',
    )
    ..writeln(
      '  fixG += (_pdfiumCmykTable[start + 1] - _pdfiumCmykTable[m1 + 1]) * mRate ~/ 32;',
    )
    ..writeln(
      '  fixB += (_pdfiumCmykTable[start + 2] - _pdfiumCmykTable[m1 + 2]) * mRate ~/ 32;',
    )
    ..writeln()
    ..writeln(
      '  final y1 = _pdfiumCmykTableOffset(cIndex, mIndex, y1Index, kIndex);',
    )
    ..writeln('  final yRate = (fixY - (yIndex << 13)) * (yIndex - y1Index);')
    ..writeln(
      '  fixR += (_pdfiumCmykTable[start] - _pdfiumCmykTable[y1]) * yRate ~/ 32;',
    )
    ..writeln(
      '  fixG += (_pdfiumCmykTable[start + 1] - _pdfiumCmykTable[y1 + 1]) * yRate ~/ 32;',
    )
    ..writeln(
      '  fixB += (_pdfiumCmykTable[start + 2] - _pdfiumCmykTable[y1 + 2]) * yRate ~/ 32;',
    )
    ..writeln()
    ..writeln(
      '  final k1 = _pdfiumCmykTableOffset(cIndex, mIndex, yIndex, k1Index);',
    )
    ..writeln('  final kRate = (fixK - (kIndex << 13)) * (kIndex - k1Index);')
    ..writeln(
      '  fixR += (_pdfiumCmykTable[start] - _pdfiumCmykTable[k1]) * kRate ~/ 32;',
    )
    ..writeln(
      '  fixG += (_pdfiumCmykTable[start + 1] - _pdfiumCmykTable[k1 + 1]) * kRate ~/ 32;',
    )
    ..writeln(
      '  fixB += (_pdfiumCmykTable[start + 2] - _pdfiumCmykTable[k1 + 2]) * kRate ~/ 32;',
    )
    ..writeln()
    ..writeln('  rgb[0] = (math.max(fixR, 0) >> 8).clamp(0, 255).toInt();')
    ..writeln('  rgb[1] = (math.max(fixG, 0) >> 8).clamp(0, 255).toInt();')
    ..writeln('  rgb[2] = (math.max(fixB, 0) >> 8).clamp(0, 255).toInt();')
    ..writeln('}')
    ..writeln()
    ..writeln('int _pdfiumCmykTableOffset(int c, int m, int y, int k) =>')
    ..writeln('    (9 * 9 * 9 * c + 9 * 9 * m + 9 * y + k) * 3;');

  File(outputPath).writeAsStringSync(out.toString());
  stdout.writeln('generated $outputPath from $sourcePath');
}
