import 'dart:io';
import 'dart:typed_data';

import 'package:pdf_cos/pdf_cos.dart' as cos;
import 'package:pdf_document/pdf_document.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/probe_jpx.dart <pdf> <page>');
    exitCode = 64;
    return;
  }

  final document = PdfDocument.open(File(args[0]).readAsBytesSync());
  final page = document.page(int.parse(args[1]) - 1);
  final xObjects = document.cos.resolve(page.resources['XObject']);
  if (xObjects is! cos.CosDictionary) return;
  _walkXObjects(document.cos, xObjects, '');
}

void _walkXObjects(
  cos.CosDocument document,
  cos.CosDictionary xObjects,
  String prefix,
) {
  for (final entry in xObjects.entries.entries) {
    final object = document.resolve(entry.value);
    if (object is! cos.CosStream) continue;
    final subtype = document.resolve(object.dictionary['Subtype']);
    final name = '$prefix/${entry.key}';
    if (subtype is cos.CosName && subtype.value == 'Image') {
      _probeImage(document, name, object);
    } else if (subtype is cos.CosName && subtype.value == 'Form') {
      final resources = document.resolve(object.dictionary['Resources']);
      if (resources is! cos.CosDictionary) continue;
      final nested = document.resolve(resources['XObject']);
      if (nested is cos.CosDictionary) {
        _walkXObjects(document, nested, name);
      }
    }
  }
}

void _probeImage(cos.CosDocument document, String name, cos.CosStream stream) {
  final filters = _filterNames(document, stream.dictionary);
  if (!filters.contains('JPXDecode')) return;
  final bytes = document.decodeStreamData(
    stream,
    stopBeforeFilter: 'JPXDecode',
  );
  _printJpxMarkers(bytes);
  final jpx = cos.JpxDecoder.decode(bytes);
  stdout.writeln('$name filters=$filters raw=${bytes.length}');
  if (jpx == null) {
    stdout.writeln('  decode=null');
    return;
  }
  stdout.writeln(
    '  ${jpx.width}x${jpx.height} components=${jpx.components} '
    'samples=${jpx.samples.length}',
  );
  for (var c = 0; c < jpx.components; c++) {
    var min = 255;
    var max = 0;
    var sum = 0;
    var saturated = 0;
    final histogram = Uint32List(256);
    for (var i = c; i < jpx.samples.length; i += jpx.components) {
      final sample = jpx.samples[i];
      if (sample < min) min = sample;
      if (sample > max) max = sample;
      sum += sample;
      if (sample == 0 || sample == 255) saturated++;
      histogram[sample]++;
    }
    final count = jpx.samples.length ~/ jpx.components;
    final top = <int>[];
    for (var i = 0; i < histogram.length; i++) {
      if (histogram[i] > 0) top.add(i);
      if (top.length == 12) break;
    }
    stdout.writeln(
      '  c$c min=$min max=$max avg=${(sum / count).toStringAsFixed(2)} '
      'saturated=${(saturated * 100 / count).toStringAsFixed(2)}% '
      'firstValues=$top',
    );
  }
  var adjacentDelta = 0;
  var adjacentCount = 0;
  final rgbHistogram = <int, int>{};
  for (var i = 0; i + 2 < jpx.samples.length; i += jpx.components) {
    final key =
        jpx.samples[i] | (jpx.samples[i + 1] << 8) | (jpx.samples[i + 2] << 16);
    rgbHistogram[key] = (rgbHistogram[key] ?? 0) + 1;
  }
  for (var y = 0; y < jpx.height; y++) {
    var row = y * jpx.width * jpx.components;
    for (var x = 1; x < jpx.width; x++) {
      for (var c = 0; c < jpx.components; c++) {
        adjacentDelta +=
            (jpx.samples[row + x * jpx.components + c] -
                    jpx.samples[row + (x - 1) * jpx.components + c])
                .abs();
        adjacentCount++;
      }
    }
  }
  stdout.writeln(
    '  horizontal avg delta='
    '${(adjacentDelta / adjacentCount).toStringAsFixed(2)}',
  );
  final dominant = rgbHistogram.entries.reduce(
    (a, b) => a.value >= b.value ? a : b,
  );
  stdout.writeln(
    '  dominant rgb='
    '${dominant.key & 0xff},${(dominant.key >> 8) & 0xff},'
    '${(dominant.key >> 16) & 0xff} '
    '${(dominant.value * 100 / (jpx.width * jpx.height)).toStringAsFixed(2)}%',
  );
  stdout.writeln('  first 48: ${jpx.samples.take(48).join(',')}');
}

void _printJpxMarkers(Uint8List bytes) {
  final data = _codestreamOf(bytes);
  final view = ByteData.sublistView(data);
  stdout.writeln('  codestream=${data.length}');
  var p = 2;
  var tileParts = 0;
  while (p + 4 <= data.length) {
    final marker = view.getUint16(p);
    if (marker == 0xff90) {
      while (p + 12 <= data.length && view.getUint16(p) == 0xff90) {
        final tileIndex = view.getUint16(p + 4);
        var tileLength = view.getUint32(p + 6);
        final partIndex = data[p + 10];
        final partCount = data[p + 11];
        if (tileLength == 0) tileLength = data.length - p;
        stdout.writeln(
          '  SOT tile=$tileIndex part=$partIndex/$partCount '
          'length=$tileLength',
        );
        tileParts++;
        if (tileLength <= 0) break;
        p += tileLength;
      }
      break;
    }
    if (marker == 0xff93 || marker == 0xffd9) break;
    final length = view.getUint16(p + 2);
    stdout.writeln('  ${_markerName(marker)} length=$length');
    switch (marker) {
      case 0xff51:
        final width = view.getUint32(p + 6);
        final height = view.getUint32(p + 10);
        final components = view.getUint16(p + 38);
        stdout.writeln(
          '  SIZ width=$width height=$height components=$components',
        );
        var q = p + 40;
        for (var c = 0; c < components; c++) {
          final ssiz = data[q++];
          final xrsiz = data[q++];
          final yrsiz = data[q++];
          stdout.writeln(
            '    c$c depth=${(ssiz & 0x7f) + 1} signed=${ssiz >= 128} '
            'xrsiz=$xrsiz yrsiz=$yrsiz',
          );
        }
      case 0xff52:
        final progression = data[p + 5];
        final layers = view.getUint16(p + 6);
        final mct = data[p + 8];
        final levels = data[p + 9];
        final cbWidth = 1 << (data[p + 10] + 2);
        final cbHeight = 1 << (data[p + 11] + 2);
        final cbStyle = data[p + 12];
        final transform = data[p + 13];
        stdout.writeln(
          '  COD progression=$progression layers=$layers mct=$mct '
          'levels=$levels codeBlock=${cbWidth}x$cbHeight '
          'style=$cbStyle transform=$transform',
        );
      case 0xff5c:
        final style = data[p + 4] >> 5;
        final guardBits = data[p + 4] & 7;
        stdout.writeln('  QCD style=$style guardBits=$guardBits');
    }
    p += 2 + length;
  }
  stdout.writeln('  tileParts=$tileParts');
}

String _markerName(int marker) => switch (marker) {
  0xff4f => 'SOC',
  0xff51 => 'SIZ',
  0xff52 => 'COD',
  0xff53 => 'COC',
  0xff55 => 'TLM',
  0xff57 => 'PLM',
  0xff58 => 'PLT',
  0xff5c => 'QCD',
  0xff5d => 'QCC',
  0xff5e => 'RGN',
  0xff5f => 'POC',
  0xff60 => 'PPM',
  0xff61 => 'PPT',
  0xff64 => 'COM',
  0xff90 => 'SOT',
  0xff91 => 'SOP',
  0xff92 => 'EPH',
  0xff93 => 'SOD',
  0xffd9 => 'EOC',
  _ => '0x${marker.toRadixString(16).padLeft(4, '0')}',
};

Uint8List _codestreamOf(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0x4f) {
    return bytes;
  }
  final view = ByteData.sublistView(bytes);
  var p = 0;
  while (p + 8 <= bytes.length) {
    var length = view.getUint32(p);
    final type = String.fromCharCodes(bytes, p + 4, p + 8);
    var headerSize = 8;
    if (length == 1) {
      length = view.getUint32(p + 12);
      headerSize = 16;
    } else if (length == 0) {
      length = bytes.length - p;
    }
    if (type == 'jp2c') {
      return Uint8List.sublistView(bytes, p + headerSize, p + length);
    }
    p += length;
  }
  return bytes;
}

List<String> _filterNames(cos.CosDocument document, cos.CosDictionary dict) {
  final filters = document.resolve(dict['Filter']);
  if (filters is cos.CosName) return [filters.value];
  if (filters is cos.CosArray) {
    return [
      for (final item in filters.items)
        if (document.resolve(item) case cos.CosName(:final value)) value,
    ];
  }
  return const [];
}
