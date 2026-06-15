import 'dart:io';
import 'dart:math' as math;

import 'package:dart_pdf_renderer/dart_pdf_renderer.dart';
import 'package:pdf_document/pdf_document.dart';

const _usage = '''
usage:
  dart run tool/bench_pure_renderer.dart <pdf> [options]

options:
  --page <n>          1-based page number (default: 1)
  --scale <n>         pixels per PDF point (default: 2)
  --region <x1,y1,x2,y2>
                      normalized page region (default: 0,0,1,1)
  --fresh <n>         fresh renderer trials for first page render (default: 5)
  --hot <n>           repeated render trials after cache warmup (default: 10)
  --annotations       render annotations (default: false)
''';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.write(_usage);
    exitCode = 64;
    return;
  }

  final options = _Options.parse(args.skip(1).toList());
  if (options == null) {
    stderr.write(_usage);
    exitCode = 64;
    return;
  }

  final pdfPath = args.first;
  final readWatch = Stopwatch()..start();
  final bytes = File(pdfPath).readAsBytesSync();
  readWatch.stop();

  final openWatch = Stopwatch()..start();
  final document = PdfDocument.open(bytes, password: '');
  openWatch.stop();

  final sizingRenderer = PurePdfPageRenderer(document);
  final pageSize = sizingRenderer.pageSizes[options.pageNumber - 1];
  final request = _RenderRequest.fromPageSize(pageSize, options);

  stdout.writeln('runtime: ${Platform.version.split('\n').first}');
  stdout.writeln('executable: ${Platform.resolvedExecutable}');
  stdout.writeln('pdf: $pdfPath');
  stdout.writeln(
    'page=${options.pageNumber} region=${request.x.toStringAsFixed(1)},'
    '${request.y.toStringAsFixed(1)} ${request.width}x${request.height} '
    'scale=${options.scale.toStringAsFixed(3)} '
    'annotations=${options.annotations}',
  );
  stdout.writeln('read: ${readWatch.elapsedMilliseconds} ms');
  stdout.writeln('open: ${openWatch.elapsedMilliseconds} ms');

  final fresh = _TimingSamples();
  var checksum = 0;
  for (var i = 0; i < options.freshTrials; i++) {
    final renderer = PurePdfPageRenderer(document);
    final result = _timeRender(renderer, request, options);
    fresh.add(result);
    checksum ^= result.checksum;
  }
  fresh.print('fresh-renderer first render');

  final hotRenderer = PurePdfPageRenderer(document);
  final warmup = _timeRender(hotRenderer, request, options);
  checksum ^= warmup.checksum;
  stdout.writeln('hot warmup: ${warmup.summary}');

  final hot = _TimingSamples();
  for (var i = 0; i < options.hotTrials; i++) {
    final result = _timeRender(hotRenderer, request, options);
    hot.add(result);
    checksum ^= result.checksum;
  }
  hot.print('hot same-page render');
  stdout.writeln('checksum: $checksum');
}

_RenderResult _timeRender(
  PurePdfPageRenderer renderer,
  _RenderRequest request,
  _Options options,
) {
  final timing = PdfRenderTiming();
  final stopwatch = Stopwatch()..start();
  final bgra = renderer.renderBgraRegion(
    pageNumber: options.pageNumber,
    x: request.x,
    y: request.y,
    width: request.width,
    height: request.height,
    pixelRatio: options.scale,
    backgroundColor: 0xffffffff,
    annotations: options.annotations,
    timing: timing,
  );
  stopwatch.stop();

  var checksum = bgra.length;
  final stride = math.max(1, bgra.length ~/ 1024);
  for (var i = 0; i < bgra.length; i += stride) {
    checksum = 0x1fffffff & (checksum * 31 + bgra[i]);
  }
  return _RenderResult(
    elapsedMicroseconds: stopwatch.elapsedMicroseconds,
    checksum: checksum,
    displayListCacheHit: timing.displayListCacheHit,
    displayListBuildMicroseconds: timing.displayListBuildMicroseconds,
    surfaceClearMicroseconds: timing.surfaceClearMicroseconds,
    replayMicroseconds: timing.replayMicroseconds,
    bgraConversionMicroseconds: timing.bgraConversionMicroseconds,
    replayedCommands: timing.replayedCommands,
    culledCommands: timing.culledCommands,
    fillPathMicroseconds: timing.fillPathMicroseconds,
    strokePathMicroseconds: timing.strokePathMicroseconds,
    clipPathMicroseconds: timing.clipPathMicroseconds,
    drawTextMicroseconds: timing.drawTextMicroseconds,
    drawImageMicroseconds: timing.drawImageMicroseconds,
    groupMicroseconds: timing.groupMicroseconds,
    otherCommandMicroseconds: timing.otherCommandMicroseconds,
    glyphRequests: timing.glyphRequests,
    glyphCacheHits: timing.glyphCacheHits,
    glyphMasksCreated: timing.glyphMasksCreated,
    glyphFallbacks: timing.glyphFallbacks,
    glyphMaskCreateMicroseconds: timing.glyphMaskCreateMicroseconds,
    glyphMaskPaintMicroseconds: timing.glyphMaskPaintMicroseconds,
  );
}

void _printStats(String label, List<int> values, {bool samples = false}) {
  if (values.isEmpty) return;
  final sorted = [...values]..sort();
  final total = values.fold<int>(0, (sum, value) => sum + value);
  final sampleSuffix = samples
      ? ' samples=[${values.map(_ms).join(', ')}]'
      : '';
  stdout.writeln(
    '$label: '
    'min=${_ms(sorted.first)} ms '
    'median=${_ms(sorted[sorted.length ~/ 2])} ms '
    'avg=${_ms(total ~/ values.length)} ms '
    'max=${_ms(sorted.last)} ms'
    '$sampleSuffix',
  );
}

String _ms(int microseconds) => (microseconds / 1000).toStringAsFixed(2);

class _RenderResult {
  const _RenderResult({
    required this.elapsedMicroseconds,
    required this.checksum,
    required this.displayListCacheHit,
    required this.displayListBuildMicroseconds,
    required this.surfaceClearMicroseconds,
    required this.replayMicroseconds,
    required this.bgraConversionMicroseconds,
    required this.replayedCommands,
    required this.culledCommands,
    required this.fillPathMicroseconds,
    required this.strokePathMicroseconds,
    required this.clipPathMicroseconds,
    required this.drawTextMicroseconds,
    required this.drawImageMicroseconds,
    required this.groupMicroseconds,
    required this.otherCommandMicroseconds,
    required this.glyphRequests,
    required this.glyphCacheHits,
    required this.glyphMasksCreated,
    required this.glyphFallbacks,
    required this.glyphMaskCreateMicroseconds,
    required this.glyphMaskPaintMicroseconds,
  });

  final int elapsedMicroseconds;
  final int checksum;
  final bool displayListCacheHit;
  final int displayListBuildMicroseconds;
  final int surfaceClearMicroseconds;
  final int replayMicroseconds;
  final int bgraConversionMicroseconds;
  final int replayedCommands;
  final int culledCommands;
  final int fillPathMicroseconds;
  final int strokePathMicroseconds;
  final int clipPathMicroseconds;
  final int drawTextMicroseconds;
  final int drawImageMicroseconds;
  final int groupMicroseconds;
  final int otherCommandMicroseconds;
  final int glyphRequests;
  final int glyphCacheHits;
  final int glyphMasksCreated;
  final int glyphFallbacks;
  final int glyphMaskCreateMicroseconds;
  final int glyphMaskPaintMicroseconds;

  String get summary =>
      'total=${_ms(elapsedMicroseconds)} ms '
      'build=${_ms(displayListBuildMicroseconds)} ms '
      'clear=${_ms(surfaceClearMicroseconds)} ms '
      'replay=${_ms(replayMicroseconds)} ms '
      'bgra=${_ms(bgraConversionMicroseconds)} ms '
      'text=${_ms(drawTextMicroseconds)} ms '
      'image=${_ms(drawImageMicroseconds)} ms '
      'fill=${_ms(fillPathMicroseconds)} ms '
      'glyphs=$glyphCacheHits/$glyphRequests '
      'commands=$replayedCommands/$culledCommands '
      'cacheHit=$displayListCacheHit';
}

class _TimingSamples {
  final total = <int>[];
  final build = <int>[];
  final clear = <int>[];
  final replay = <int>[];
  final bgra = <int>[];
  final fill = <int>[];
  final stroke = <int>[];
  final clip = <int>[];
  final text = <int>[];
  final image = <int>[];
  final group = <int>[];
  final other = <int>[];
  final glyphCreate = <int>[];
  final glyphPaint = <int>[];
  var cacheHits = 0;
  var replayedCommands = 0;
  var culledCommands = 0;
  var glyphRequests = 0;
  var glyphCacheHits = 0;
  var glyphMasksCreated = 0;
  var glyphFallbacks = 0;

  void add(_RenderResult result) {
    total.add(result.elapsedMicroseconds);
    build.add(result.displayListBuildMicroseconds);
    clear.add(result.surfaceClearMicroseconds);
    replay.add(result.replayMicroseconds);
    bgra.add(result.bgraConversionMicroseconds);
    fill.add(result.fillPathMicroseconds);
    stroke.add(result.strokePathMicroseconds);
    clip.add(result.clipPathMicroseconds);
    text.add(result.drawTextMicroseconds);
    image.add(result.drawImageMicroseconds);
    group.add(result.groupMicroseconds);
    other.add(result.otherCommandMicroseconds);
    glyphCreate.add(result.glyphMaskCreateMicroseconds);
    glyphPaint.add(result.glyphMaskPaintMicroseconds);
    if (result.displayListCacheHit) cacheHits++;
    replayedCommands += result.replayedCommands;
    culledCommands += result.culledCommands;
    glyphRequests += result.glyphRequests;
    glyphCacheHits += result.glyphCacheHits;
    glyphMasksCreated += result.glyphMasksCreated;
    glyphFallbacks += result.glyphFallbacks;
  }

  void print(String label) {
    final divisor = total.isEmpty ? 1 : total.length;
    stdout.writeln(
      '$label: cacheHits=$cacheHits/${total.length} '
      'avgCommands=${replayedCommands ~/ divisor}/'
      '${culledCommands ~/ divisor} '
      'avgGlyphs=${glyphCacheHits ~/ divisor}/'
      '${glyphRequests ~/ divisor} '
      'created=${glyphMasksCreated ~/ divisor} '
      'fallback=${glyphFallbacks ~/ divisor}',
    );
    _printStats('  total', total, samples: true);
    _printStats('  build', build);
    _printStats('  clear', clear);
    _printStats('  replay', replay);
    _printStats('  bgra', bgra);
    _printStats('  text', text);
    _printStats('  image', image);
    _printStats('  fill', fill);
    _printStats('  stroke', stroke);
    _printStats('  clip', clip);
    _printStats('  group', group);
    _printStats('  other', other);
    _printStats('  glyph-create', glyphCreate);
    _printStats('  glyph-paint', glyphPaint);
  }
}

class _RenderRequest {
  const _RenderRequest({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory _RenderRequest.fromPageSize(PdfPageSize pageSize, _Options options) {
    final fullWidth = pageSize.width * options.scale;
    final fullHeight = pageSize.height * options.scale;
    final left = options.region[0] * fullWidth;
    final top = options.region[1] * fullHeight;
    return _RenderRequest(
      x: left,
      y: top,
      width: math.max(
        1,
        ((options.region[2] - options.region[0]) * fullWidth).round(),
      ),
      height: math.max(
        1,
        ((options.region[3] - options.region[1]) * fullHeight).round(),
      ),
    );
  }

  final double x;
  final double y;
  final int width;
  final int height;
}

class _Options {
  const _Options({
    required this.pageNumber,
    required this.scale,
    required this.region,
    required this.freshTrials,
    required this.hotTrials,
    required this.annotations,
  });

  final int pageNumber;
  final double scale;
  final List<double> region;
  final int freshTrials;
  final int hotTrials;
  final bool annotations;

  static _Options? parse(List<String> args) {
    var pageNumber = 1;
    var scale = 2.0;
    var region = const [0.0, 0.0, 1.0, 1.0];
    var freshTrials = 5;
    var hotTrials = 10;
    var annotations = false;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      switch (arg) {
        case '--page':
          pageNumber = int.parse(args[++i]);
        case '--scale':
          scale = double.parse(args[++i]);
        case '--region':
          final values = args[++i].split(',').map(double.parse).toList();
          if (values.length != 4) return null;
          region = values;
        case '--fresh':
          freshTrials = int.parse(args[++i]);
        case '--hot':
          hotTrials = int.parse(args[++i]);
        case '--annotations':
          annotations = true;
        default:
          return null;
      }
    }

    if (pageNumber < 1 || scale <= 0 || freshTrials < 0 || hotTrials < 0) {
      return null;
    }
    if (region[0] < 0 ||
        region[1] < 0 ||
        region[2] > 1 ||
        region[3] > 1 ||
        region[0] >= region[2] ||
        region[1] >= region[3]) {
      return null;
    }

    return _Options(
      pageNumber: pageNumber,
      scale: scale,
      region: region,
      freshTrials: freshTrials,
      hotTrials: hotTrials,
      annotations: annotations,
    );
  }
}
