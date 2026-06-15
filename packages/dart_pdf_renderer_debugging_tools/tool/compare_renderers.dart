import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_pdf_renderer/dart_pdf_renderer.dart';
import 'package:image/image.dart' as image;
import 'package:pdf_document/pdf_document.dart' as dart_pdf;
import 'package:pdfrx_engine/pdfrx_engine.dart' as pdfrx;

const _usage = '''
usage:
  dart run tool/compare_renderers.dart <pdf> <page> <x1> <y1> <x2> <y2> <scale> [output-prefix] [options]

arguments:
  page          1-based page number
  x1..y2        normalized page region, each value is 0.0 to 1.0
  scale         pixels per PDF point for the full page

outputs:
  <prefix>.dart_pdf.png
  <prefix>.pdfium.png
  <prefix>.diff.png

options:
  --hotspots <n>     print up to n high-difference regions (default: 8)
  --tile <pixels>    hotspot tile size in output pixels (default: 64)
  --trace            print dart-pdf renderer operations intersecting the region
  --trace-limit <n>  maximum trace events to print (default: 200)
''';

Future<void> main(List<String> args) async {
  await _compareMain(args);
}

Future<void> _compareMain(List<String> args) async {
  if (args.length < 7) {
    stderr.write(_usage);
    exitCode = 64;
    return;
  }

  final request = _RenderRequest.parse(args.take(7).toList());
  var nextArg = 7;
  var prefix = _defaultPrefix(request);
  if (nextArg < args.length && !args[nextArg].startsWith('--')) {
    prefix = args[nextArg++];
  }
  final options = _CompareOptions.parse(args.skip(nextArg).toList());

  final dartPdfPath = '$prefix.dart_pdf.png';
  final pdfiumPath = '$prefix.pdfium.png';
  final diffPath = '$prefix.diff.png';

  final pdfium = pdfrx.PdfrxEntryFunctions.instance;
  await pdfium.init();
  try {
    await _renderWithDartPdf(request, dartPdfPath);
    await _renderWithPdfium(pdfium, request, pdfiumPath);

    final metrics = await _writeDiff(
      request,
      dartPdfPath,
      pdfiumPath,
      diffPath,
      options: options,
    );
    stdout.writeln('dart-pdf: $dartPdfPath');
    stdout.writeln('pdfium:   $pdfiumPath');
    stdout.writeln('diff:     $diffPath');
    stdout.writeln(
      'pixels: ${metrics.width}x${metrics.height}, '
      'different: ${metrics.differentPixels} '
      '(${metrics.differentRatio.toStringAsFixed(2)}%), '
      'avg delta: ${metrics.averageDelta.toStringAsFixed(2)}, '
      'max delta: ${metrics.maxDelta}',
    );
    if (metrics.hotspots.isNotEmpty) {
      stdout.writeln('hotspots:');
      for (var i = 0; i < metrics.hotspots.length; i++) {
        stdout.writeln('  ${i + 1}. ${metrics.hotspots[i]}');
      }
    }
    if (options.trace) {
      await _printTrace(request, options.traceLimit);
    }
  } finally {
    await pdfium.stopBackgroundWorker();
  }
}

Future<void> _renderWithDartPdf(_RenderRequest request, String output) async {
  final data = await File(request.pdfPath).readAsBytes();
  final doc = dart_pdf.PdfDocument.open(data, password: '');
  final renderer = PurePdfPageRenderer(doc);
  if (request.pageNumber < 1 ||
      request.pageNumber > renderer.pageSizes.length) {
    throw RangeError.range(
      request.pageNumber,
      1,
      renderer.pageSizes.length,
      'page',
    );
  }
  final pageSize = renderer.pageSizes[request.pageNumber - 1];
  final fullWidth = pageSize.width * request.scale;
  final fullHeight = pageSize.height * request.scale;
  final left = request.x1 * fullWidth;
  final top = request.y1 * fullHeight;
  final width = math.max(1, ((request.x2 - request.x1) * fullWidth).round());
  final height = math.max(1, ((request.y2 - request.y1) * fullHeight).round());
  final bgra = renderer.renderBgraRegion(
    pageNumber: request.pageNumber,
    x: left.roundToDouble(),
    y: top.roundToDouble(),
    width: width,
    height: height,
    pixelRatio: request.scale,
    backgroundColor: 0xffffffff,
    annotations: true,
  );
  await _writeBgraPng(bgra, width, height, output);
  stdout.writeln('dart-pdf rendered ${width}x$height');
}

Future<void> _renderWithPdfium(
  pdfrx.PdfrxEntryFunctions entryFunctions,
  _RenderRequest request,
  String output,
) async {
  final doc = await entryFunctions.openFile(request.pdfPath);
  try {
    if (request.pageNumber < 1 || request.pageNumber > doc.pages.length) {
      throw RangeError.range(request.pageNumber, 1, doc.pages.length, 'page');
    }
    final page = doc.pages[request.pageNumber - 1];
    final fullWidth = page.width * request.scale;
    final fullHeight = page.height * request.scale;
    final left = request.x1 * fullWidth;
    final top = request.y1 * fullHeight;
    final width = math.max(1, ((request.x2 - request.x1) * fullWidth).round());
    final height = math.max(
      1,
      ((request.y2 - request.y1) * fullHeight).round(),
    );
    final rendered = await page.render(
      x: left.round(),
      y: top.round(),
      width: width,
      height: height,
      fullWidth: fullWidth,
      fullHeight: fullHeight,
    );
    if (rendered == null) throw StateError('render returned null');
    try {
      await _writeBgraPng(
        Uint8List.fromList(rendered.pixels),
        rendered.width,
        rendered.height,
        output,
      );
      stdout.writeln('pdfium rendered ${rendered.width}x${rendered.height}');
    } finally {
      rendered.dispose();
    }
  } finally {
    await doc.dispose();
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

Future<void> _printTrace(_RenderRequest request, int limit) async {
  final data = await File(request.pdfPath).readAsBytes();
  final doc = dart_pdf.PdfDocument.open(data, password: '');
  final renderer = PurePdfPageRenderer(doc);
  final pageSize = renderer.pageSizes[request.pageNumber - 1];
  final x = request.x1 * pageSize.width * request.scale;
  final y = request.y1 * pageSize.height * request.scale;
  final width = math.max(
    1,
    ((request.x2 - request.x1) * pageSize.width * request.scale).round(),
  );
  final height = math.max(
    1,
    ((request.y2 - request.y1) * pageSize.height * request.scale).round(),
  );
  final trace = PdfRenderTrace(
    region: PdfRenderTraceRegion(0, 0, width.toDouble(), height.toDouble()),
  );
  renderer.renderRgbaRegion(
    pageNumber: request.pageNumber,
    x: x,
    y: y,
    width: width,
    height: height,
    pixelRatio: request.scale,
    backgroundColor: 0xffffffff,
    annotations: true,
    trace: trace,
  );
  stdout.writeln('trace: ${trace.events.length} events');
  for (final event in trace.events.take(limit)) {
    stdout.writeln('  $event');
  }
  if (trace.events.length > limit) {
    stdout.writeln('  ... ${trace.events.length - limit} more');
  }
}

Future<_DiffMetrics> _writeDiff(
  _RenderRequest request,
  String dartPdfPath,
  String pdfiumPath,
  String diffPath, {
  required _CompareOptions options,
}) async {
  final dartPdf = image.decodePng(await File(dartPdfPath).readAsBytes());
  final pdfium = image.decodePng(await File(pdfiumPath).readAsBytes());
  if (dartPdf == null) throw StateError('failed to decode $dartPdfPath');
  if (pdfium == null) throw StateError('failed to decode $pdfiumPath');
  if (dartPdf.width != pdfium.width || dartPdf.height != pdfium.height) {
    throw StateError(
      'image sizes differ: '
      '${dartPdf.width}x${dartPdf.height} vs ${pdfium.width}x${pdfium.height}',
    );
  }

  final diff = image.Image(width: dartPdf.width, height: dartPdf.height);
  final tileColumns = (dartPdf.width / options.tileSize).ceil();
  final tileRows = (dartPdf.height / options.tileSize).ceil();
  final tiles = List<_DiffTile>.generate(tileColumns * tileRows, (index) {
    final tx = index % tileColumns;
    final ty = index ~/ tileColumns;
    final x = tx * options.tileSize;
    final y = ty * options.tileSize;
    return _DiffTile(
      x: x,
      y: y,
      width: math.min(options.tileSize, dartPdf.width - x),
      height: math.min(options.tileSize, dartPdf.height - y),
    );
  });

  var differentPixels = 0;
  var totalDelta = 0;
  var maxDelta = 0;
  for (var y = 0; y < dartPdf.height; y++) {
    for (var x = 0; x < dartPdf.width; x++) {
      final a = dartPdf.getPixel(x, y);
      final b = pdfium.getPixel(x, y);
      final dr = (a.r - b.r).abs().toInt();
      final dg = (a.g - b.g).abs().toInt();
      final db = (a.b - b.b).abs().toInt();
      final da = (a.a - b.a).abs().toInt();
      final delta = math.max(math.max(dr, dg), math.max(db, da));
      if (delta != 0) differentPixels++;
      totalDelta += delta;
      maxDelta = math.max(maxDelta, delta);
      tiles[(y ~/ options.tileSize) * tileColumns + (x ~/ options.tileSize)]
          .add(delta);
      final v = math.min(255, delta * 4);
      diff.setPixelRgba(x, y, v, v, v, 255);
    }
  }

  await File(diffPath).writeAsBytes(image.encodePng(diff));
  final hotspots = tiles.where((tile) => tile.score > 0).toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  return _DiffMetrics(
    width: dartPdf.width,
    height: dartPdf.height,
    differentPixels: differentPixels,
    totalDelta: totalDelta,
    maxDelta: maxDelta,
    hotspots: hotspots
        .take(options.hotspotCount)
        .map((tile) => tile.toHotspot(request, dartPdf.width, dartPdf.height))
        .toList(),
  );
}

String _defaultPrefix(_RenderRequest request) {
  final pdf = File(request.pdfPath).uri.pathSegments.last;
  final dot = pdf.lastIndexOf('.');
  final stem = dot < 0 ? pdf : pdf.substring(0, dot);
  String n(double value) => value.toString().replaceAll('.', 'p');
  return '$stem.p${request.pageNumber}.'
      '${n(request.x1)}_${n(request.y1)}_${n(request.x2)}_${n(request.y2)}.'
      's${n(request.scale)}';
}

class _RenderRequest {
  _RenderRequest({
    required this.pdfPath,
    required this.pageNumber,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.scale,
  }) {
    for (final value in [x1, y1, x2, y2]) {
      if (value < 0 || value > 1) {
        throw ArgumentError.value(value, 'region', 'must be between 0 and 1');
      }
    }
    if (x1 >= x2 || y1 >= y2) {
      throw ArgumentError('region must satisfy x1 < x2 and y1 < y2');
    }
    if (scale <= 0) {
      throw ArgumentError.value(scale, 'scale', 'must be positive');
    }
  }

  factory _RenderRequest.parse(List<String> args) {
    return _RenderRequest(
      pdfPath: args[0],
      pageNumber: int.parse(args[1]),
      x1: double.parse(args[2]),
      y1: double.parse(args[3]),
      x2: double.parse(args[4]),
      y2: double.parse(args[5]),
      scale: double.parse(args[6]),
    );
  }

  final String pdfPath;
  final int pageNumber;
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final double scale;
}

class _CompareOptions {
  _CompareOptions({
    required this.hotspotCount,
    required this.tileSize,
    required this.trace,
    required this.traceLimit,
  });

  factory _CompareOptions.parse(List<String> args) {
    var hotspotCount = 8;
    var tileSize = 64;
    var trace = false;
    var traceLimit = 200;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--hotspots':
          hotspotCount = int.parse(args[++i]);
        case '--tile':
          tileSize = int.parse(args[++i]);
        case '--trace':
          trace = true;
        case '--trace-limit':
          traceLimit = int.parse(args[++i]);
        default:
          throw ArgumentError('unknown option: ${args[i]}');
      }
    }
    if (hotspotCount < 0) {
      throw ArgumentError.value(hotspotCount, 'hotspots', 'must be >= 0');
    }
    if (tileSize < 1) {
      throw ArgumentError.value(tileSize, 'tile', 'must be >= 1');
    }
    if (traceLimit < 1) {
      throw ArgumentError.value(traceLimit, 'trace-limit', 'must be >= 1');
    }
    return _CompareOptions(
      hotspotCount: hotspotCount,
      tileSize: tileSize,
      trace: trace,
      traceLimit: traceLimit,
    );
  }

  final int hotspotCount;
  final int tileSize;
  final bool trace;
  final int traceLimit;
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
    if (delta == 0) return;
    changedPixels++;
    totalDelta += delta;
    maxDelta = math.max(maxDelta, delta);
  }

  _Hotspot toHotspot(_RenderRequest request, int imageWidth, int imageHeight) {
    final regionWidth = request.x2 - request.x1;
    final regionHeight = request.y2 - request.y1;
    return _Hotspot(
      x1: request.x1 + regionWidth * x / imageWidth,
      y1: request.y1 + regionHeight * y / imageHeight,
      x2: request.x1 + regionWidth * (x + width) / imageWidth,
      y2: request.y1 + regionHeight * (y + height) / imageHeight,
      changedPixels: changedPixels,
      averageDelta: totalDelta / (width * height),
      maxDelta: maxDelta,
    );
  }
}

class _Hotspot {
  _Hotspot({
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

class _DiffMetrics {
  _DiffMetrics({
    required this.width,
    required this.height,
    required this.differentPixels,
    required this.totalDelta,
    required this.maxDelta,
    required this.hotspots,
  });

  final int width;
  final int height;
  final int differentPixels;
  final int totalDelta;
  final int maxDelta;
  final List<_Hotspot> hotspots;

  double get differentRatio => differentPixels * 100 / (width * height);

  double get averageDelta => totalDelta / (width * height);
}
