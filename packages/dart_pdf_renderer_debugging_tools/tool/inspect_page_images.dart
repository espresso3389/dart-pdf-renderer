import 'dart:io';

import 'package:pdf_cos/pdf_cos.dart' as cos;
import 'package:pdf_document/pdf_document.dart' as dart_pdf;
import 'package:pdf_graphics/pdf_graphics.dart';

const _usage = '''
usage:
  dart run tool/inspect_page_images.dart <pdf> [options]

options:
  --pages <spec>    page numbers/ranges, for example 1-5,112,213 (default: 1)
  --details         print indexed-image palettes and sample histograms

Prints image XObjects that are actually referenced by page content streams.
Form XObjects are traversed recursively.
''';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.write(_usage);
    exitCode = 64;
    return;
  }

  final options = _Options.parse(args);
  if (options == null) {
    stderr.write(_usage);
    exitCode = 64;
    return;
  }

  final data = File(options.pdfPath).readAsBytesSync();
  final document = dart_pdf.PdfDocument.open(data, password: '');
  final pages = _expandPages(options.pagesSpec, document.pageCount);
  for (final pageNumber in pages) {
    final page = document.page(pageNumber - 1);
    final images = <_ImageUse>[];
    _walkOperations(
      document.cos,
      ContentStreamParser.parse(page.contentBytes()),
      page.resources,
      'page $pageNumber',
      0,
      <cos.CosStream>{},
      images,
    );

    stdout.writeln('page=$pageNumber images=${images.length}');
    for (var i = 0; i < images.length; i++) {
      stdout.writeln('  ${i + 1}. ${images[i]}');
      if (options.details) {
        for (final line in images[i].details) {
          stdout.writeln('     $line');
        }
      }
    }
  }
}

void _walkOperations(
  cos.CosDocument document,
  List<ContentOperation> operations,
  cos.CosDictionary resources,
  String path,
  int depth,
  Set<cos.CosStream> visitedForms,
  List<_ImageUse> images,
) {
  if (depth > 12) return;
  for (final operation in operations) {
    if (operation.operator != 'Do' || operation.operands.isEmpty) continue;
    final name = operation.operands.last;
    if (name is! cos.CosName) continue;
    final xObjectGroup = document.resolve(resources['XObject']);
    if (xObjectGroup is! cos.CosDictionary) continue;
    final xObject = document.resolve(xObjectGroup[name.value]);
    if (xObject is! cos.CosStream) continue;

    final subtype = _nameValue(document.resolve(xObject.dictionary['Subtype']));
    final childPath = '$path/${name.value}';
    if (subtype == 'Image') {
      images.add(_ImageUse.fromStream(document, childPath, xObject));
      continue;
    }
    if (subtype != 'Form' || !visitedForms.add(xObject)) continue;

    final formResources = document.resolve(xObject.dictionary['Resources']);
    final content = document.decodeStreamData(xObject);
    _walkOperations(
      document,
      ContentStreamParser.parse(content),
      formResources is cos.CosDictionary ? formResources : resources,
      childPath,
      depth + 1,
      visitedForms,
      images,
    );
  }
}

List<int> _expandPages(String? spec, int pageCount) {
  if (spec == null || spec.trim().isEmpty || spec == 'all') {
    return [1];
  }

  final pages = <int>{};
  for (final part in spec.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final dash = trimmed.indexOf('-');
    if (dash < 0) {
      pages.add(_parsePage(trimmed, pageCount));
      continue;
    }
    final start = _parsePage(trimmed.substring(0, dash), pageCount);
    final end = _parsePage(trimmed.substring(dash + 1), pageCount);
    if (start > end) {
      throw ArgumentError.value(trimmed, 'pages', 'range start exceeds end');
    }
    for (var page = start; page <= end; page++) {
      pages.add(page);
    }
  }
  return pages.toList()..sort();
}

int _parsePage(String value, int pageCount) {
  final page = int.parse(value);
  if (page < 1 || page > pageCount) {
    throw RangeError.range(page, 1, pageCount, 'page');
  }
  return page;
}

String _objectSummary(cos.CosDocument document, cos.CosObject? object) {
  final resolved = document.resolve(object);
  return switch (resolved) {
    cos.CosName(:final value) => '/$value',
    cos.CosInteger(:final value) => '$value',
    cos.CosReal(:final value) => '$value',
    cos.CosBoolean(:final value) => '$value',
    cos.CosString(:final bytes) => 'string(${bytes.length} bytes)',
    cos.CosArray(:final items) =>
      '[${items.map((item) => _objectSummary(document, item)).join(' ')}]',
    cos.CosDictionary(:final entries) => '<<${entries.keys.join(' ')}>>',
    cos.CosStream(:final dictionary, :final rawBytes) =>
      'stream(${rawBytes.length} bytes ${_dictionaryKeySummary(dictionary)})',
    cos.CosReference(:final objectNumber, :final generation) =>
      '$objectNumber $generation R',
    cos.CosNull() => 'null',
  };
}

String _dictionaryKeySummary(cos.CosDictionary dictionary) =>
    '<<${dictionary.entries.keys.join(' ')}>>';

String? _nameValue(cos.CosObject? object) =>
    object is cos.CosName ? object.value : null;

int _intValue(cos.CosObject? object) => switch (object) {
  cos.CosInteger(:final value) => value,
  cos.CosReal(:final value) => value.round(),
  _ => 0,
};

List<String> _filterNames(
  cos.CosDocument document,
  cos.CosDictionary dictionary,
) {
  final filter = document.resolve(dictionary['Filter']);
  if (filter is cos.CosName) return [filter.value];
  if (filter is cos.CosArray) {
    return [
      for (final item in filter.items)
        if (document.resolve(item) case cos.CosName(:final value)) value,
    ];
  }
  return const [];
}

String _supportNote(
  int bits,
  bool imageMask,
  List<String> filters,
  String colorSpace,
) {
  if (imageMask) return 'pure: stencil';
  if (filters.contains('DCTDecode') || filters.contains('DCT')) {
    if (colorSpace.contains('DeviceCMYK')) {
      return 'pure: supported DCT CMYK';
    }
    return 'pure: DCT via image package';
  }
  if (bits != 8) return 'pure: unsupported bits';
  if (colorSpace == '/DeviceGray' ||
      colorSpace == '/G' ||
      colorSpace == '/DeviceRGB' ||
      colorSpace == '/RGB' ||
      colorSpace == '/DeviceCMYK' ||
      colorSpace == '/CMYK') {
    return 'pure: supported';
  }
  if (colorSpace.startsWith('[/Indexed ') &&
      (colorSpace.contains('DeviceGray') ||
          colorSpace.contains('DeviceRGB') ||
          colorSpace.contains('DeviceCMYK'))) {
    return 'pure: supported indexed';
  }
  return 'pure: unsupported color space';
}

class _Options {
  const _Options({
    required this.pdfPath,
    required this.pagesSpec,
    required this.details,
  });

  final String pdfPath;
  final String? pagesSpec;
  final bool details;

  static _Options? parse(List<String> args) {
    final pdfPath = args.first;
    String? pagesSpec;
    var details = false;
    for (var i = 1; i < args.length; i++) {
      switch (args[i]) {
        case '--pages':
          pagesSpec = args[++i];
        case '--details':
          details = true;
        default:
          return null;
      }
    }
    return _Options(pdfPath: pdfPath, pagesSpec: pagesSpec, details: details);
  }
}

class _ImageUse {
  const _ImageUse({
    required this.path,
    required this.width,
    required this.height,
    required this.bits,
    required this.imageMask,
    required this.colorSpace,
    required this.filters,
    required this.decode,
    required this.decodeParms,
    required this.sMask,
    required this.mask,
    required this.rawBytes,
    required this.supportNote,
    required this.details,
  });

  factory _ImageUse.fromStream(
    cos.CosDocument document,
    String path,
    cos.CosStream stream,
  ) {
    final dictionary = stream.dictionary;
    final width = _intValue(document.resolve(dictionary['Width']));
    final height = _intValue(document.resolve(dictionary['Height']));
    final bits = _intValue(document.resolve(dictionary['BitsPerComponent']));
    final imageMask =
        document.resolve(dictionary['ImageMask']) == const cos.CosBoolean(true);
    final colorSpace = _objectSummary(document, dictionary['ColorSpace']);
    final filters = _filterNames(document, dictionary);
    final details = _imageDetails(document, stream);
    return _ImageUse(
      path: path,
      width: width,
      height: height,
      bits: bits,
      imageMask: imageMask,
      colorSpace: colorSpace,
      filters: filters,
      decode: _objectSummary(document, dictionary['Decode']),
      decodeParms: _objectSummary(document, dictionary['DecodeParms']),
      sMask: _objectSummary(document, dictionary['SMask']),
      mask: _objectSummary(document, dictionary['Mask']),
      rawBytes: stream.rawBytes.length,
      supportNote: _supportNote(bits, imageMask, filters, colorSpace),
      details: details,
    );
  }

  final String path;
  final int width;
  final int height;
  final int bits;
  final bool imageMask;
  final String colorSpace;
  final List<String> filters;
  final String decode;
  final String decodeParms;
  final String sMask;
  final String mask;
  final int rawBytes;
  final String supportNote;
  final List<String> details;

  @override
  String toString() =>
      '$path ${width}x$height bits=$bits '
      'mask=$imageMask cs=$colorSpace filter=${filters.join('+')} '
      'decode=$decode smask=$sMask mask=$mask raw=$rawBytes $supportNote';
}

List<String> _imageDetails(cos.CosDocument document, cos.CosStream stream) {
  final dictionary = stream.dictionary;
  final colorSpace = document.resolve(dictionary['ColorSpace']);
  if (colorSpace is! cos.CosArray || colorSpace.length < 4) return const [];
  final family = document.resolve(colorSpace[0]);
  if (family is! cos.CosName ||
      (family.value != 'Indexed' && family.value != 'I')) {
    return const [];
  }

  final base = _objectSummary(document, colorSpace[1]);
  final highValue = _intValue(document.resolve(colorSpace[2]));
  final lookupObject = document.resolve(colorSpace[3]);
  final lookup = switch (lookupObject) {
    cos.CosString(:final bytes) => bytes,
    cos.CosStream() => document.decodeStreamData(lookupObject),
    _ => null,
  };
  final lines = <String>['indexed base=$base high=$highValue'];
  if (lookup != null) {
    final components = base.contains('DeviceCMYK')
        ? 4
        : base.contains('DeviceRGB')
        ? 3
        : 1;
    for (var i = 0; i <= highValue; i++) {
      final offset = i * components;
      if (offset + components > lookup.length) break;
      lines.add(
        'palette[$i]=${lookup.sublist(offset, offset + components).join(',')}',
      );
    }
  }

  final bits = _intValue(document.resolve(dictionary['BitsPerComponent']));
  if (bits == 8) {
    try {
      final data = document.decodeStreamData(stream);
      final histogram = <int, int>{};
      for (final sample in data) {
        histogram[sample] = (histogram[sample] ?? 0) + 1;
      }
      final entries = histogram.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      lines.add(
        'samples=${entries.take(16).map((e) => '${e.key}:${e.value}').join(' ')}',
      );
    } on Exception {
      lines.add('samples=(decode failed)');
    }
  }
  return lines;
}
