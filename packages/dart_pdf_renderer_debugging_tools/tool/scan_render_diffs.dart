import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_pdf_renderer/dart_pdf_renderer.dart';
import 'package:image/image.dart' as image;
import 'package:pdf_document/pdf_document.dart' as dart_pdf;
import 'package:pdfrx_engine/pdfrx_engine.dart' as pdfrx;

const _usage = '''
usage:
  dart run tool/scan_render_diffs.dart <pdf> [options]

options:
  --pages <spec>       page numbers/ranges, for example 1-5,12,60 (default: all)
  --scale <n>          pixels per PDF point (default: 1)
  --top <n>            number of worst pages to print after the scan (default: 10)
  --tile <pixels>      hotspot tile size in output pixels (default: 64)
  --threshold <delta>  ignore pixel channel deltas up to this value when
                       counting changed pixels/hotspots (default: 0)
  --write-worst <n>    write PNG triplets for the n worst pages (default: 0)
  --out <directory>    directory for PNG triplets (default: tmp/render_diff_scan)
  --annotations        render annotations (default: false)

outputs:
  per-page summary lines and, with --write-worst, these files:
    pNNNN.dart_pdf.png
    pNNNN.pdfium.png
    pNNNN.diff.png
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

  await _scan(options);
}

Future<void> _scan(_Options options) async {
  final pdfium = pdfrx.PdfrxEntryFunctions.instance;
  await pdfium.init();

  final pdfBytes = await File(options.pdfPath).readAsBytes();
  final dartPdfDoc = dart_pdf.PdfDocument.open(pdfBytes, password: '');
  final dartPdfRenderer = PurePdfPageRenderer(dartPdfDoc);
  final pdfiumDoc = await pdfium.openFile(options.pdfPath);
  try {
    final pageCount = math.min(
      dartPdfRenderer.pageSizes.length,
      pdfiumDoc.pages.length,
    );
    final pages = _expandPages(options.pagesSpec, pageCount);
    stdout.writeln('pdf: ${options.pdfPath}');
    stdout.writeln(
      'pages=${_formatPageSet(pages)} scale=${options.scale} '
      'threshold=${options.threshold} annotations=${options.annotations}',
    );

    final totalWatch = Stopwatch()..start();
    final results = <_PageDiff>[];
    for (final pageNumber in pages) {
      final result = await _comparePage(
        dartPdfRenderer,
        pdfiumDoc,
        pageNumber,
        options,
      );
      results.add(result);
      stdout.writeln(result.summaryLine);
    }
    totalWatch.stop();

    results.sort(_compareDiffDescending);
    final shown = math.min(options.top, results.length);
    stdout.writeln('');
    stdout.writeln('worst pages by average delta:');
    for (var i = 0; i < shown; i++) {
      stdout.writeln('  ${i + 1}. ${results[i].summaryLine}');
      for (final hotspot in results[i].hotspots.take(3)) {
        stdout.writeln('     hotspot $hotspot');
      }
    }
    stdout.writeln(
      'scanned ${results.length} pages in ${totalWatch.elapsedMilliseconds} ms',
    );

    if (options.writeWorst > 0) {
      final outputDirectory = Directory(options.outputDirectory);
      await outputDirectory.create(recursive: true);
      final written = math.min(options.writeWorst, results.length);
      for (var i = 0; i < written; i++) {
        await _writePageOutputs(
          dartPdfRenderer,
          pdfiumDoc,
          results[i].pageNumber,
          options,
        );
      }
      stdout.writeln(
        'wrote PNG triplets for $written pages to ${outputDirectory.path}',
      );
    }
  } finally {
    await pdfiumDoc.dispose();
    await pdfium.stopBackgroundWorker();
  }
}

Future<_PageDiff> _comparePage(
  PurePdfPageRenderer dartPdfRenderer,
  pdfrx.PdfDocument pdfiumDoc,
  int pageNumber,
  _Options options,
) async {
  final dartPdf = _renderDartPdfPage(dartPdfRenderer, pageNumber, options);
  final pdfium = await _renderPdfiumPage(pdfiumDoc, pageNumber, options);
  try {
    final metrics = _diffBgra(
      pageNumber: pageNumber,
      dartPdf: dartPdf.pixels,
      pdfium: pdfium.pixels,
      width: dartPdf.width,
      height: dartPdf.height,
      tileSize: options.tileSize,
      threshold: options.threshold,
    );
    return metrics.copyWith(
      dartPdfRenderMicroseconds: dartPdf.elapsedMicroseconds,
      pdfiumRenderMicroseconds: pdfium.elapsedMicroseconds,
    );
  } finally {
    dartPdf.dispose();
    pdfium.dispose();
  }
}

_RenderedPage _renderDartPdfPage(
  PurePdfPageRenderer renderer,
  int pageNumber,
  _Options options,
) {
  final pageSize = renderer.pageSizes[pageNumber - 1];
  final fullWidth = pageSize.width * options.scale;
  final fullHeight = pageSize.height * options.scale;
  final width = math.max(1, fullWidth.round());
  final height = math.max(1, fullHeight.round());
  final stopwatch = Stopwatch()..start();
  final bgra = renderer.renderBgraRegion(
    pageNumber: pageNumber,
    x: 0,
    y: 0,
    width: width,
    height: height,
    pixelRatio: options.scale,
    backgroundColor: 0xffffffff,
    annotations: options.annotations,
  );
  stopwatch.stop();
  return _RenderedPage(
    width: width,
    height: height,
    pixels: bgra,
    elapsedMicroseconds: stopwatch.elapsedMicroseconds,
    onDispose: () {},
  );
}

Future<_RenderedPage> _renderPdfiumPage(
  pdfrx.PdfDocument document,
  int pageNumber,
  _Options options,
) async {
  final page = document.pages[pageNumber - 1];
  final fullWidth = page.width * options.scale;
  final fullHeight = page.height * options.scale;
  final width = math.max(1, fullWidth.round());
  final height = math.max(1, fullHeight.round());
  final stopwatch = Stopwatch()..start();
  final rendered = await page.render(
    x: 0,
    y: 0,
    width: width,
    height: height,
    fullWidth: fullWidth,
    fullHeight: fullHeight,
    backgroundColor: 0xffffffff,
    annotationRenderingMode: options.annotations
        ? pdfrx.PdfAnnotationRenderingMode.annotationAndForms
        : pdfrx.PdfAnnotationRenderingMode.none,
  );
  stopwatch.stop();
  if (rendered == null) {
    throw StateError('render returned null for page $pageNumber');
  }
  return _RenderedPage(
    width: rendered.width,
    height: rendered.height,
    pixels: Uint8List.fromList(rendered.pixels),
    elapsedMicroseconds: stopwatch.elapsedMicroseconds,
    onDispose: rendered.dispose,
  );
}

_PageDiff _diffBgra({
  required int pageNumber,
  required Uint8List dartPdf,
  required Uint8List pdfium,
  required int width,
  required int height,
  required int tileSize,
  required int threshold,
}) {
  if (dartPdf.length != pdfium.length) {
    throw StateError(
      'pixel sizes differ for page $pageNumber: '
      '${dartPdf.length} vs ${pdfium.length}',
    );
  }

  final tileColumns = (width / tileSize).ceil();
  final tileRows = (height / tileSize).ceil();
  final tiles = List<_DiffTile>.generate(tileColumns * tileRows, (index) {
    final tx = index % tileColumns;
    final ty = index ~/ tileColumns;
    final x = tx * tileSize;
    final y = ty * tileSize;
    return _DiffTile(
      x: x,
      y: y,
      width: math.min(tileSize, width - x),
      height: math.min(tileSize, height - y),
    );
  });

  var differentPixels = 0;
  var totalDelta = 0;
  var maxDelta = 0;
  for (var y = 0; y < height; y++) {
    final rowOffset = y * width * 4;
    for (var x = 0; x < width; x++) {
      final offset = rowOffset + x * 4;
      final db = (dartPdf[offset] - pdfium[offset]).abs();
      final dg = (dartPdf[offset + 1] - pdfium[offset + 1]).abs();
      final dr = (dartPdf[offset + 2] - pdfium[offset + 2]).abs();
      final da = (dartPdf[offset + 3] - pdfium[offset + 3]).abs();
      final delta = math.max(math.max(dr, dg), math.max(db, da));
      totalDelta += delta;
      maxDelta = math.max(maxDelta, delta);
      if (delta <= threshold) continue;
      differentPixels++;
      tiles[(y ~/ tileSize) * tileColumns + (x ~/ tileSize)].add(delta);
    }
  }

  final hotspots = tiles.where((tile) => tile.score > 0).toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  return _PageDiff(
    pageNumber: pageNumber,
    width: width,
    height: height,
    differentPixels: differentPixels,
    totalDelta: totalDelta,
    maxDelta: maxDelta,
    hotspots: hotspots.map((tile) => tile.toHotspot(width, height)).toList(),
    dartPdfRenderMicroseconds: 0,
    pdfiumRenderMicroseconds: 0,
  );
}

Future<void> _writePageOutputs(
  PurePdfPageRenderer dartPdfRenderer,
  pdfrx.PdfDocument pdfiumDoc,
  int pageNumber,
  _Options options,
) async {
  final dartPdf = _renderDartPdfPage(dartPdfRenderer, pageNumber, options);
  final pdfium = await _renderPdfiumPage(pdfiumDoc, pageNumber, options);
  try {
    final stem = 'p${pageNumber.toString().padLeft(4, '0')}';
    final dartPdfPath = '${options.outputDirectory}\\$stem.dart_pdf.png';
    final pdfiumPath = '${options.outputDirectory}\\$stem.pdfium.png';
    final diffPath = '${options.outputDirectory}\\$stem.diff.png';
    await _writeBgraPng(
      dartPdf.pixels,
      dartPdf.width,
      dartPdf.height,
      dartPdfPath,
    );
    await _writeBgraPng(pdfium.pixels, pdfium.width, pdfium.height, pdfiumPath);
    await _writeDiffPng(
      dartPdf.pixels,
      pdfium.pixels,
      dartPdf.width,
      dartPdf.height,
      diffPath,
    );
    stdout.writeln('wrote page $pageNumber: $dartPdfPath');
  } finally {
    dartPdf.dispose();
    pdfium.dispose();
  }
}

Future<void> _writeBgraPng(
  Uint8List bgra,
  int width,
  int height,
  String output,
) async {
  final rgba = Uint8List(bgra.length);
  for (var i = 0; i < bgra.length; i += 4) {
    rgba[i] = bgra[i + 2];
    rgba[i + 1] = bgra[i + 1];
    rgba[i + 2] = bgra[i];
    rgba[i + 3] = bgra[i + 3];
  }
  final png = image.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
  );
  await File(output).writeAsBytes(image.encodePng(png));
}

Future<void> _writeDiffPng(
  Uint8List dartPdf,
  Uint8List pdfium,
  int width,
  int height,
  String output,
) async {
  final diff = image.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    final rowOffset = y * width * 4;
    for (var x = 0; x < width; x++) {
      final offset = rowOffset + x * 4;
      final db = (dartPdf[offset] - pdfium[offset]).abs();
      final dg = (dartPdf[offset + 1] - pdfium[offset + 1]).abs();
      final dr = (dartPdf[offset + 2] - pdfium[offset + 2]).abs();
      final da = (dartPdf[offset + 3] - pdfium[offset + 3]).abs();
      final delta = math.max(math.max(dr, dg), math.max(db, da));
      final v = math.min(255, delta * 4);
      diff.setPixelRgba(x, y, v, v, v, 255);
    }
  }
  await File(output).writeAsBytes(image.encodePng(diff));
}

List<int> _expandPages(String? spec, int pageCount) {
  if (spec == null || spec.trim().isEmpty || spec == 'all') {
    return [for (var i = 1; i <= pageCount; i++) i];
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
  final sorted = pages.toList()..sort();
  return sorted;
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

int _compareDiffDescending(_PageDiff a, _PageDiff b) {
  final average = b.averageDelta.compareTo(a.averageDelta);
  if (average != 0) return average;
  final ratio = b.differentRatio.compareTo(a.differentRatio);
  if (ratio != 0) return ratio;
  return b.maxDelta.compareTo(a.maxDelta);
}

String _ms(int microseconds) => (microseconds / 1000).toStringAsFixed(1);

class _Options {
  const _Options({
    required this.pdfPath,
    required this.pagesSpec,
    required this.scale,
    required this.top,
    required this.tileSize,
    required this.threshold,
    required this.writeWorst,
    required this.outputDirectory,
    required this.annotations,
  });

  final String pdfPath;
  final String? pagesSpec;
  final double scale;
  final int top;
  final int tileSize;
  final int threshold;
  final int writeWorst;
  final String outputDirectory;
  final bool annotations;

  static _Options? parse(List<String> args) {
    final pdfPath = args.first;
    String? pagesSpec;
    var scale = 1.0;
    var top = 10;
    var tileSize = 64;
    var threshold = 0;
    var writeWorst = 0;
    var outputDirectory = 'tmp\\render_diff_scan';
    var annotations = false;

    for (var i = 1; i < args.length; i++) {
      switch (args[i]) {
        case '--pages':
          pagesSpec = args[++i];
        case '--scale':
          scale = double.parse(args[++i]);
        case '--top':
          top = int.parse(args[++i]);
        case '--tile':
          tileSize = int.parse(args[++i]);
        case '--threshold':
          threshold = int.parse(args[++i]);
        case '--write-worst':
          writeWorst = int.parse(args[++i]);
        case '--out':
          outputDirectory = args[++i];
        case '--annotations':
          annotations = true;
        default:
          return null;
      }
    }

    if (scale <= 0 ||
        top < 0 ||
        tileSize < 1 ||
        threshold < 0 ||
        threshold > 255 ||
        writeWorst < 0) {
      return null;
    }

    return _Options(
      pdfPath: pdfPath,
      pagesSpec: pagesSpec,
      scale: scale,
      top: top,
      tileSize: tileSize,
      threshold: threshold,
      writeWorst: writeWorst,
      outputDirectory: outputDirectory,
      annotations: annotations,
    );
  }
}

class _RenderedPage {
  const _RenderedPage({
    required this.width,
    required this.height,
    required this.pixels,
    required this.elapsedMicroseconds,
    required this.onDispose,
  });

  final int width;
  final int height;
  final Uint8List pixels;
  final int elapsedMicroseconds;
  final void Function() onDispose;

  void dispose() => onDispose();
}

class _DiffTile {
  _DiffTile({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  var totalDelta = 0;
  var maxDelta = 0;
  var changedPixels = 0;

  int get score => totalDelta;

  void add(int delta) {
    changedPixels++;
    totalDelta += delta;
    maxDelta = math.max(maxDelta, delta);
  }

  _Hotspot toHotspot(int imageWidth, int imageHeight) {
    return _Hotspot(
      x1: x / imageWidth,
      y1: y / imageHeight,
      x2: (x + width) / imageWidth,
      y2: (y + height) / imageHeight,
      changedPixels: changedPixels,
      averageDelta: totalDelta / (width * height),
      maxDelta: maxDelta,
    );
  }
}

class _Hotspot {
  const _Hotspot({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.changedPixels,
    required this.averageDelta,
    required this.maxDelta,
  });

  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final int changedPixels;
  final double averageDelta;
  final int maxDelta;

  @override
  String toString() {
    String f(double value) => value.toStringAsFixed(4);
    return '${f(x1)} ${f(y1)} ${f(x2)} ${f(y2)} '
        'changed=$changedPixels avg=${averageDelta.toStringAsFixed(2)} '
        'max=$maxDelta';
  }
}

class _PageDiff {
  const _PageDiff({
    required this.pageNumber,
    required this.width,
    required this.height,
    required this.differentPixels,
    required this.totalDelta,
    required this.maxDelta,
    required this.hotspots,
    required this.dartPdfRenderMicroseconds,
    required this.pdfiumRenderMicroseconds,
  });

  final int pageNumber;
  final int width;
  final int height;
  final int differentPixels;
  final int totalDelta;
  final int maxDelta;
  final List<_Hotspot> hotspots;
  final int dartPdfRenderMicroseconds;
  final int pdfiumRenderMicroseconds;

  double get differentRatio => differentPixels * 100 / (width * height);

  double get averageDelta => totalDelta / (width * height);

  String get summaryLine =>
      'page=$pageNumber ${width}x$height '
      'different=${differentRatio.toStringAsFixed(2)}% '
      'avg=${averageDelta.toStringAsFixed(2)} max=$maxDelta '
      'dart-pdf=${_ms(dartPdfRenderMicroseconds)}ms '
      'pdfium=${_ms(pdfiumRenderMicroseconds)}ms';

  _PageDiff copyWith({
    required int dartPdfRenderMicroseconds,
    required int pdfiumRenderMicroseconds,
  }) {
    return _PageDiff(
      pageNumber: pageNumber,
      width: width,
      height: height,
      differentPixels: differentPixels,
      totalDelta: totalDelta,
      maxDelta: maxDelta,
      hotspots: hotspots,
      dartPdfRenderMicroseconds: dartPdfRenderMicroseconds,
      pdfiumRenderMicroseconds: pdfiumRenderMicroseconds,
    );
  }
}
