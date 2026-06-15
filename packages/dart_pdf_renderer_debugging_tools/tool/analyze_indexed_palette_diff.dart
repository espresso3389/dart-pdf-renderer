import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_pdf_renderer/dart_pdf_renderer.dart';
// ignore: implementation_imports
import 'package:dart_pdf_renderer/src/pdfium_cmyk.dart';
import 'package:pdf_cos/pdf_cos.dart' as cos;
import 'package:pdf_document/pdf_document.dart' as dart_pdf;
import 'package:pdf_graphics/pdf_graphics.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart' as pdfrx;

const _usage = '''
usage:
  dart run tool/analyze_indexed_palette_diff.dart <pdf> [options]

options:
  --pages <spec>       page numbers/ranges, for example 51,55,112 (default: 1)
  --scale <n>          pixels per PDF point (default: 1)
  --tolerance <delta>  max channel delta for matching pure palette pixels
                       (default: 3)
  --min-pixels <n>     hide palette entries with fewer matches (default: 50)

Prints, for each Indexed DeviceCMYK image palette entry, the current pure-Dart
fallback RGB and the average PDFium RGB at pixels where the pure render matched
that palette color.
''';

Future<void> main(List<String> args) async {
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

  final pdfium = pdfrx.PdfrxEntryFunctions.instance;
  await pdfium.init();

  final pdfBytes = await File(options.pdfPath).readAsBytes();
  final cosDocument = dart_pdf.PdfDocument.open(pdfBytes, password: '');
  final pureRenderer = PurePdfPageRenderer(cosDocument);
  final pdfiumDoc = await pdfium.openFile(options.pdfPath);
  try {
    final pageCount = math.min(
      cosDocument.pageCount,
      pureRenderer.pageSizes.length,
    );
    final pages = _expandPages(options.pagesSpec, pageCount);
    stdout.writeln(
      'pdf: ${options.pdfPath} pages=${_formatPageSet(pages)} '
      'scale=${options.scale} tolerance=${options.tolerance}',
    );
    for (final pageNumber in pages) {
      final palettes = _indexedDeviceCmykPalettes(cosDocument, pageNumber);
      stdout.writeln('page=$pageNumber indexedDeviceCmyk=${palettes.length}');
      if (palettes.isEmpty) continue;

      final pure = _renderPurePage(pureRenderer, pageNumber, options.scale);
      final pdfiumPage = await _renderPdfiumPage(
        pdfiumDoc,
        pageNumber,
        options.scale,
      );
      try {
        for (var i = 0; i < palettes.length; i++) {
          final palette = palettes[i];
          stdout.writeln(
            '  image ${i + 1}. ${palette.path} '
            '${palette.width}x${palette.height} entries=${palette.colors.length}',
          );
          for (var entry = 0; entry < palette.colors.length; entry++) {
            final cmyk = palette.colors[entry];
            final pureRgb = _defaultCmykToRgb(cmyk);
            final sample = _sampleMatchingPixels(
              pure: pure.pixels,
              pdfium: pdfiumPage.pixels,
              width: pure.width,
              height: pure.height,
              pureRgb: pureRgb,
              tolerance: options.tolerance,
            );
            if (sample.count < options.minPixels) continue;
            stdout.writeln(
              '    [$entry] cmyk=${cmyk.join(',')} '
              'pure=${pureRgb.format()} '
              'pdfium=${sample.pdfiumRgb.format()} '
              'count=${sample.count} '
              'avgDelta=${sample.averageDelta.toStringAsFixed(2)}',
            );
          }
        }
      } finally {
        pure.dispose();
        pdfiumPage.dispose();
      }
    }
  } finally {
    await pdfiumDoc.dispose();
    await pdfium.stopBackgroundWorker();
  }
}

List<_IndexedPalette> _indexedDeviceCmykPalettes(
  dart_pdf.PdfDocument document,
  int pageNumber,
) {
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

  final palettes = <_IndexedPalette>[];
  for (final image in images) {
    final palette = _indexedDeviceCmykPalette(document.cos, image);
    if (palette != null) palettes.add(palette);
  }
  return palettes;
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
      images.add(_ImageUse(childPath, xObject));
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

_IndexedPalette? _indexedDeviceCmykPalette(
  cos.CosDocument document,
  _ImageUse image,
) {
  final dictionary = image.stream.dictionary;
  final colorSpace = document.resolve(dictionary['ColorSpace']);
  if (colorSpace is! cos.CosArray || colorSpace.length < 4) return null;
  final family = document.resolve(colorSpace[0]);
  if (family is! cos.CosName ||
      (family.value != 'Indexed' && family.value != 'I')) {
    return null;
  }
  final base = document.resolve(colorSpace[1]);
  if (base is! cos.CosName ||
      (base.value != 'DeviceCMYK' && base.value != 'CMYK')) {
    return null;
  }

  final highValue = _intValue(document.resolve(colorSpace[2]));
  final lookup = _lookupBytes(document, colorSpace[3]);
  if (highValue < 0 || lookup == null) return null;
  final colors = <List<int>>[];
  for (var i = 0; i <= highValue; i++) {
    final offset = i * 4;
    if (offset + 4 > lookup.length) break;
    colors.add(lookup.sublist(offset, offset + 4));
  }

  return _IndexedPalette(
    image.path,
    _intValue(document.resolve(dictionary['Width'])),
    _intValue(document.resolve(dictionary['Height'])),
    colors,
  );
}

Uint8List? _lookupBytes(cos.CosDocument document, cos.CosObject object) {
  final resolved = document.resolve(object);
  if (resolved is cos.CosString) return resolved.bytes;
  if (resolved is cos.CosStream) return document.decodeStreamData(resolved);
  return null;
}

_RenderedPage _renderPurePage(
  PurePdfPageRenderer renderer,
  int pageNumber,
  double scale,
) {
  final pageSize = renderer.pageSizes[pageNumber - 1];
  final fullWidth = pageSize.width * scale;
  final fullHeight = pageSize.height * scale;
  final width = math.max(1, fullWidth.round());
  final height = math.max(1, fullHeight.round());
  final bgra = renderer.renderBgraRegion(
    pageNumber: pageNumber,
    x: 0,
    y: 0,
    width: width,
    height: height,
    pixelRatio: scale,
    backgroundColor: 0xffffffff,
    annotations: false,
  );
  return _RenderedPage(
    width: width,
    height: height,
    pixels: bgra,
    onDispose: () {},
  );
}

Future<_RenderedPage> _renderPdfiumPage(
  pdfrx.PdfDocument document,
  int pageNumber,
  double scale,
) async {
  final page = document.pages[pageNumber - 1];
  final fullWidth = page.width * scale;
  final fullHeight = page.height * scale;
  final rendered = await page.render(
    x: 0,
    y: 0,
    width: math.max(1, fullWidth.round()),
    height: math.max(1, fullHeight.round()),
    fullWidth: fullWidth,
    fullHeight: fullHeight,
    backgroundColor: 0xffffffff,
    annotationRenderingMode: pdfrx.PdfAnnotationRenderingMode.none,
  );
  if (rendered == null) {
    throw StateError('render returned null for page $pageNumber');
  }
  return _RenderedPage(
    width: rendered.width,
    height: rendered.height,
    pixels: Uint8List.fromList(rendered.pixels),
    onDispose: rendered.dispose,
  );
}

_PaletteSample _sampleMatchingPixels({
  required Uint8List pure,
  required Uint8List pdfium,
  required int width,
  required int height,
  required _Rgb pureRgb,
  required int tolerance,
}) {
  var count = 0;
  var pureR = 0;
  var pureG = 0;
  var pureB = 0;
  var pdfiumR = 0;
  var pdfiumG = 0;
  var pdfiumB = 0;
  var totalDelta = 0;
  for (var y = 0; y < height; y++) {
    var offset = y * width * 4;
    for (var x = 0; x < width; x++) {
      final b = pure[offset];
      final g = pure[offset + 1];
      final r = pure[offset + 2];
      if ((r - pureRgb.r).abs() <= tolerance &&
          (g - pureRgb.g).abs() <= tolerance &&
          (b - pureRgb.b).abs() <= tolerance) {
        final pb = pdfium[offset];
        final pg = pdfium[offset + 1];
        final pr = pdfium[offset + 2];
        count++;
        pureR += r;
        pureG += g;
        pureB += b;
        pdfiumR += pr;
        pdfiumG += pg;
        pdfiumB += pb;
        totalDelta += math.max(
          math.max((r - pr).abs(), (g - pg).abs()),
          (b - pb).abs(),
        );
      }
      offset += 4;
    }
  }
  if (count == 0) return const _PaletteSample.empty();
  return _PaletteSample(
    count,
    _Rgb(
      (pureR / count).round(),
      (pureG / count).round(),
      (pureB / count).round(),
    ),
    _Rgb(
      (pdfiumR / count).round(),
      (pdfiumG / count).round(),
      (pdfiumB / count).round(),
    ),
    totalDelta / count,
  );
}

_Rgb _defaultCmykToRgb(List<int> cmyk) {
  final rgb = List<int>.filled(3, 0);
  pdfiumCmykToRgb(cmyk[0], cmyk[1], cmyk[2], cmyk[3], rgb);
  return _Rgb(rgb[0], rgb[1], rgb[2]);
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

String _formatPageSet(List<int> pages) {
  if (pages.isEmpty) return '(none)';
  final ranges = <String>[];
  var start = pages.first;
  var previous = pages.first;
  for (final page in pages.skip(1)) {
    if (page == previous + 1) {
      previous = page;
      continue;
    }
    ranges.add(start == previous ? '$start' : '$start-$previous');
    start = page;
    previous = page;
  }
  ranges.add(start == previous ? '$start' : '$start-$previous');
  return ranges.join(',');
}

String? _nameValue(cos.CosObject? object) =>
    object is cos.CosName ? object.value : null;

int _intValue(cos.CosObject? object) => switch (object) {
  cos.CosInteger(:final value) => value,
  cos.CosReal(:final value) => value.round(),
  _ => 0,
};

class _Options {
  const _Options({
    required this.pdfPath,
    required this.pagesSpec,
    required this.scale,
    required this.tolerance,
    required this.minPixels,
  });

  final String pdfPath;
  final String? pagesSpec;
  final double scale;
  final int tolerance;
  final int minPixels;

  static _Options? parse(List<String> args) {
    final pdfPath = args.first;
    String? pagesSpec;
    var scale = 1.0;
    var tolerance = 3;
    var minPixels = 50;
    for (var i = 1; i < args.length; i++) {
      switch (args[i]) {
        case '--pages':
          pagesSpec = args[++i];
        case '--scale':
          scale = double.parse(args[++i]);
        case '--tolerance':
          tolerance = int.parse(args[++i]);
        case '--min-pixels':
          minPixels = int.parse(args[++i]);
        default:
          return null;
      }
    }
    if (scale <= 0 || tolerance < 0 || minPixels < 0) return null;
    return _Options(
      pdfPath: pdfPath,
      pagesSpec: pagesSpec,
      scale: scale,
      tolerance: tolerance,
      minPixels: minPixels,
    );
  }
}

class _ImageUse {
  const _ImageUse(this.path, this.stream);

  final String path;
  final cos.CosStream stream;
}

class _IndexedPalette {
  const _IndexedPalette(this.path, this.width, this.height, this.colors);

  final String path;
  final int width;
  final int height;
  final List<List<int>> colors;
}

class _RenderedPage {
  const _RenderedPage({
    required this.width,
    required this.height,
    required this.pixels,
    required this.onDispose,
  });

  final int width;
  final int height;
  final Uint8List pixels;
  final void Function() onDispose;

  void dispose() => onDispose();
}

class _PaletteSample {
  const _PaletteSample(
    this.count,
    this.pureRgb,
    this.pdfiumRgb,
    this.averageDelta,
  );

  const _PaletteSample.empty()
    : count = 0,
      pureRgb = const _Rgb(0, 0, 0),
      pdfiumRgb = const _Rgb(0, 0, 0),
      averageDelta = 0;

  final int count;
  final _Rgb pureRgb;
  final _Rgb pdfiumRgb;
  final double averageDelta;
}

class _Rgb {
  const _Rgb(this.r, this.g, this.b);

  final int r;
  final int g;
  final int b;

  String format() => '$r,$g,$b';
}
