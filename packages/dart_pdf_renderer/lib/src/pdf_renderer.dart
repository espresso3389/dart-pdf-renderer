import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;
// ignore: implementation_imports
import 'package:image/src/formats/jpeg/jpeg_data.dart' as image_internal;
import 'package:pdf_cos/pdf_cos.dart' as cos;
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart'
    hide
        PdfBeginGroupCommand,
        PdfClipPathCommand,
        PdfDrawImageCommand,
        PdfDrawTextCommand,
        PdfEndGroupCommand,
        PdfFillMeshCommand,
        PdfFillPathCommand,
        PdfFillPathGradientCommand,
        PdfRestoreCommand,
        PdfSaveCommand,
        PdfSetBlendModeCommand,
        PdfStrokePathCommand;

import 'pdf_display_command.dart';
import 'pdfium_cmyk.dart';

const _antiAliasSamplesPerAxis = 4;
const _antiAliasSampleCount =
    _antiAliasSamplesPerAxis * _antiAliasSamplesPerAxis;
const _antiAliasSampleScale = 1 / _antiAliasSampleCount;
const _minCubicFlattenSegments = 8;
const _midCubicFlattenSegments = 12;
const _maxCubicFlattenSegments = 16;
const _glyphTransformQuantization = 64;
const _glyphSubpixelQuantization = 1;
const _defaultMaxGlyphRasterPixels = 65536;
const _defaultMaxGlyphRasterCacheEntries = 2048;

/// A synchronous renderer for PDF pages backed by the pure Dart renderer.
class PdfPageRenderer {
  /// Creates a renderer for [document].
  ///
  /// Optional cache instances can be supplied to share or control cache state
  /// across renderer instances.
  PdfPageRenderer(
    this.document, {
    PdfGlyphRasterCache? glyphRasterCache,
    PdfImageDecodeCache? imageDecodeCache,
  }) : glyphRasterCache = glyphRasterCache ?? PdfGlyphRasterCache(),
       imageDecodeCache = imageDecodeCache ?? PdfImageDecodeCache();

  /// The PDF document rendered by this instance.
  final PdfDocument document;
  final _displayLists =
      <({bool annotations, int pageNumber}), _PdfPageDisplayList>{};

  /// The glyph raster cache used while rendering text.
  final PdfGlyphRasterCache glyphRasterCache;

  /// The image decode cache used while rendering image XObjects.
  final PdfImageDecodeCache imageDecodeCache;
  late final _ImageColorContext _documentImageColorContext =
      _ImageColorContext.fromDocument(document.cos);

  /// The page sizes in display coordinate order.
  List<PdfPageSize> get pageSizes => List.unmodifiable([
    for (var i = 0; i < document.pageCount; i++) _pageSize(document.page(i)),
  ]);

  /// Renders a page region to BGRA pixels.
  Uint8List renderBgraRegion({
    required int pageNumber,
    required double x,
    required double y,
    required int width,
    required int height,
    required double pixelRatio,
    required int backgroundColor,
    required bool annotations,
    PdfRenderTiming? timing,
  }) {
    final rgba = renderRgbaRegion(
      pageNumber: pageNumber,
      x: x,
      y: y,
      width: width,
      height: height,
      pixelRatio: pixelRatio,
      backgroundColor: backgroundColor,
      annotations: annotations,
      timing: timing,
    );
    final stopwatch = timing == null ? null : (Stopwatch()..start());
    final bgra = _rgbaToBgra(rgba, width: width, height: height);
    if (stopwatch != null) {
      stopwatch.stop();
      timing!.bgraConversionMicroseconds = stopwatch.elapsedMicroseconds;
    }
    return bgra;
  }

  /// Renders a page region to RGBA pixels.
  Uint8List renderRgbaRegion({
    required int pageNumber,
    required double x,
    required double y,
    required int width,
    required int height,
    required double pixelRatio,
    required int backgroundColor,
    required bool annotations,
    PdfRenderTrace? trace,
    PdfRenderTiming? timing,
  }) {
    timing?.reset();
    final page = document.page(pageNumber - 1);
    return _renderRgbaDisplayList(
      _displayListFor(pageNumber, page, annotations, timing: timing),
      cosDocument: page.document.cos,
      x: x,
      y: y,
      width: width,
      height: height,
      pixelRatio: pixelRatio,
      backgroundColor: backgroundColor,
      glyphRasterCache: glyphRasterCache,
      imageDecodeCache: imageDecodeCache,
      trace: trace,
      timing: timing,
    );
  }

  _PdfPageDisplayList _displayListFor(
    int pageNumber,
    PdfPage page,
    bool annotations, {
    PdfRenderTiming? timing,
  }) {
    final key = (pageNumber: pageNumber, annotations: annotations);
    final cached = _displayLists[key];
    if (cached != null) {
      timing?.displayListCacheHit = true;
      return cached;
    }
    timing?.displayListCacheHit = false;
    final stopwatch = timing == null ? null : (Stopwatch()..start());
    final displayList = _buildDisplayList(
      page,
      annotations: annotations,
      documentImageColorContext: _documentImageColorContext,
    );
    if (stopwatch != null) {
      stopwatch.stop();
      timing!.displayListBuildMicroseconds = stopwatch.elapsedMicroseconds;
    }
    _displayLists[key] = displayList;
    return displayList;
  }

  static PdfPageSize _pageSize(PdfPage page) {
    final box = page.cropBox;
    final swap = page.rotation == 90 || page.rotation == 270;
    return swap
        ? PdfPageSize(box.height, box.width)
        : PdfPageSize(box.width, box.height);
  }

  static _PdfPageDisplayList _buildDisplayList(
    PdfPage page, {
    required bool annotations,
    required _ImageColorContext documentImageColorContext,
  }) {
    final imageColorContexts = _collectImageColorContexts(
      page,
      annotations: annotations,
      documentImageColorContext: documentImageColorContext,
    );
    final device = _RecordingPdfDevice(
      transform: _pageToViewMatrix(page),
      imageColorContexts: imageColorContexts,
      documentImageColorContext: documentImageColorContext,
    );
    final interpreter = PdfInterpreter(cos: page.document.cos, device: device)
      ..drawPage(page);
    if (annotations) interpreter.drawAnnotations(page);
    return _PdfPageDisplayList(List.unmodifiable(device.commands));
  }

  static Uint8List _renderRgbaDisplayList(
    _PdfPageDisplayList displayList, {
    required cos.CosDocument cosDocument,
    required double x,
    required double y,
    required int width,
    required int height,
    required double pixelRatio,
    required int backgroundColor,
    required PdfGlyphRasterCache glyphRasterCache,
    required PdfImageDecodeCache imageDecodeCache,
    PdfRenderTrace? trace,
    PdfRenderTiming? timing,
  }) {
    final clearStopwatch = timing == null ? null : (Stopwatch()..start());
    final surface = _RgbaSurface(width, height)
      ..clear(
        (backgroundColor >> 16) & 0xff,
        (backgroundColor >> 8) & 0xff,
        backgroundColor & 0xff,
        (backgroundColor >> 24) & 0xff,
      );
    if (clearStopwatch != null) {
      clearStopwatch.stop();
      timing!.surfaceClearMicroseconds = clearStopwatch.elapsedMicroseconds;
    }
    final viewX = x / pixelRatio;
    final viewY = y / pixelRatio;
    final transform = PdfMatrix.translation(
      -viewX,
      -viewY,
    ).concat(PdfMatrix.scaled(pixelRatio, pixelRatio));
    final replayStopwatch = timing == null ? null : (Stopwatch()..start());
    displayList.replay(
      PdfDirectPdfDevice._(
        surface,
        cosDocument: cosDocument,
        transform: transform,
        glyphRasterCache: glyphRasterCache,
        imageDecodeCache: imageDecodeCache,
        trace: trace,
        timing: timing,
      ),
      PdfDisplayRect(
        viewX,
        viewY,
        viewX + width / pixelRatio,
        viewY + height / pixelRatio,
      ),
    );
    if (replayStopwatch != null) {
      replayStopwatch.stop();
      timing!.replayMicroseconds = replayStopwatch.elapsedMicroseconds;
    }
    return surface.pixels;
  }

  static PdfMatrix _pageToViewMatrix(PdfPage page) {
    final box = page.cropBox;
    final unrotated = PdfMatrix.translation(-box.left, -box.bottom)
        .concat(const PdfMatrix.scaled(1, -1))
        .concat(PdfMatrix.translation(0, box.height));
    return switch (page.rotation) {
      90 =>
        unrotated
            .concat(const PdfMatrix(0, 1, -1, 0, 0, 0))
            .concat(PdfMatrix.translation(box.height, 0)),
      180 =>
        unrotated
            .concat(const PdfMatrix(-1, 0, 0, -1, 0, 0))
            .concat(PdfMatrix.translation(box.width, box.height)),
      270 =>
        unrotated
            .concat(const PdfMatrix(0, -1, 1, 0, 0, 0))
            .concat(PdfMatrix.translation(0, box.width)),
      _ => unrotated,
    };
  }
}

class _PdfPageDisplayList {
  const _PdfPageDisplayList(this.commands);

  final List<PdfDisplayCommand> commands;

  void replay(PdfDirectPdfDevice device, PdfDisplayRect visibleBounds) {
    for (final command in commands) {
      if (command.shouldReplay(visibleBounds)) {
        final stopwatch = device.timing == null ? null : (Stopwatch()..start());
        command.replay(device);
        if (stopwatch != null) {
          stopwatch.stop();
          device.timing!._addCommandTime(
            command,
            stopwatch.elapsedMicroseconds,
          );
        }
      } else {
        device.timing?.culledCommands++;
      }
    }
  }
}

Map<cos.CosStream, _ImageColorContext> _collectImageColorContexts(
  PdfPage page, {
  required bool annotations,
  required _ImageColorContext documentImageColorContext,
}) {
  final collector = _ImageColorContextCollector(
    page.document.cos,
    documentImageColorContext,
  );
  collector.walkPage(page);
  if (annotations) collector.walkAnnotations(page);
  return collector.imageContexts;
}

class _ImageColorContextCollector {
  _ImageColorContextCollector(this.cosDocument, this.documentImageColorContext);

  final cos.CosDocument cosDocument;
  final _ImageColorContext documentImageColorContext;
  final imageContexts = Map<cos.CosStream, _ImageColorContext>.identity();
  final _resourceContexts =
      Map<cos.CosDictionary, _ImageColorContext>.identity();
  final _visitedForms = <cos.CosStream>{};

  void walkPage(PdfPage page) {
    _walkOperations(
      ContentStreamParser.parse(page.contentBytes()),
      page.resources,
      _contextForResources(page.resources),
      0,
    );
  }

  void walkAnnotations(PdfPage page) {
    for (final annotation in page.annotations) {
      if (annotation.isHidden || annotation.isNoView) continue;
      if (annotation.subtype == 'Popup') continue;
      final form = annotation.normalAppearance;
      if (form == null) continue;
      _walkForm(form, page.resources, _contextForResources(page.resources), 0);
    }
  }

  _ImageColorContext _contextForResources(cos.CosDictionary resources) =>
      _resourceContexts.putIfAbsent(
        resources,
        () => _ImageColorContext.fromResources(
          cosDocument,
          resources,
          parent: documentImageColorContext,
        ),
      );

  void _walkOperations(
    List<ContentOperation> operations,
    cos.CosDictionary resources,
    _ImageColorContext context,
    int depth,
  ) {
    if (depth > 16) return;
    for (final operation in operations) {
      if (operation.operator != 'Do' || operation.operands.isEmpty) continue;
      final name = operation.operands.last;
      if (name is! cos.CosName) continue;
      final xObjectGroup = cosDocument.resolve(resources['XObject']);
      if (xObjectGroup is! cos.CosDictionary) continue;
      final xObject = cosDocument.resolve(xObjectGroup[name.value]);
      if (xObject is! cos.CosStream) continue;
      final subtype = _nameValue(
        cosDocument.resolve(xObject.dictionary['Subtype']),
      );
      if (subtype == 'Image') {
        imageContexts.putIfAbsent(xObject, () => context);
      } else if (subtype == 'Form') {
        _walkForm(xObject, resources, context, depth + 1);
      }
    }
  }

  void _walkForm(
    cos.CosStream form,
    cos.CosDictionary outerResources,
    _ImageColorContext outerContext,
    int depth,
  ) {
    if (!_visitedForms.add(form)) return;
    final innerResources = cosDocument.resolve(form.dictionary['Resources']);
    final resources = innerResources is cos.CosDictionary
        ? innerResources
        : outerResources;
    final context = innerResources is cos.CosDictionary
        ? _contextForResources(innerResources)
        : outerContext;
    try {
      final content = cosDocument.decodeStreamData(form);
      _walkOperations(
        ContentStreamParser.parse(content),
        resources,
        context,
        depth,
      );
    } on Exception {
      return;
    }
  }
}

class _RecordingPdfDevice implements PdfDevice {
  _RecordingPdfDevice({
    required this.transform,
    required this.imageColorContexts,
    required this.documentImageColorContext,
  });

  final PdfMatrix transform;
  final Map<cos.CosStream, _ImageColorContext> imageColorContexts;
  final _ImageColorContext documentImageColorContext;
  final _commandStack = <List<PdfDisplayCommand>>[<PdfDisplayCommand>[]];

  List<PdfDisplayCommand> get commands => _commandStack.first;

  void _addCommand(PdfDisplayCommand command) {
    _commandStack.last.add(command);
  }

  @override
  void save() {
    _addCommand(const PdfSaveCommand());
  }

  @override
  void restore() {
    _addCommand(const PdfRestoreCommand());
  }

  @override
  void fillPath(PdfPath path, PdfColor color, PdfFillRule rule, double alpha) {
    final transformed = _transformPath(path, transform);
    _addCommand(
      PdfFillPathCommand(
        transformed,
        color,
        rule,
        alpha,
        _pathBounds(transformed),
      ),
    );
  }

  @override
  void fillPathGradient(
    PdfPath path,
    PdfFillRule rule,
    PdfGradient gradient,
    double alpha,
  ) {
    final transformed = _transformPath(path, transform);
    _addCommand(
      PdfFillPathGradientCommand(
        transformed,
        rule,
        _transformGradient(gradient, transform),
        alpha,
        _pathBounds(transformed),
      ),
    );
  }

  @override
  void fillMesh(PdfMesh mesh, double alpha) {
    final transformed = _transformMesh(mesh, transform);
    _addCommand(
      PdfFillMeshCommand(transformed, alpha, _meshBounds(transformed)),
    );
  }

  @override
  void strokePath(
    PdfPath path,
    PdfColor color,
    PdfStroke stroke,
    double alpha,
  ) {
    final transformed = _transformPath(path, transform);
    final bounds = _pathBounds(transformed)?.inflate(stroke.width / 2 + 1);
    _addCommand(
      PdfStrokePathCommand(
        transformed,
        color,
        stroke.copyWith(width: stroke.width * transform.scaleFactor),
        alpha,
        bounds,
      ),
    );
  }

  @override
  void clipPath(PdfPath path, PdfFillRule rule) {
    _addCommand(PdfClipPathCommand(_transformPath(path, transform), rule));
  }

  @override
  void drawText(PdfTextRun run) {
    final transformed = _transformTextRun(run, transform);
    if (run.invisible) {
      _addCommand(PdfDrawTextCommand(transformed, null));
      return;
    }
    _addCommand(
      PdfDrawTextCommand(transformed, _textRunBounds(transformed)?.inflate(2)),
    );
  }

  @override
  void drawImage(PdfImageRequest request) {
    final transformed = _transformImageDrawRequest(
      _ImageDrawRequest(
        request,
        imageColorContexts[request.stream] ?? documentImageColorContext,
      ),
      transform,
    );
    _addCommand(
      PdfDrawImageCommand(
        transformed,
        _imageRequestBounds(transformed.request),
      ),
    );
  }

  @override
  void setBlendMode(PdfBlendMode mode) {
    _addCommand(PdfSetBlendModeCommand(mode));
  }

  @override
  void beginGroup(double alpha, {bool knockout = false}) {
    _addCommand(PdfBeginGroupCommand(alpha, knockout: knockout));
  }

  @override
  void endGroup() {
    _addCommand(const PdfEndGroupCommand());
  }

  @override
  void beginSoftMasked() {
    _addCommand(const PdfBeginSoftMaskCommand());
  }

  @override
  void endSoftMasked({
    required bool luminosity,
    required PdfRect backdrop,
    required void Function() drawMask,
    double backdropLuminance = 0,
    double transferScale = 1,
    double transferOffset = 0,
  }) {
    _commandStack.add(<PdfDisplayCommand>[]);
    drawMask();
    final maskCommands = List<PdfDisplayCommand>.unmodifiable(
      _commandStack.removeLast(),
    );
    _addCommand(
      PdfEndSoftMaskCommand(
        luminosity: luminosity,
        backdrop: _transformRect(backdrop, transform),
        maskCommands: maskCommands,
        backdropLuminance: backdropLuminance,
        transferScale: transferScale,
        transferOffset: transferOffset,
      ),
    );
  }
}

/// Cache for rasterized glyph masks.
class PdfGlyphRasterCache {
  /// Creates a glyph raster cache.
  PdfGlyphRasterCache({
    this.maxEntries = _defaultMaxGlyphRasterCacheEntries,
    this.maxGlyphPixels = _defaultMaxGlyphRasterPixels,
  });

  /// The maximum number of glyph masks retained.
  final int maxEntries;

  /// The maximum pixel area allowed for a single glyph mask.
  final int maxGlyphPixels;
  final _entries = <_GlyphRasterKey, _GlyphRasterMask>{};
  final _outlineKeys = Expando<_GlyphOutlineKey>();

  /// The current number of cached glyph masks.
  int get entryCount => _entries.length;

  /// Removes all cached glyph masks.
  void clear() {
    _entries.clear();
  }

  bool _paintGlyph({
    required _RgbaSurface surface,
    required _ClipState clip,
    required PdfPath outline,
    required PdfMatrix transform,
    required PdfColor color,
    required double alpha,
    PdfRenderTiming? timing,
  }) {
    timing?.glyphRequests++;
    final placement = _GlyphRasterPlacement.from(transform);
    final key = _GlyphRasterKey.from(
      _outlineKeys[outline] ??= _GlyphOutlineKey.from(outline),
      placement,
    );
    final cached = _entries.remove(key);
    final _GlyphRasterMask? mask;
    if (cached != null) {
      timing?.glyphCacheHits++;
      mask = cached;
    } else {
      final stopwatch = timing == null ? null : (Stopwatch()..start());
      mask = _createMask(outline, placement);
      if (stopwatch != null) {
        stopwatch.stop();
        timing!.glyphMaskCreateMicroseconds += stopwatch.elapsedMicroseconds;
      }
      if (mask == null) {
        timing?.glyphFallbacks++;
        return false;
      }
      timing?.glyphMasksCreated++;
    }
    _entries[key] = mask;
    if (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    final paintStopwatch = timing == null ? null : (Stopwatch()..start());
    mask.paint(
      surface: surface,
      clip: clip,
      baseX: placement.baseX,
      baseY: placement.baseY,
      color: color,
      alpha: alpha,
    );
    if (paintStopwatch != null) {
      paintStopwatch.stop();
      timing!.glyphMaskPaintMicroseconds += paintStopwatch.elapsedMicroseconds;
    }
    return true;
  }

  _GlyphRasterMask? _createMask(
    PdfPath outline,
    _GlyphRasterPlacement placement,
  ) {
    final contours = _flattenPath(outline, transform: placement.transform);
    final bounds = _rawBoundsOf(contours);
    if (bounds == null || bounds.isEmpty) {
      return const _GlyphRasterMask.empty();
    }
    if (bounds.width * bounds.height > maxGlyphPixels) return null;

    final coverage = _buildPathCoverageAlpha(
      bounds,
      contours,
      PdfFillRule.nonzero,
    );
    return _GlyphRasterMask(
      bounds.left,
      bounds.top,
      bounds.width,
      bounds.height,
      coverage,
    );
  }
}

class _GlyphRasterPlacement {
  const _GlyphRasterPlacement(
    this.baseX,
    this.baseY,
    this.qa,
    this.qb,
    this.qc,
    this.qd,
    this.qfx,
    this.qfy,
  );

  factory _GlyphRasterPlacement.from(PdfMatrix transform) {
    final fx = _quantizeFraction(transform.e);
    final fy = _quantizeFraction(transform.f);
    return _GlyphRasterPlacement(
      fx.base,
      fy.base,
      _quantizeTransform(transform.a),
      _quantizeTransform(transform.b),
      _quantizeTransform(transform.c),
      _quantizeTransform(transform.d),
      fx.fraction,
      fy.fraction,
    );
  }

  final int baseX;
  final int baseY;
  final int qa;
  final int qb;
  final int qc;
  final int qd;
  final int qfx;
  final int qfy;

  PdfMatrix get transform => PdfMatrix(
    qa / _glyphTransformQuantization,
    qb / _glyphTransformQuantization,
    qc / _glyphTransformQuantization,
    qd / _glyphTransformQuantization,
    qfx / _glyphSubpixelQuantization,
    qfy / _glyphSubpixelQuantization,
  );
}

class _GlyphRasterKey {
  const _GlyphRasterKey(
    this.outlineKey,
    this.qa,
    this.qb,
    this.qc,
    this.qd,
    this.qfx,
    this.qfy,
  );

  factory _GlyphRasterKey.from(
    _GlyphOutlineKey outlineKey,
    _GlyphRasterPlacement placement,
  ) => _GlyphRasterKey(
    outlineKey,
    placement.qa,
    placement.qb,
    placement.qc,
    placement.qd,
    placement.qfx,
    placement.qfy,
  );

  final _GlyphOutlineKey outlineKey;
  final int qa;
  final int qb;
  final int qc;
  final int qd;
  final int qfx;
  final int qfy;

  @override
  bool operator ==(Object other) =>
      other is _GlyphRasterKey &&
      outlineKey == other.outlineKey &&
      qa == other.qa &&
      qb == other.qb &&
      qc == other.qc &&
      qd == other.qd &&
      qfx == other.qfx &&
      qfy == other.qfy;

  @override
  int get hashCode => Object.hash(outlineKey, qa, qb, qc, qd, qfx, qfy);
}

class _GlyphOutlineKey {
  const _GlyphOutlineKey(this.segments, this.hashCode);

  factory _GlyphOutlineKey.from(PdfPath outline) {
    var hash = 0x345678;
    for (final segment in outline.segments) {
      switch (segment) {
        case PdfMoveTo(:final x, :final y):
          hash = _combineHash(hash, 1);
          hash = _combineHash(hash, x.hashCode);
          hash = _combineHash(hash, y.hashCode);
        case PdfLineTo(:final x, :final y):
          hash = _combineHash(hash, 2);
          hash = _combineHash(hash, x.hashCode);
          hash = _combineHash(hash, y.hashCode);
        case PdfCubicTo():
          hash = _combineHash(hash, 3);
          hash = _combineHash(hash, segment.x1.hashCode);
          hash = _combineHash(hash, segment.y1.hashCode);
          hash = _combineHash(hash, segment.x2.hashCode);
          hash = _combineHash(hash, segment.y2.hashCode);
          hash = _combineHash(hash, segment.x3.hashCode);
          hash = _combineHash(hash, segment.y3.hashCode);
        case PdfClosePath():
          hash = _combineHash(hash, 4);
      }
    }
    return _GlyphOutlineKey(outline.segments, hash);
  }

  final List<PdfPathSegment> segments;

  @override
  final int hashCode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _GlyphOutlineKey) return false;
    if (hashCode != other.hashCode) return false;
    if (identical(segments, other.segments)) return true;
    if (segments.length != other.segments.length) return false;
    for (var i = 0; i < segments.length; i++) {
      if (!_samePathSegment(segments[i], other.segments[i])) return false;
    }
    return true;
  }
}

int _combineHash(int hash, int value) =>
    0x1fffffff & (hash + value + ((hash & 0x0007ffff) << 10));

bool _samePathSegment(PdfPathSegment a, PdfPathSegment b) {
  switch (a) {
    case PdfMoveTo(:final x, :final y):
      return b is PdfMoveTo && x == b.x && y == b.y;
    case PdfLineTo(:final x, :final y):
      return b is PdfLineTo && x == b.x && y == b.y;
    case PdfCubicTo():
      return b is PdfCubicTo &&
          a.x1 == b.x1 &&
          a.y1 == b.y1 &&
          a.x2 == b.x2 &&
          a.y2 == b.y2 &&
          a.x3 == b.x3 &&
          a.y3 == b.y3;
    case PdfClosePath():
      return b is PdfClosePath;
  }
}

class _GlyphRasterMask {
  const _GlyphRasterMask(
    this.originX,
    this.originY,
    this.width,
    this.height,
    this.coverage,
  );

  const _GlyphRasterMask.empty()
    : originX = 0,
      originY = 0,
      width = 0,
      height = 0,
      coverage = const [];

  final int originX;
  final int originY;
  final int width;
  final int height;
  final List<int> coverage;

  void paint({
    required _RgbaSurface surface,
    required _ClipState clip,
    required int baseX,
    required int baseY,
    required PdfColor color,
    required double alpha,
  }) {
    if (width == 0 || height == 0) return;
    final r = (color.red.clamp(0, 1) * 255).round();
    final g = (color.green.clamp(0, 1) * 255).round();
    final b = (color.blue.clamp(0, 1) * 255).round();
    final baseAlpha = (alpha.clamp(0, 1) * 255).round();
    final dstLeft = math.max(0, math.max(clip.bounds.left, baseX + originX));
    final dstTop = math.max(0, math.max(clip.bounds.top, baseY + originY));
    final dstRight = math.min(
      surface.width,
      math.min(clip.bounds.right, baseX + originX + width),
    );
    final dstBottom = math.min(
      surface.height,
      math.min(clip.bounds.bottom, baseY + originY + height),
    );
    if (dstLeft >= dstRight || dstTop >= dstBottom) return;

    final dstPixels = surface.pixels;
    final dstWidth = surface.width;
    final needsPathClip = clip.paths.isNotEmpty;
    for (var dstY = dstTop; dstY < dstBottom; dstY++) {
      var coverageOffset =
          (dstY - baseY - originY) * width + dstLeft - baseX - originX;
      var dstOffset = (dstY * dstWidth + dstLeft) * 4;
      for (var dstX = dstLeft; dstX < dstRight; dstX++) {
        final coverageAlpha = coverage[coverageOffset];
        if (coverageAlpha != 0 &&
            (!needsPathClip || clip.contains(dstX + 0.5, dstY + 0.5))) {
          final a = baseAlpha * coverageAlpha ~/ 255;
          if (a >= 255) {
            dstPixels[dstOffset] = r;
            dstPixels[dstOffset + 1] = g;
            dstPixels[dstOffset + 2] = b;
            dstPixels[dstOffset + 3] = 255;
          } else if (a > 0) {
            final inv = 255 - a;
            dstPixels[dstOffset] = (r * a + dstPixels[dstOffset] * inv) ~/ 255;
            dstPixels[dstOffset + 1] =
                (g * a + dstPixels[dstOffset + 1] * inv) ~/ 255;
            dstPixels[dstOffset + 2] =
                (b * a + dstPixels[dstOffset + 2] * inv) ~/ 255;
            if (a > dstPixels[dstOffset + 3]) dstPixels[dstOffset + 3] = a;
          }
        }
        coverageOffset++;
        dstOffset += 4;
      }
    }
  }
}

Uint8List _buildPathCoverageAlpha(
  _IntRect bounds,
  List<List<_Point>> contours,
  PdfFillRule rule,
) {
  final coverage = Uint8List(bounds.width * bounds.height);
  final events = <_ScanlineIntersection>[];
  for (var py = bounds.top; py < bounds.bottom; py++) {
    for (var sy = 0; sy < _antiAliasSamplesPerAxis; sy++) {
      final y = py + (sy + 0.5) / _antiAliasSamplesPerAxis;
      events.clear();
      for (final contour in contours) {
        for (var i = 0; i < contour.length - 1; i++) {
          final p1 = contour[i];
          final p2 = contour[i + 1];
          if (p1.y == p2.y) continue;
          final minY = math.min(p1.y, p2.y);
          final maxY = math.max(p1.y, p2.y);
          if (y < minY || y >= maxY) continue;
          final t = (y - p1.y) / (p2.y - p1.y);
          final x = p1.x + (p2.x - p1.x) * t;
          events.add(_ScanlineIntersection(x, p2.y > p1.y ? 1 : -1));
        }
      }
      if (events.isEmpty) continue;
      events.sort((a, b) => a.x.compareTo(b.x));

      if (rule == PdfFillRule.evenOdd) {
        var inside = false;
        var spanStart = 0.0;
        for (final event in events) {
          if (inside) {
            _addCoverageSpanSamples(coverage, bounds, py, spanStart, event.x);
          }
          inside = !inside;
          spanStart = event.x;
        }
      } else {
        var winding = 0;
        var spanStart = 0.0;
        for (final event in events) {
          if (winding != 0) {
            _addCoverageSpanSamples(coverage, bounds, py, spanStart, event.x);
          }
          winding += event.windingDelta;
          spanStart = event.x;
        }
      }
    }
  }
  for (var i = 0; i < coverage.length; i++) {
    coverage[i] = _coverageAlphaForSampleCount(coverage[i]);
  }
  return coverage;
}

int _coverageAlphaForSampleCount(int coveredSamples) {
  if (coveredSamples <= 0) return 0;
  if (coveredSamples >= _antiAliasSampleCount) return 255;
  return (coveredSamples * 255 / _antiAliasSampleCount).round();
}

void _addCoverageSpanSamples(
  Uint8List coverage,
  _IntRect bounds,
  int py,
  double x1,
  double x2,
) {
  if (x2 <= x1) return;
  final rowOffset = (py - bounds.top) * bounds.width - bounds.left;
  for (var sx = 0; sx < _antiAliasSamplesPerAxis; sx++) {
    final offset = (sx + 0.5) / _antiAliasSamplesPerAxis;
    final start = math.max(bounds.left, (x1 - offset).ceil());
    final end = math.min(bounds.right, (x2 - offset).ceil());
    for (var px = start; px < end; px++) {
      coverage[rowOffset + px]++;
    }
  }
}

({int base, int fraction}) _quantizeFraction(double value) {
  var base = value.floor();
  var fraction = ((value - base) * _glyphSubpixelQuantization).round();
  if (fraction >= _glyphSubpixelQuantization) {
    base++;
    fraction = 0;
  }
  return (base: base, fraction: fraction);
}

int _quantizeTransform(double value) =>
    (value * _glyphTransformQuantization).round();

PdfPath _transformPath(PdfPath path, PdfMatrix transform) => PdfPath([
  for (final segment in path.segments)
    switch (segment) {
      PdfMoveTo(:final x, :final y) => PdfMoveTo(
        transform.transformX(x, y),
        transform.transformY(x, y),
      ),
      PdfLineTo(:final x, :final y) => PdfLineTo(
        transform.transformX(x, y),
        transform.transformY(x, y),
      ),
      PdfCubicTo() => PdfCubicTo(
        transform.transformX(segment.x1, segment.y1),
        transform.transformY(segment.x1, segment.y1),
        transform.transformX(segment.x2, segment.y2),
        transform.transformY(segment.x2, segment.y2),
        transform.transformX(segment.x3, segment.y3),
        transform.transformY(segment.x3, segment.y3),
      ),
      PdfClosePath() => const PdfClosePath(),
    },
]);

PdfTextRun _transformTextRun(PdfTextRun run, PdfMatrix transform) => PdfTextRun(
  text: run.text,
  transform: run.transform.concat(transform),
  color: run.color,
  width: run.width,
  fontName: run.fontName,
  fontSize: run.fontSize,
  glyphs: run.glyphs,
  invisible: run.invisible,
);

class _ImageDrawRequest {
  const _ImageDrawRequest(this.request, this.colorContext);

  final PdfImageRequest request;
  final _ImageColorContext colorContext;
}

_ImageDrawRequest _transformImageDrawRequest(
  _ImageDrawRequest request,
  PdfMatrix transform,
) => _ImageDrawRequest(
  PdfImageRequest(
    stream: request.request.stream,
    transform: request.request.transform.concat(transform),
    alpha: request.request.alpha,
    isStencil: request.request.isStencil,
    stencilColor: request.request.stencilColor,
    isInline: request.request.isInline,
  ),
  request.colorContext,
);

PdfMesh _transformMesh(PdfMesh mesh, PdfMatrix transform) => PdfMesh([
  for (final vertex in mesh.vertices)
    PdfMeshVertex(
      transform.transformX(vertex.x, vertex.y),
      transform.transformY(vertex.x, vertex.y),
      vertex.color,
    ),
], mesh.triangles);

PdfGradient _transformGradient(PdfGradient gradient, PdfMatrix transform) =>
    PdfGradient(
      isRadial: gradient.isRadial,
      coords: gradient.coords,
      colors: gradient.colors,
      stops: gradient.stops,
      transform: gradient.transform.concat(transform),
      extendStart: gradient.extendStart,
      extendEnd: gradient.extendEnd,
    );

PdfRect _transformRect(PdfRect rect, PdfMatrix transform) {
  final points = [
    _Point(
      transform.transformX(rect.left, rect.top),
      transform.transformY(rect.left, rect.top),
    ),
    _Point(
      transform.transformX(rect.right, rect.top),
      transform.transformY(rect.right, rect.top),
    ),
    _Point(
      transform.transformX(rect.right, rect.bottom),
      transform.transformY(rect.right, rect.bottom),
    ),
    _Point(
      transform.transformX(rect.left, rect.bottom),
      transform.transformY(rect.left, rect.bottom),
    ),
  ];
  var left = double.infinity;
  var top = double.infinity;
  var right = double.negativeInfinity;
  var bottom = double.negativeInfinity;
  for (final point in points) {
    left = math.min(left, point.x);
    top = math.min(top, point.y);
    right = math.max(right, point.x);
    bottom = math.max(bottom, point.y);
  }
  return PdfRect(left, top, right, bottom);
}

PdfColor? _axialGradientColorAt(PdfGradient gradient, double x, double y) {
  final coords = gradient.coords;
  final matrix = gradient.transform;
  final x0 = matrix.transformX(coords[0], coords[1]);
  final y0 = matrix.transformY(coords[0], coords[1]);
  final x1 = matrix.transformX(coords[2], coords[3]);
  final y1 = matrix.transformY(coords[2], coords[3]);
  final dx = x1 - x0;
  final dy = y1 - y0;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared <= 1e-12) {
    return gradient.colors.isEmpty ? null : gradient.colors.last;
  }
  var t = ((x - x0) * dx + (y - y0) * dy) / lengthSquared;
  if (t < 0) {
    if (!gradient.extendStart) return null;
    t = 0;
  } else if (t > 1) {
    if (!gradient.extendEnd) return null;
    t = 1;
  }
  return _interpolateGradientColor(gradient, t);
}

PdfColor? _interpolateGradientColor(PdfGradient gradient, double t) {
  final colors = gradient.colors;
  if (colors.isEmpty) return null;
  if (colors.length == 1) return colors.first;
  final stops = gradient.stops;
  if (stops.length != colors.length) {
    final scaled = t.clamp(0.0, 1.0) * (colors.length - 1);
    final index = scaled.floor().clamp(0, colors.length - 2);
    return _lerpColor(colors[index], colors[index + 1], scaled - index);
  }
  if (t <= stops.first) return colors.first;
  for (var i = 1; i < stops.length; i++) {
    final stop = stops[i];
    if (t <= stop) {
      final previous = stops[i - 1];
      final span = stop - previous;
      final local = span.abs() <= 1e-12 ? 0.0 : (t - previous) / span;
      return _lerpColor(colors[i - 1], colors[i], local);
    }
  }
  return colors.last;
}

PdfColor _lerpColor(PdfColor a, PdfColor b, double t) {
  final local = t.clamp(0.0, 1.0);
  return PdfColor(
    a.red + (b.red - a.red) * local,
    a.green + (b.green - a.green) * local,
    a.blue + (b.blue - a.blue) * local,
  );
}

double _luminance(int r, int g, int b) =>
    (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;

PdfDisplayRect? _pathBounds(PdfPath path) {
  final points = <_Point>[];
  for (final segment in path.segments) {
    switch (segment) {
      case PdfMoveTo(:final x, :final y) || PdfLineTo(:final x, :final y):
        points.add(_Point(x, y));
      case PdfCubicTo():
        points.add(_Point(segment.x1, segment.y1));
        points.add(_Point(segment.x2, segment.y2));
        points.add(_Point(segment.x3, segment.y3));
      case PdfClosePath():
        break;
    }
  }
  return _pointsBounds(points);
}

PdfDisplayRect? _textRunBounds(PdfTextRun run) {
  final matrix = run.transform;
  return _pointsBounds([
    _Point(matrix.transformX(0, -0.25), matrix.transformY(0, -0.25)),
    _Point(
      matrix.transformX(run.width, -0.25),
      matrix.transformY(run.width, -0.25),
    ),
    _Point(matrix.transformX(run.width, 1), matrix.transformY(run.width, 1)),
    _Point(matrix.transformX(0, 1), matrix.transformY(0, 1)),
  ]);
}

PdfDisplayRect? _imageRequestBounds(PdfImageRequest request) => _pointsBounds([
  _Point(
    request.transform.transformX(0, 0),
    request.transform.transformY(0, 0),
  ),
  _Point(
    request.transform.transformX(1, 0),
    request.transform.transformY(1, 0),
  ),
  _Point(
    request.transform.transformX(1, 1),
    request.transform.transformY(1, 1),
  ),
  _Point(
    request.transform.transformX(0, 1),
    request.transform.transformY(0, 1),
  ),
]);

PdfDisplayRect? _meshBounds(PdfMesh mesh) => _pointsBounds([
  for (final vertex in mesh.vertices) _Point(vertex.x, vertex.y),
]);

PdfDisplayRect? _pointsBounds(List<_Point> points) {
  if (points.isEmpty) return null;
  var left = double.infinity;
  var top = double.infinity;
  var right = double.negativeInfinity;
  var bottom = double.negativeInfinity;
  for (final point in points) {
    left = math.min(left, point.x);
    top = math.min(top, point.y);
    right = math.max(right, point.x);
    bottom = math.max(bottom, point.y);
  }
  return PdfDisplayRect(left, top, right, bottom);
}

_IntRect? _rawBoundsOf(List<List<_Point>> contours) {
  if (contours.isEmpty) return null;
  var left = double.infinity;
  var top = double.infinity;
  var right = double.negativeInfinity;
  var bottom = double.negativeInfinity;
  for (final contour in contours) {
    for (final point in contour) {
      left = math.min(left, point.x);
      top = math.min(top, point.y);
      right = math.max(right, point.x);
      bottom = math.max(bottom, point.y);
    }
  }
  return _IntRect(left.floor(), top.floor(), right.ceil(), bottom.ceil());
}

/// The visible size of a PDF page after page rotation is applied.
class PdfPageSize {
  /// Creates a page size.
  const PdfPageSize(this.width, this.height);

  /// The page width in PDF points.
  final double width;

  /// The page height in PDF points.
  final double height;
}

Uint8List _rgbaToBgra(
  Uint8List rgba, {
  required int width,
  required int height,
}) {
  final out = Uint8List(width * height * 4);
  if (Endian.host == Endian.little) {
    final src = rgba.buffer.asUint32List(rgba.offsetInBytes, width * height);
    final dst = out.buffer.asUint32List();
    for (var i = 0; i < src.length; i++) {
      final pixel = src[i];
      dst[i] =
          (pixel & 0xff00ff00) |
          ((pixel & 0x000000ff) << 16) |
          ((pixel & 0x00ff0000) >> 16);
    }
    return out;
  }
  for (var offset = 0; offset < out.length; offset += 4) {
    out[offset] = rgba[offset + 2];
    out[offset + 1] = rgba[offset + 1];
    out[offset + 2] = rgba[offset];
    out[offset + 3] = rgba[offset + 3];
  }
  return out;
}

/// Timing and counter data collected during rendering.
class PdfRenderTiming {
  /// Whether the display list came from the page cache.
  var displayListCacheHit = false;

  /// Time spent building the display list, in microseconds.
  var displayListBuildMicroseconds = 0;

  /// Time spent clearing the output surface, in microseconds.
  var surfaceClearMicroseconds = 0;

  /// Time spent replaying display commands, in microseconds.
  var replayMicroseconds = 0;

  /// Time spent converting RGBA pixels to BGRA, in microseconds.
  var bgraConversionMicroseconds = 0;

  /// Number of display commands replayed.
  var replayedCommands = 0;

  /// Number of display commands skipped by visible-bounds culling.
  var culledCommands = 0;

  /// Time spent filling paths, in microseconds.
  var fillPathMicroseconds = 0;

  /// Time spent stroking paths, in microseconds.
  var strokePathMicroseconds = 0;

  /// Time spent applying clipping paths, in microseconds.
  var clipPathMicroseconds = 0;

  /// Time spent drawing text, in microseconds.
  var drawTextMicroseconds = 0;

  /// Time spent drawing images, in microseconds.
  var drawImageMicroseconds = 0;

  /// Time spent processing transparency groups, in microseconds.
  var groupMicroseconds = 0;

  /// Time spent in commands not covered by another bucket.
  var otherCommandMicroseconds = 0;

  /// Number of glyph mask lookups requested.
  var glyphRequests = 0;

  /// Number of glyph mask cache hits.
  var glyphCacheHits = 0;

  /// Number of glyph masks created.
  var glyphMasksCreated = 0;

  /// Number of glyphs rendered through the fallback path.
  var glyphFallbacks = 0;

  /// Time spent creating glyph masks, in microseconds.
  var glyphMaskCreateMicroseconds = 0;

  /// Time spent painting glyph masks, in microseconds.
  var glyphMaskPaintMicroseconds = 0;

  /// Resets all counters to their initial values.
  void reset() {
    displayListCacheHit = false;
    displayListBuildMicroseconds = 0;
    surfaceClearMicroseconds = 0;
    replayMicroseconds = 0;
    bgraConversionMicroseconds = 0;
    replayedCommands = 0;
    culledCommands = 0;
    fillPathMicroseconds = 0;
    strokePathMicroseconds = 0;
    clipPathMicroseconds = 0;
    drawTextMicroseconds = 0;
    drawImageMicroseconds = 0;
    groupMicroseconds = 0;
    otherCommandMicroseconds = 0;
    glyphRequests = 0;
    glyphCacheHits = 0;
    glyphMasksCreated = 0;
    glyphFallbacks = 0;
    glyphMaskCreateMicroseconds = 0;
    glyphMaskPaintMicroseconds = 0;
  }

  void _addCommandTime(PdfDisplayCommand command, int microseconds) {
    replayedCommands++;
    switch (command) {
      case PdfFillPathCommand() ||
          PdfFillPathGradientCommand() ||
          PdfFillMeshCommand():
        fillPathMicroseconds += microseconds;
      case PdfStrokePathCommand():
        strokePathMicroseconds += microseconds;
      case PdfClipPathCommand():
        clipPathMicroseconds += microseconds;
      case PdfDrawTextCommand():
        drawTextMicroseconds += microseconds;
      case PdfDrawImageCommand():
        drawImageMicroseconds += microseconds;
      case PdfBeginGroupCommand() ||
          PdfEndGroupCommand() ||
          PdfBeginSoftMaskCommand() ||
          PdfEndSoftMaskCommand():
        groupMicroseconds += microseconds;
      default:
        otherCommandMicroseconds += microseconds;
    }
  }
}

/// Collects render trace events that intersect a region.
class PdfRenderTrace {
  /// Creates a trace collector for [region].
  PdfRenderTrace({required this.region});

  /// The region of interest for collected trace events.
  final PdfRenderTraceRegion region;

  /// The collected trace events.
  final events = <PdfRenderTraceEvent>[];

  /// Adds a trace event when [bounds] intersects [region].
  void add(String operation, PdfRenderTraceRegion bounds, {String? details}) {
    if (!bounds.intersects(region)) return;
    events.add(
      PdfRenderTraceEvent(
        index: events.length + 1,
        operation: operation,
        bounds: bounds,
        details: details,
      ),
    );
  }
}

/// A rectangular region used for render tracing.
class PdfRenderTraceRegion {
  /// Creates a trace region from its edges.
  const PdfRenderTraceRegion(this.left, this.top, this.right, this.bottom);

  /// The left edge.
  final double left;

  /// The top edge.
  final double top;

  /// The right edge.
  final double right;

  /// The bottom edge.
  final double bottom;

  /// Whether the region has no positive area.
  bool get isEmpty => left >= right || top >= bottom;

  /// Returns whether this region intersects [other].
  bool intersects(PdfRenderTraceRegion other) =>
      !isEmpty &&
      !other.isEmpty &&
      left < other.right &&
      right > other.left &&
      top < other.bottom &&
      bottom > other.top;

  @override
  String toString() =>
      '${left.toStringAsFixed(1)},${top.toStringAsFixed(1)},'
      '${right.toStringAsFixed(1)},${bottom.toStringAsFixed(1)}';
}

/// A single render trace event.
class PdfRenderTraceEvent {
  /// Creates a render trace event.
  const PdfRenderTraceEvent({
    required this.index,
    required this.operation,
    required this.bounds,
    this.details,
  });

  /// The one-based sequence number of the event.
  final int index;

  /// The traced operation name.
  final String operation;

  /// The affected bounds of the operation.
  final PdfRenderTraceRegion bounds;

  /// Optional operation-specific details.
  final String? details;

  @override
  String toString() {
    final suffix = details == null ? '' : ' $details';
    return '#$index $operation [$bounds]$suffix';
  }
}

/// A direct rendering device used to replay display commands to pixels.
class PdfDirectPdfDevice implements PdfDevice, PdfDisplayCommandDevice {
  PdfDirectPdfDevice._(
    _RgbaSurface surface, {
    required this.cosDocument,
    required PdfMatrix transform,
    this.glyphRasterCache,
    this.imageDecodeCache,
    this.trace,
    this.timing,
  }) : _surfaceStack = [surface],
       _transformStack = [transform],
       _clipStack = [_ClipState(_IntRect(0, 0, surface.width, surface.height))];

  final List<_RgbaSurface> _surfaceStack;

  /// The COS document used to resolve and decode page resources.
  final cos.CosDocument cosDocument;

  /// The glyph raster cache used while drawing text.
  final PdfGlyphRasterCache? glyphRasterCache;

  /// The image decode cache used while drawing images.
  final PdfImageDecodeCache? imageDecodeCache;

  /// Optional trace collector for rendered operations.
  final PdfRenderTrace? trace;

  /// Optional timing collector for rendered operations.
  final PdfRenderTiming? timing;
  final List<PdfMatrix> _transformStack;
  final List<_ClipState> _clipStack;
  final List<double> _groupAlphaStack = [];

  _RgbaSurface get _surface => _surfaceStack.last;
  PdfMatrix get _transform => _transformStack.last;
  _ClipState get _clip => _clipStack.last;

  @override
  void save() {
    _transformStack.add(_transform);
    _clipStack.add(_clip);
  }

  @override
  void restore() {
    if (_transformStack.length > 1) _transformStack.removeLast();
    if (_clipStack.length > 1) _clipStack.removeLast();
  }

  @override
  void fillPath(PdfPath path, PdfColor color, PdfFillRule rule, double alpha) {
    _fillPath(path, color, rule, alpha, operation: 'fillPath');
  }

  @override
  void fillPathGradient(
    PdfPath path,
    PdfFillRule rule,
    PdfGradient gradient,
    double alpha,
  ) {
    _fillPathGradient(
      _transformPath(path, _transform),
      rule,
      _transformGradient(gradient, _transform),
      alpha,
    );
  }

  @override
  void fillMesh(PdfMesh mesh, double alpha) {
    if (mesh.vertices.isEmpty) return;
    final path = PdfPath([
      for (var i = 0; i < mesh.triangles.length; i += 3) ...[
        PdfMoveTo(
          mesh.vertices[mesh.triangles[i]].x,
          mesh.vertices[mesh.triangles[i]].y,
        ),
        PdfLineTo(
          mesh.vertices[mesh.triangles[i + 1]].x,
          mesh.vertices[mesh.triangles[i + 1]].y,
        ),
        PdfLineTo(
          mesh.vertices[mesh.triangles[i + 2]].x,
          mesh.vertices[mesh.triangles[i + 2]].y,
        ),
        const PdfClosePath(),
      ],
    ]);
    _fillPath(
      path,
      mesh.averageColor,
      PdfFillRule.nonzero,
      alpha,
      operation: 'fillMesh',
      details: 'triangles=${mesh.triangles.length ~/ 3} alpha=${_f(alpha)}',
    );
  }

  @override
  void strokePath(
    PdfPath path,
    PdfColor color,
    PdfStroke stroke,
    double alpha,
  ) {
    final contours = _flatten(path);
    if (contours.isEmpty) return;
    final bounds = _boundsOf(contours)?.intersect(_clip.bounds);
    if (bounds != null && !bounds.isEmpty) {
      _trace(
        'strokePath',
        bounds,
        '${_colorDetails(color, alpha)} width=${_f(stroke.width)} '
            'dash=${stroke.dashArray.length} clip=${_clip.bounds}',
      );
    }
    final r = (color.red.clamp(0, 1) * 255).round();
    final g = (color.green.clamp(0, 1) * 255).round();
    final b = (color.blue.clamp(0, 1) * 255).round();
    final a = (alpha.clamp(0, 1) * 255).round();
    final width = math.max(1.0, stroke.width * _transform.scaleFactor);
    final dashes = [
      for (final dash in stroke.dashArray)
        if (dash > 0) dash * _transform.scaleFactor,
    ];
    final phase = stroke.dashPhase * _transform.scaleFactor;
    for (final contour in contours) {
      _strokeContour(contour, width, dashes, phase, r, g, b, a);
    }
  }

  @override
  void clipPath(PdfPath path, PdfFillRule rule) {
    final contours = _flatten(path);
    final bounds = _boundsOf(contours);
    if (bounds == null) return;
    _trace(
      'clipPath',
      bounds.intersect(_clip.bounds),
      'rule=${rule.name} previousClip=${_clip.bounds}',
    );
    if (_isAxisAlignedRectangle(contours)) {
      _clipStack[_clipStack.length - 1] = _clip.intersectBounds(bounds);
      return;
    }
    _clipStack[_clipStack.length - 1] = _clip.intersect(
      bounds,
      contours: contours,
      rule: rule,
    );
  }

  @override
  void drawText(PdfTextRun run) {
    if (run.invisible) {
      _traceRegion(
        'skipText',
        _textRunTraceRegion(run),
        'reason=invisible font=${run.fontName} text="${_snippet(run.text)}"',
      );
      return;
    }
    if (run.glyphs == null) {
      _traceRegion(
        'skipText',
        _textRunTraceRegion(run),
        'reason=noOutlines font=${run.fontName} size=${_f(run.fontSize)} '
            'text="${_snippet(run.text)}"',
      );
      return;
    }
    final glyphTransform = run.transform.concat(_transform);
    for (final glyph in run.glyphs!) {
      final outline = glyph.outline;
      if (outline == null) continue;
      final shifted = PdfMatrix.translation(
        glyph.offset,
        0,
      ).concat(glyphTransform);
      if (glyphRasterCache?._paintGlyph(
            surface: _surface,
            clip: _clip,
            outline: outline,
            transform: shifted,
            color: run.color,
            alpha: 1,
            timing: timing,
          ) ??
          false) {
        continue;
      }
      _fillPathWithTransform(
        outline,
        run.color,
        PdfFillRule.nonzero,
        1,
        shifted,
        operation: 'drawText',
        details:
            'glyphOffset=${_f(glyph.offset)} ${_colorDetails(run.color, 1)}',
      );
    }
  }

  @override
  void drawImage(PdfImageRequest request) {
    drawImageRequest(_ImageDrawRequest(request, _ImageColorContext.device));
  }

  @override
  void drawImageRequest(Object drawRequest) {
    drawRequest as _ImageDrawRequest;
    final request = drawRequest.request;
    final decoded = _decodeImage(drawRequest);
    if (decoded == null) return;
    final matrix = request.transform.concat(_transform);
    final inverse = matrix.inverted();
    if (inverse == null) return;

    final corners = [
      _Point(matrix.transformX(0, 0), matrix.transformY(0, 0)),
      _Point(matrix.transformX(1, 0), matrix.transformY(1, 0)),
      _Point(matrix.transformX(1, 1), matrix.transformY(1, 1)),
      _Point(matrix.transformX(0, 1), matrix.transformY(0, 1)),
    ];
    final bounds = _boundsOf([corners])?.intersect(_clip.bounds);
    if (bounds == null || bounds.isEmpty) return;
    _trace(
      'drawImage',
      bounds,
      'source=${decoded.width}x${decoded.height} alpha=${_f(request.alpha)} '
          'clip=${_clip.bounds}',
    );

    final alpha = (request.alpha.clamp(0, 1) * 255).round();
    final needsClip = _clip.paths.isNotEmpty;
    if (!needsClip && alpha >= 255 && decoded.opaque) {
      _drawOpaqueImageNoClip(bounds, inverse, decoded);
      return;
    }

    final dstPixels = _surface.pixels;
    final dstWidth = _surface.width;
    _surface.markDirty(bounds);
    final srcPixels = decoded.rgba;
    final srcWidth = decoded.width;
    final srcHeight = decoded.height;
    final stepUx = inverse.a;
    final stepUy = inverse.b;
    final rowStartX = bounds.left + 0.5;
    for (var py = bounds.top; py < bounds.bottom; py++) {
      final sy = py + 0.5;
      var ux = inverse.transformX(rowStartX, sy);
      var uy = inverse.transformY(rowStartX, sy);
      var px = bounds.left;
      while (px < bounds.right) {
        if (needsClip && !_clip.contains(px + 0.5, sy)) {
          px++;
          ux += stepUx;
          uy += stepUy;
          continue;
        }
        if (ux >= 0 && ux <= 1 && uy >= 0 && uy <= 1) {
          final sample = _sampleImageBilinear(
            srcPixels,
            srcWidth,
            srcHeight,
            ux,
            uy,
          );
          final a = ((sample >>> 24) & 0xff) * alpha ~/ 255;
          if (a >= 255) {
            final dstOffset = (py * dstWidth + px) * 4;
            dstPixels[dstOffset] = sample & 0xff;
            dstPixels[dstOffset + 1] = (sample >>> 8) & 0xff;
            dstPixels[dstOffset + 2] = (sample >>> 16) & 0xff;
            dstPixels[dstOffset + 3] = 255;
          } else if (a > 0) {
            final dstOffset = (py * dstWidth + px) * 4;
            final inv = 255 - a;
            dstPixels[dstOffset] =
                ((sample & 0xff) * a + dstPixels[dstOffset] * inv) ~/ 255;
            dstPixels[dstOffset + 1] =
                (((sample >>> 8) & 0xff) * a +
                    dstPixels[dstOffset + 1] * inv) ~/
                255;
            dstPixels[dstOffset + 2] =
                (((sample >>> 16) & 0xff) * a +
                    dstPixels[dstOffset + 2] * inv) ~/
                255;
            if (a > dstPixels[dstOffset + 3]) dstPixels[dstOffset + 3] = a;
          }
        }
        px++;
        ux += stepUx;
        uy += stepUy;
      }
    }
  }

  void _drawOpaqueImageNoClip(
    _IntRect bounds,
    PdfMatrix inverse,
    _DecodedImage decoded,
  ) {
    final dstPixels = _surface.pixels;
    final dstWidth = _surface.width;
    _surface.markDirty(bounds);
    final srcPixels = decoded.rgba;
    final srcWidth = decoded.width;
    final srcHeight = decoded.height;
    final ia = inverse.a;
    final ib = inverse.b;
    final ic = inverse.c;
    final id = inverse.d;
    final ie = inverse.e;
    final iff = inverse.f;
    final rowStartX = bounds.left + 0.5;

    if (ib.abs() < 1e-12 && ic.abs() < 1e-12) {
      final footprintX = (ia.abs() * srcWidth).clamp(1.0, srcWidth.toDouble());
      final footprintY = (id.abs() * srcHeight).clamp(
        1.0,
        srcHeight.toDouble(),
      );
      final useBoxFilter = footprintX > 1.25 || footprintY > 1.25;
      for (var py = bounds.top; py < bounds.bottom; py++) {
        final sy = py + 0.5;
        final uy = id * sy + iff;
        if (uy < 0 || uy > 1) continue;
        var ux = ia * rowStartX + ie;
        var dstOffset = (py * dstWidth + bounds.left) * 4;
        for (var px = bounds.left; px < bounds.right; px++) {
          if (ux >= 0 && ux <= 1) {
            final sample = useBoxFilter
                ? _sampleImageBox(
                    srcPixels,
                    srcWidth,
                    srcHeight,
                    ux,
                    uy,
                    footprintX,
                    footprintY,
                  )
                : _sampleImageBilinear(srcPixels, srcWidth, srcHeight, ux, uy);
            dstPixels[dstOffset] = sample & 0xff;
            dstPixels[dstOffset + 1] = (sample >>> 8) & 0xff;
            dstPixels[dstOffset + 2] = (sample >>> 16) & 0xff;
            dstPixels[dstOffset + 3] = 255;
          }
          dstOffset += 4;
          ux += ia;
        }
      }
      return;
    }

    for (var py = bounds.top; py < bounds.bottom; py++) {
      final sy = py + 0.5;
      var ux = ia * rowStartX + ic * sy + ie;
      var uy = ib * rowStartX + id * sy + iff;
      var dstOffset = (py * dstWidth + bounds.left) * 4;
      for (var px = bounds.left; px < bounds.right; px++) {
        if (ux >= 0 && ux <= 1 && uy >= 0 && uy <= 1) {
          final sample = _sampleImageBilinear(
            srcPixels,
            srcWidth,
            srcHeight,
            ux,
            uy,
          );
          dstPixels[dstOffset] = sample & 0xff;
          dstPixels[dstOffset + 1] = (sample >>> 8) & 0xff;
          dstPixels[dstOffset + 2] = (sample >>> 16) & 0xff;
          dstPixels[dstOffset + 3] = 255;
        }
        dstOffset += 4;
        ux += ia;
        uy += ib;
      }
    }
  }

  @override
  void setBlendMode(PdfBlendMode mode) {
    _trace('setBlendMode', _clip.bounds, mode.name);
  }

  @override
  void beginGroup(double alpha, {bool knockout = false}) {
    _trace('beginGroup', _clip.bounds, 'alpha=${_f(alpha)} knockout=$knockout');
    _groupAlphaStack.add(alpha.clamp(0, 1));
    _surfaceStack.add(_RgbaSurface(_surface.width, _surface.height));
  }

  @override
  void endGroup() {
    if (_surfaceStack.length <= 1) return;
    final layer = _surfaceStack.removeLast();
    final alpha = _groupAlphaStack.isEmpty
        ? 1.0
        : _groupAlphaStack.removeLast();
    _trace('endGroup', _clip.bounds, 'alpha=${_f(alpha)}');
    final parent = _surface;
    final dirtyBounds = layer.dirtyBounds;
    if (dirtyBounds == null || dirtyBounds.isEmpty) return;
    for (var y = dirtyBounds.top; y < dirtyBounds.bottom; y++) {
      for (var x = dirtyBounds.left; x < dirtyBounds.right; x++) {
        final offset = (y * layer.width + x) * 4;
        final a = (layer.pixels[offset + 3] * alpha).round();
        if (a == 0) continue;
        parent.blendPixel(
          x,
          y,
          layer.pixels[offset],
          layer.pixels[offset + 1],
          layer.pixels[offset + 2],
          a,
        );
      }
    }
  }

  @override
  void beginSoftMasked() {
    _trace('beginSoftMasked', _clip.bounds);
    _surfaceStack.add(_RgbaSurface(_surface.width, _surface.height));
  }

  @override
  void endSoftMasked({
    required bool luminosity,
    required PdfRect backdrop,
    required void Function() drawMask,
    double backdropLuminance = 0,
    double transferScale = 1,
    double transferOffset = 0,
  }) {
    _traceRegion(
      'endSoftMasked',
      _rectToTraceRegion(backdrop),
      'luminosity=$luminosity backdropLuminance=${_f(backdropLuminance)} '
          'transferScale=${_f(transferScale)} '
          'transferOffset=${_f(transferOffset)}',
    );
    if (_surfaceStack.length <= 1) {
      return;
    }
    final content = _surfaceStack.removeLast();
    final mask = _RgbaSurface(_surface.width, _surface.height);
    _surfaceStack.add(mask);
    drawMask();
    _surfaceStack.removeLast();
    _compositeSoftMaskedContent(
      content,
      mask,
      luminosity: luminosity,
      backdropLuminance: backdropLuminance,
      transferScale: transferScale,
      transferOffset: transferOffset,
    );
  }

  void _compositeSoftMaskedContent(
    _RgbaSurface content,
    _RgbaSurface mask, {
    required bool luminosity,
    required double backdropLuminance,
    required double transferScale,
    required double transferOffset,
  }) {
    final dirtyBounds = content.dirtyBounds;
    if (dirtyBounds == null || dirtyBounds.isEmpty) return;
    final parent = _surface;
    final contentPixels = content.pixels;
    final maskPixels = mask.pixels;
    final backdrop = backdropLuminance.clamp(0.0, 1.0);
    for (var y = dirtyBounds.top; y < dirtyBounds.bottom; y++) {
      for (var x = dirtyBounds.left; x < dirtyBounds.right; x++) {
        final offset = (y * content.width + x) * 4;
        final contentAlpha = contentPixels[offset + 3];
        if (contentAlpha == 0) continue;
        final maskAlpha = maskPixels[offset + 3] / 255.0;
        final rawMask = luminosity
            ? backdrop * (1 - maskAlpha) +
                  _luminance(
                        maskPixels[offset],
                        maskPixels[offset + 1],
                        maskPixels[offset + 2],
                      ) *
                      maskAlpha
            : maskAlpha;
        final transferred = (rawMask * transferScale + transferOffset).clamp(
          0.0,
          1.0,
        );
        final alpha = (contentAlpha * transferred).round();
        if (alpha == 0) continue;
        parent.blendPixel(
          x,
          y,
          contentPixels[offset],
          contentPixels[offset + 1],
          contentPixels[offset + 2],
          alpha,
        );
      }
    }
  }

  void _fillPath(
    PdfPath path,
    PdfColor color,
    PdfFillRule rule,
    double alpha, {
    required String operation,
    String? details,
  }) {
    _fillPathWithTransform(
      path,
      color,
      rule,
      alpha,
      _transform,
      operation: operation,
      details: details,
    );
  }

  void _fillPathWithTransform(
    PdfPath path,
    PdfColor color,
    PdfFillRule rule,
    double alpha,
    PdfMatrix transform, {
    required String operation,
    String? details,
  }) {
    final contours = _flatten(path, transform: transform);
    if (contours.isEmpty) return;
    final bounds = _boundsOf(contours)?.intersect(_clip.bounds);
    if (bounds == null || bounds.isEmpty) return;
    _trace(
      operation,
      bounds,
      details ??
          '${_colorDetails(color, alpha)} rule=${rule.name} '
              'clip=${_clip.bounds}',
    );

    final r = (color.red.clamp(0, 1) * 255).round();
    final g = (color.green.clamp(0, 1) * 255).round();
    final b = (color.blue.clamp(0, 1) * 255).round();
    final a = (alpha.clamp(0, 1) * 255).round();
    if (_clip.paths.isEmpty && _isPixelAlignedRectangle(contours, bounds)) {
      _fillRectangle(bounds, r, g, b, a);
      return;
    }
    final mask = _buildFillCoverageMask(bounds, contours, rule);
    final dstPixels = _surface.pixels;
    final dstWidth = _surface.width;
    _surface.markDirty(bounds);
    final maskValues = mask._values;
    final maskBoundary = mask._boundary;
    final maskWidth = mask.width;
    final maskOriginX = mask.originX;
    final maskOriginY = mask.originY;
    final opaque = a >= 255;
    for (var py = bounds.top; py < bounds.bottom; py++) {
      var maskOffset =
          (py - maskOriginY) * maskWidth + bounds.left - maskOriginX;
      var dstOffset = (py * dstWidth + bounds.left) * 4;
      for (var px = bounds.left; px < bounds.right; px++) {
        if (maskBoundary[maskOffset] == 0) {
          if (maskValues[maskOffset] == 0) {
            maskOffset++;
            dstOffset += 4;
            continue;
          }
          if (opaque) {
            dstPixels[dstOffset] = r;
            dstPixels[dstOffset + 1] = g;
            dstPixels[dstOffset + 2] = b;
            dstPixels[dstOffset + 3] = 255;
          } else {
            final inv = 255 - a;
            dstPixels[dstOffset] = (r * a + dstPixels[dstOffset] * inv) ~/ 255;
            dstPixels[dstOffset + 1] =
                (g * a + dstPixels[dstOffset + 1] * inv) ~/ 255;
            dstPixels[dstOffset + 2] =
                (b * a + dstPixels[dstOffset + 2] * inv) ~/ 255;
            if (a > dstPixels[dstOffset + 3]) dstPixels[dstOffset + 3] = a;
          }
          maskOffset++;
          dstOffset += 4;
          continue;
        }
        final coveredSamples = _fillCoverageSamples(px, py, contours, rule);
        if (coveredSamples != 0) {
          final coverageAlpha = (a * coveredSamples * _antiAliasSampleScale)
              .round();
          final inv = 255 - coverageAlpha;
          dstPixels[dstOffset] =
              (r * coverageAlpha + dstPixels[dstOffset] * inv) ~/ 255;
          dstPixels[dstOffset + 1] =
              (g * coverageAlpha + dstPixels[dstOffset + 1] * inv) ~/ 255;
          dstPixels[dstOffset + 2] =
              (b * coverageAlpha + dstPixels[dstOffset + 2] * inv) ~/ 255;
          if (coverageAlpha > dstPixels[dstOffset + 3]) {
            dstPixels[dstOffset + 3] = coverageAlpha;
          }
        }
        maskOffset++;
        dstOffset += 4;
      }
    }
  }

  void _fillPathGradient(
    PdfPath path,
    PdfFillRule rule,
    PdfGradient gradient,
    double alpha,
  ) {
    if (gradient.isRadial || gradient.coords.length < 4) {
      _fillPath(
        path,
        gradient.averageColor,
        rule,
        alpha,
        operation: 'fillPathGradient',
        details: 'alpha=${_f(alpha)} rule=${rule.name} fallback=averageColor',
      );
      return;
    }

    final contours = _flatten(path, transform: PdfMatrix.identity);
    if (contours.isEmpty) return;
    final bounds = _boundsOf(contours)?.intersect(_clip.bounds);
    if (bounds == null || bounds.isEmpty) return;
    _trace(
      'fillPathGradient',
      bounds,
      'alpha=${_f(alpha)} rule=${rule.name} type=axial '
          'coords=${gradient.coords.map(_f).join(',')} '
          'line=${_gradientLineDetails(gradient)} '
          'c0=${_colorDetails(gradient.colors.first, 1)} '
          'cN=${_colorDetails(gradient.colors.last, 1)} '
          'clip=${_clip.bounds}',
    );

    final a = (alpha.clamp(0, 1) * 255).round();
    if (a <= 0) return;
    final mask = _buildFillCoverageMask(bounds, contours, rule);
    final dstPixels = _surface.pixels;
    final dstWidth = _surface.width;
    _surface.markDirty(bounds);
    final maskValues = mask._values;
    final maskBoundary = mask._boundary;
    final maskWidth = mask.width;
    final maskOriginX = mask.originX;
    final maskOriginY = mask.originY;
    final opaque = a >= 255;

    for (var py = bounds.top; py < bounds.bottom; py++) {
      var maskOffset =
          (py - maskOriginY) * maskWidth + bounds.left - maskOriginX;
      var dstOffset = (py * dstWidth + bounds.left) * 4;
      for (var px = bounds.left; px < bounds.right; px++) {
        if (maskBoundary[maskOffset] == 0) {
          if (maskValues[maskOffset] != 0) {
            final color = _axialGradientColorAt(gradient, px + 0.5, py + 0.5);
            if (color != null) {
              final r = (color.red.clamp(0, 1) * 255).round();
              final g = (color.green.clamp(0, 1) * 255).round();
              final b = (color.blue.clamp(0, 1) * 255).round();
              if (opaque) {
                dstPixels[dstOffset] = r;
                dstPixels[dstOffset + 1] = g;
                dstPixels[dstOffset + 2] = b;
                dstPixels[dstOffset + 3] = 255;
              } else {
                final inv = 255 - a;
                dstPixels[dstOffset] =
                    (r * a + dstPixels[dstOffset] * inv) ~/ 255;
                dstPixels[dstOffset + 1] =
                    (g * a + dstPixels[dstOffset + 1] * inv) ~/ 255;
                dstPixels[dstOffset + 2] =
                    (b * a + dstPixels[dstOffset + 2] * inv) ~/ 255;
                if (a > dstPixels[dstOffset + 3]) dstPixels[dstOffset + 3] = a;
              }
            }
          }
          maskOffset++;
          dstOffset += 4;
          continue;
        }
        final coveredSamples = _fillCoverageSamples(px, py, contours, rule);
        if (coveredSamples != 0) {
          final color = _axialGradientColorAt(gradient, px + 0.5, py + 0.5);
          if (color != null) {
            final coverageAlpha = (a * coveredSamples * _antiAliasSampleScale)
                .round();
            final inv = 255 - coverageAlpha;
            final r = (color.red.clamp(0, 1) * 255).round();
            final g = (color.green.clamp(0, 1) * 255).round();
            final b = (color.blue.clamp(0, 1) * 255).round();
            dstPixels[dstOffset] =
                (r * coverageAlpha + dstPixels[dstOffset] * inv) ~/ 255;
            dstPixels[dstOffset + 1] =
                (g * coverageAlpha + dstPixels[dstOffset + 1] * inv) ~/ 255;
            dstPixels[dstOffset + 2] =
                (b * coverageAlpha + dstPixels[dstOffset + 2] * inv) ~/ 255;
            if (coverageAlpha > dstPixels[dstOffset + 3]) {
              dstPixels[dstOffset + 3] = coverageAlpha;
            }
          }
        }
        maskOffset++;
        dstOffset += 4;
      }
    }
  }

  void _fillRectangle(_IntRect bounds, int r, int g, int b, int a) {
    if (a <= 0) return;
    final clipped = bounds.intersect(_clip.bounds);
    if (clipped.isEmpty) return;
    final dstPixels = _surface.pixels;
    final dstWidth = _surface.width;
    _surface.markDirty(clipped);
    if (a >= 255) {
      for (var py = clipped.top; py < clipped.bottom; py++) {
        var dstOffset = (py * dstWidth + clipped.left) * 4;
        for (var px = clipped.left; px < clipped.right; px++) {
          dstPixels[dstOffset] = r;
          dstPixels[dstOffset + 1] = g;
          dstPixels[dstOffset + 2] = b;
          dstPixels[dstOffset + 3] = 255;
          dstOffset += 4;
        }
      }
      return;
    }
    final inv = 255 - a;
    for (var py = clipped.top; py < clipped.bottom; py++) {
      var dstOffset = (py * dstWidth + clipped.left) * 4;
      for (var px = clipped.left; px < clipped.right; px++) {
        dstPixels[dstOffset] = (r * a + dstPixels[dstOffset] * inv) ~/ 255;
        dstPixels[dstOffset + 1] =
            (g * a + dstPixels[dstOffset + 1] * inv) ~/ 255;
        dstPixels[dstOffset + 2] =
            (b * a + dstPixels[dstOffset + 2] * inv) ~/ 255;
        if (a > dstPixels[dstOffset + 3]) dstPixels[dstOffset + 3] = a;
        dstOffset += 4;
      }
    }
  }

  _FillCoverageMask _buildFillCoverageMask(
    _IntRect bounds,
    List<List<_Point>> contours,
    PdfFillRule rule,
  ) {
    final mask = _FillCoverageMask(bounds);
    if (_clip.paths.isEmpty) {
      _buildFillCoverageMaskByScanline(mask, bounds, contours, rule);
    } else {
      _buildFillCoverageMaskByPointTest(mask, bounds, contours, rule);
    }
    mask.markBoundaryTransitions(bounds);
    _markFillBoundaryPixels(mask, bounds, contours);
    return mask;
  }

  void _buildFillCoverageMaskByPointTest(
    _FillCoverageMask mask,
    _IntRect bounds,
    List<List<_Point>> contours,
    PdfFillRule rule,
  ) {
    for (var py = bounds.top - 1; py <= bounds.bottom; py++) {
      final y = py + 0.5;
      for (var px = bounds.left - 1; px <= bounds.right; px++) {
        final x = px + 0.5;
        mask.set(px, py, _fillCoversPoint(contours, rule, x, y));
      }
    }
  }

  void _buildFillCoverageMaskByScanline(
    _FillCoverageMask mask,
    _IntRect bounds,
    List<List<_Point>> contours,
    PdfFillRule rule,
  ) {
    final events = <_ScanlineIntersection>[];
    final clipBounds = _clip.bounds;
    final minX = math.max(bounds.left - 1, clipBounds.left);
    final maxX = math.min(bounds.right, clipBounds.right - 1);
    if (minX > maxX) return;

    for (var py = bounds.top - 1; py <= bounds.bottom; py++) {
      final y = py + 0.5;
      if (y < clipBounds.top || y >= clipBounds.bottom) continue;
      events.clear();
      for (final contour in contours) {
        for (var i = 0; i < contour.length - 1; i++) {
          final p1 = contour[i];
          final p2 = contour[i + 1];
          if (p1.y == p2.y) continue;
          final minY = math.min(p1.y, p2.y);
          final maxY = math.max(p1.y, p2.y);
          if (y < minY || y >= maxY) continue;
          final t = (y - p1.y) / (p2.y - p1.y);
          final x = p1.x + (p2.x - p1.x) * t;
          events.add(_ScanlineIntersection(x, p2.y > p1.y ? 1 : -1));
        }
      }
      if (events.isEmpty) continue;
      events.sort((a, b) => a.x.compareTo(b.x));

      if (rule == PdfFillRule.evenOdd) {
        var inside = false;
        var spanStart = 0.0;
        for (final event in events) {
          if (inside) {
            _markFillSpan(mask, py, spanStart, event.x, minX, maxX);
          }
          inside = !inside;
          spanStart = event.x;
        }
      } else {
        var winding = 0;
        var spanStart = 0.0;
        for (final event in events) {
          if (winding != 0) {
            _markFillSpan(mask, py, spanStart, event.x, minX, maxX);
          }
          winding += event.windingDelta;
          spanStart = event.x;
        }
      }
    }
  }

  void _markFillSpan(
    _FillCoverageMask mask,
    int py,
    double x1,
    double x2,
    int minX,
    int maxX,
  ) {
    if (x2 <= x1) return;
    final start = math.max(minX, (x1 - 0.5).ceil());
    final end = math.min(maxX, (x2 - 0.5).floor());
    for (var px = start; px <= end; px++) {
      mask.set(px, py, true);
    }
  }

  void _markFillBoundaryPixels(
    _FillCoverageMask mask,
    _IntRect bounds,
    List<List<_Point>> contours,
  ) {
    for (final contour in contours) {
      for (var i = 0; i < contour.length - 1; i++) {
        final p1 = contour[i];
        final p2 = contour[i + 1];
        final dx = p2.x - p1.x;
        final dy = p2.y - p1.y;
        final steps = math.max(dx.abs(), dy.abs()).ceil();
        for (var step = 0; step <= steps; step++) {
          final t = steps == 0 ? 0.0 : step / steps;
          final x = p1.x + dx * t;
          final y = p1.y + dy * t;
          final centerX = x.floor();
          final centerY = y.floor();
          for (var offsetY = -1; offsetY <= 1; offsetY++) {
            final py = centerY + offsetY;
            if (py < bounds.top || py >= bounds.bottom) continue;
            for (var offsetX = -1; offsetX <= 1; offsetX++) {
              final px = centerX + offsetX;
              if (px < bounds.left || px >= bounds.right) continue;
              mask.markBoundary(px, py);
            }
          }
        }
      }
    }
  }

  int _fillCoverageSamples(
    int px,
    int py,
    List<List<_Point>> contours,
    PdfFillRule rule,
  ) {
    var coveredSamples = 0;
    for (var sy = 0; sy < _antiAliasSamplesPerAxis; sy++) {
      final y = py + (sy + 0.5) / _antiAliasSamplesPerAxis;
      for (var sx = 0; sx < _antiAliasSamplesPerAxis; sx++) {
        final x = px + (sx + 0.5) / _antiAliasSamplesPerAxis;
        if (_fillCoversPoint(contours, rule, x, y)) coveredSamples++;
      }
    }
    return coveredSamples;
  }

  bool _fillCoversPoint(
    List<List<_Point>> contours,
    PdfFillRule rule,
    double x,
    double y,
  ) {
    final inside = rule == PdfFillRule.evenOdd
        ? _containsEvenOdd(contours, x, y)
        : _containsNonZero(contours, x, y);
    return inside && _clip.contains(x, y);
  }

  void _trace(String operation, _IntRect bounds, [String? details]) {
    trace?.add(
      operation,
      bounds.toTraceRegion(),
      details: details == null
          ? 'groupDepth=${_surfaceStack.length - 1}'
          : '$details groupDepth=${_surfaceStack.length - 1}',
    );
  }

  void _traceRegion(
    String operation,
    PdfRenderTraceRegion bounds, [
    String? details,
  ]) {
    trace?.add(
      operation,
      bounds,
      details: details == null
          ? 'groupDepth=${_surfaceStack.length - 1}'
          : '$details groupDepth=${_surfaceStack.length - 1}',
    );
  }

  String _colorDetails(PdfColor color, double alpha) =>
      'rgb=${_f(color.red)},${_f(color.green)},${_f(color.blue)} '
      'alpha=${_f(alpha)}';

  String _gradientLineDetails(PdfGradient gradient) {
    final coords = gradient.coords;
    if (coords.length < 4) return '(none)';
    final matrix = gradient.transform;
    final x0 = matrix.transformX(coords[0], coords[1]);
    final y0 = matrix.transformY(coords[0], coords[1]);
    final x1 = matrix.transformX(coords[2], coords[3]);
    final y1 = matrix.transformY(coords[2], coords[3]);
    return '${_f(x0)},${_f(y0)}->${_f(x1)},${_f(y1)}';
  }

  String _f(double value) => value.toStringAsFixed(3);

  PdfRenderTraceRegion _rectToTraceRegion(PdfRect rect) {
    final points = [
      _Point(
        _transform.transformX(rect.left, rect.top),
        _transform.transformY(rect.left, rect.top),
      ),
      _Point(
        _transform.transformX(rect.right, rect.top),
        _transform.transformY(rect.right, rect.top),
      ),
      _Point(
        _transform.transformX(rect.right, rect.bottom),
        _transform.transformY(rect.right, rect.bottom),
      ),
      _Point(
        _transform.transformX(rect.left, rect.bottom),
        _transform.transformY(rect.left, rect.bottom),
      ),
    ];
    final bounds = _boundsOf([points]);
    return bounds?.toTraceRegion() ?? const PdfRenderTraceRegion(0, 0, 0, 0);
  }

  PdfRenderTraceRegion _textRunTraceRegion(PdfTextRun run) {
    final matrix = run.transform.concat(_transform);
    final corners = [
      _Point(matrix.transformX(0, -0.25), matrix.transformY(0, -0.25)),
      _Point(
        matrix.transformX(run.width, -0.25),
        matrix.transformY(run.width, -0.25),
      ),
      _Point(matrix.transformX(run.width, 1), matrix.transformY(run.width, 1)),
      _Point(matrix.transformX(0, 1), matrix.transformY(0, 1)),
    ];
    final bounds = _boundsOf([corners]);
    return bounds?.toTraceRegion() ?? const PdfRenderTraceRegion(0, 0, 0, 0);
  }

  String _snippet(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 48) return normalized;
    return '${normalized.substring(0, 45)}...';
  }

  List<List<_Point>> _flatten(PdfPath path, {PdfMatrix? transform}) {
    return _flattenPath(path, transform: transform ?? _transform);
  }

  _IntRect? _boundsOf(List<List<_Point>> contours) {
    if (contours.isEmpty) return null;
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (final contour in contours) {
      for (final p in contour) {
        left = math.min(left, p.x);
        top = math.min(top, p.y);
        right = math.max(right, p.x);
        bottom = math.max(bottom, p.y);
      }
    }
    return _IntRect(
      left.floor().clamp(0, _surface.width),
      top.floor().clamp(0, _surface.height),
      right.ceil().clamp(0, _surface.width),
      bottom.ceil().clamp(0, _surface.height),
    );
  }

  void _strokeContour(
    List<_Point> points,
    double width,
    List<double> dashes,
    double dashPhase,
    int r,
    int g,
    int b,
    int a,
  ) {
    if (points.length < 2) return;
    var dashIndex = 0;
    var dashRemaining = dashes.isEmpty ? double.infinity : dashes.first;
    var dashOn = true;
    if (dashes.isNotEmpty) {
      final cycle = dashes.fold<double>(0, (sum, dash) => sum + dash);
      var skip = cycle == 0 ? 0.0 : dashPhase.abs() % cycle;
      while (skip > 0 && dashes.isNotEmpty) {
        if (skip >= dashRemaining) {
          skip -= dashRemaining;
          dashIndex = (dashIndex + 1) % dashes.length;
          dashOn = !dashOn;
          dashRemaining = dashes[dashIndex];
        } else {
          dashRemaining -= skip;
          skip = 0;
        }
      }
    }

    for (var i = 0; i < points.length - 1; i++) {
      var start = points[i];
      final end = points[i + 1];
      var remaining = start.distanceTo(end);
      if (remaining <= 1e-6) continue;
      final direction = _Point(
        (end.x - start.x) / remaining,
        (end.y - start.y) / remaining,
      );
      while (remaining > 1e-6) {
        final length = math.min(remaining, dashRemaining);
        final segmentEnd = _Point(
          start.x + direction.x * length,
          start.y + direction.y * length,
        );
        if (dashOn) {
          _drawStrokeSegment(start, segmentEnd, width, r, g, b, a);
        }
        start = segmentEnd;
        remaining -= length;
        if (dashes.isNotEmpty) {
          dashRemaining -= length;
          if (dashRemaining <= 1e-6) {
            dashIndex = (dashIndex + 1) % dashes.length;
            dashOn = !dashOn;
            dashRemaining = dashes[dashIndex];
          }
        }
      }
    }
  }

  void _drawStrokeSegment(
    _Point p1,
    _Point p2,
    double width,
    int r,
    int g,
    int b,
    int a,
  ) {
    final radius = width / 2;
    final antialiasRadius = radius + 0.5;
    final bounds = _IntRect(
      (math.min(p1.x, p2.x) - antialiasRadius).floor().clamp(0, _surface.width),
      (math.min(p1.y, p2.y) - antialiasRadius).floor().clamp(
        0,
        _surface.height,
      ),
      (math.max(p1.x, p2.x) + antialiasRadius).ceil().clamp(0, _surface.width),
      (math.max(p1.y, p2.y) + antialiasRadius).ceil().clamp(0, _surface.height),
    ).intersect(_clip.bounds);
    if (bounds.isEmpty) return;
    final dx = p2.x - p1.x;
    final dy = p2.y - p1.y;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= 1e-12) return;
    for (var py = bounds.top; py < bounds.bottom; py++) {
      for (var px = bounds.left; px < bounds.right; px++) {
        final coverage = _strokeCoverageAtPixel(
          px,
          py,
          p1,
          dx,
          dy,
          lengthSquared,
          radius,
        );
        if (coverage <= 0) continue;
        _surface.blendPixel(px, py, r, g, b, (a * coverage).round());
      }
    }
  }

  double _strokeCoverageAtPixel(
    int px,
    int py,
    _Point p1,
    double dx,
    double dy,
    double lengthSquared,
    double radius,
  ) {
    var coverage = 0.0;
    for (var sy = 0; sy < _antiAliasSamplesPerAxis; sy++) {
      final y = py + (sy + 0.5) / _antiAliasSamplesPerAxis;
      for (var sx = 0; sx < _antiAliasSamplesPerAxis; sx++) {
        final x = px + (sx + 0.5) / _antiAliasSamplesPerAxis;
        if (!_clip.contains(x, y)) continue;
        coverage += _strokeCoverageAtPoint(
          x,
          y,
          p1,
          dx,
          dy,
          lengthSquared,
          radius,
        );
      }
    }
    return coverage * _antiAliasSampleScale;
  }

  _DecodedImage? _decodeImage(_ImageDrawRequest request) {
    final cache = imageDecodeCache;
    return cache == null
        ? _decodePdfImage(request, cosDocument)
        : cache._decode(request, cosDocument);
  }
}

const _defaultMaxDecodedImageCacheBytes = 64 * 1024 * 1024;
const _defaultMaxDecodedImageCacheEntries = 64;

class _ImageColorContext {
  _ImageColorContext._({
    required this.defaultGray,
    required this.defaultRgb,
    required this.defaultCmyk,
    required this.namedColorSpaces,
  }) : cacheKey = _nextCacheKey++;

  factory _ImageColorContext.fromDocument(cos.CosDocument cosDocument) {
    return _ImageColorContext._(
      defaultGray: null,
      defaultRgb: null,
      defaultCmyk: _outputIntentCmyk(cosDocument),
      namedColorSpaces: const {},
    );
  }

  factory _ImageColorContext.fromResources(
    cos.CosDocument cosDocument,
    cos.CosDictionary resources, {
    required _ImageColorContext parent,
  }) {
    final spaces = cosDocument.resolve(resources['ColorSpace']);
    if (spaces is! cos.CosDictionary) return parent;

    final namedColorSpaces = <String, cos.CosObject>{};
    for (final entry in spaces.entries.entries) {
      if (!_defaultColorSpaceNames.contains(entry.key)) {
        namedColorSpaces[entry.key] = entry.value;
      }
    }
    final namedContext = namedColorSpaces.isEmpty
        ? parent
        : _ImageColorContext._(
            defaultGray: parent.defaultGray,
            defaultRgb: parent.defaultRgb,
            defaultCmyk: parent.defaultCmyk,
            namedColorSpaces: namedColorSpaces,
          );

    _ImageColorSpace? defaultSpace(String name) {
      final object = spaces[name];
      if (object == null) return null;
      return _ImageColorSpace.parse(
        cosDocument,
        object,
        context: namedContext,
        useDeviceDefaults: false,
      );
    }

    if (namedColorSpaces.isEmpty &&
        spaces['DefaultGray'] == null &&
        spaces['DefaultRGB'] == null &&
        spaces['DefaultCMYK'] == null) {
      return parent;
    }

    return _ImageColorContext._(
      defaultGray: defaultSpace('DefaultGray') ?? parent.defaultGray,
      defaultRgb: defaultSpace('DefaultRGB') ?? parent.defaultRgb,
      defaultCmyk: defaultSpace('DefaultCMYK') ?? parent.defaultCmyk,
      namedColorSpaces: namedColorSpaces,
    );
  }

  static final device = _ImageColorContext._(
    defaultGray: null,
    defaultRgb: null,
    defaultCmyk: null,
    namedColorSpaces: const {},
  );

  static var _nextCacheKey = 1;

  final _ImageColorSpace? defaultGray;
  final _ImageColorSpace? defaultRgb;
  final _ImageColorSpace? defaultCmyk;
  final Map<String, cos.CosObject> namedColorSpaces;
  final int cacheKey;

  _ImageColorSpace? resolveNamed(
    cos.CosDocument cosDocument,
    String name, {
    bool useDeviceDefaults = true,
    Set<String>? resolvingNames,
  }) {
    final object = namedColorSpaces[name];
    if (object == null) return null;
    final resolving = resolvingNames ?? <String>{};
    if (!resolving.add(name)) return null;
    try {
      return _ImageColorSpace.parse(
        cosDocument,
        object,
        context: this,
        useDeviceDefaults: useDeviceDefaults,
        resolvingNames: resolving,
      );
    } finally {
      resolving.remove(name);
    }
  }
}

const _defaultColorSpaceNames = {'DefaultGray', 'DefaultRGB', 'DefaultCMYK'};

_ImageColorSpace? _outputIntentCmyk(cos.CosDocument cosDocument) {
  final root = cosDocument.resolve(cosDocument.trailer['Root']);
  if (root is! cos.CosDictionary) return null;
  final intents = cosDocument.resolve(root['OutputIntents']);
  final entries = switch (intents) {
    cos.CosArray(:final items) => items,
    cos.CosDictionary() => <cos.CosObject>[intents],
    _ => const <cos.CosObject>[],
  };
  for (final object in entries) {
    final intent = cosDocument.resolve(object);
    if (intent is! cos.CosDictionary) continue;
    final profile = cosDocument.resolve(intent['DestOutputProfile']);
    if (profile is! cos.CosStream) continue;
    final n = _intValue(cosDocument.resolve(profile.dictionary['N']));
    if (n != 4) continue;
    final iccProfile = _parseIccProfile(cosDocument, profile);
    if (iccProfile != null && iccProfile.channels == 4) {
      return _ImageColorSpace.cmyk(iccProfile: iccProfile);
    }
  }
  return null;
}

/// Cache for decoded image XObjects.
class PdfImageDecodeCache {
  /// Creates an image decode cache.
  PdfImageDecodeCache({
    this.maxEntries = _defaultMaxDecodedImageCacheEntries,
    this.maxBytes = _defaultMaxDecodedImageCacheBytes,
  });

  /// The maximum number of decoded images retained.
  final int maxEntries;

  /// The maximum total bytes retained by decoded images.
  final int maxBytes;
  final _entries = <_ImageDecodeKey, _DecodedImage>{};
  var _bytes = 0;

  /// The current number of decoded images in the cache.
  int get entryCount => _entries.length;

  /// The current total byte size of decoded image data.
  int get byteCount => _bytes;

  /// Removes all decoded images from the cache.
  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  _DecodedImage? _decode(
    _ImageDrawRequest request,
    cos.CosDocument cosDocument,
  ) {
    final key = _ImageDecodeKey.from(request);
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return cached;
    }

    final decoded = _decodePdfImage(request, cosDocument);
    if (decoded == null) return null;
    _entries[key] = decoded;
    _bytes += decoded.byteLength;
    _trim();
    return decoded;
  }

  void _trim() {
    while (_entries.length > maxEntries || _bytes > maxBytes) {
      final key = _entries.keys.first;
      final removed = _entries.remove(key);
      if (removed == null) break;
      _bytes -= removed.byteLength;
    }
  }
}

class _ImageDecodeKey {
  const _ImageDecodeKey(
    this.streamId,
    this.colorContextKey,
    this.isStencil,
    this.stencilR,
    this.stencilG,
    this.stencilB,
  );

  factory _ImageDecodeKey.from(_ImageDrawRequest request) => _ImageDecodeKey(
    identityHashCode(request.request.stream),
    request.colorContext.cacheKey,
    request.request.isStencil,
    (request.request.stencilColor.red.clamp(0, 1) * 255).round(),
    (request.request.stencilColor.green.clamp(0, 1) * 255).round(),
    (request.request.stencilColor.blue.clamp(0, 1) * 255).round(),
  );

  final int streamId;
  final int colorContextKey;
  final bool isStencil;
  final int stencilR;
  final int stencilG;
  final int stencilB;

  @override
  bool operator ==(Object other) =>
      other is _ImageDecodeKey &&
      streamId == other.streamId &&
      colorContextKey == other.colorContextKey &&
      isStencil == other.isStencil &&
      stencilR == other.stencilR &&
      stencilG == other.stencilG &&
      stencilB == other.stencilB;

  @override
  int get hashCode => Object.hash(
    streamId,
    colorContextKey,
    isStencil,
    stencilR,
    stencilG,
    stencilB,
  );
}

_DecodedImage? _decodePdfImage(
  _ImageDrawRequest drawRequest,
  cos.CosDocument cosDocument,
) {
  final request = drawRequest.request;
  final dict = request.stream.dictionary;
  final width = _intValue(cosDocument.resolve(dict['Width']));
  final height = _intValue(cosDocument.resolve(dict['Height']));
  if (width <= 0 || height <= 0) return null;
  if (request.isStencil) {
    return _decodeStencilImage(request, cosDocument, width, height);
  }

  final bits = _intValue(cosDocument.resolve(dict['BitsPerComponent']));
  final colorSpace = _ImageColorSpace.parse(
    cosDocument,
    dict['ColorSpace'],
    context: drawRequest.colorContext,
  );
  final filters = _filterNames(cosDocument, dict);
  if (filters.contains('JPXDecode')) {
    final bytes = cosDocument.decodeStreamData(
      request.stream,
      stopBeforeFilter: 'JPXDecode',
    );
    final decoded = cos.JpxDecoder.decode(bytes);
    if (decoded == null) return null;
    if (colorSpace != null &&
        colorSpace.inputComponents == decoded.components) {
      return _decodeSampledImage(
        cosDocument,
        dict,
        decoded.samples,
        decoded.width,
        decoded.height,
        8,
        colorSpace,
      );
    }
    return _decodeJpxWithoutPdfColorSpace(decoded);
  }
  if (filters.contains('DCTDecode') || filters.contains('DCT')) {
    final bytes = cosDocument.decodeStreamData(
      request.stream,
      stopBeforeFilter: filters.contains('DCTDecode') ? 'DCTDecode' : 'DCT',
    );
    if (colorSpace?.kind == _ImageColorSpaceKind.cmyk) {
      final decoded = _decodeCmykJpeg(cosDocument, dict, bytes, colorSpace!);
      if (decoded != null) return decoded;
    }
    final decoded = image.decodeImage(bytes);
    if (decoded == null) return null;
    final rgba = decoded.getBytes(order: image.ChannelOrder.rgba, alpha: 255);
    if (colorSpace != null && bits > 0) {
      _applyDecodedRgbImageColorSpace(
        rgba,
        cosDocument,
        dict,
        colorSpace,
        bits,
      );
    }
    return _DecodedImage(decoded.width, decoded.height, rgba, opaque: true);
  }

  if (!_isSupportedImageBits(bits) || colorSpace == null) return null;
  final data = cosDocument.decodeStreamData(request.stream);
  return _decodeSampledImage(
    cosDocument,
    dict,
    data,
    width,
    height,
    bits,
    colorSpace,
  );
}

_DecodedImage? _decodeJpxWithoutPdfColorSpace(cos.JpxImage image) {
  final pixelCount = image.width * image.height;
  if (image.samples.length < pixelCount * image.components) return null;
  final rgba = Uint8List(pixelCount * 4);
  var srcOffset = 0;
  var dstOffset = 0;
  switch (image.components) {
    case 1:
      for (var i = 0; i < pixelCount; i++) {
        final gray = image.samples[srcOffset++];
        rgba[dstOffset] = gray;
        rgba[dstOffset + 1] = gray;
        rgba[dstOffset + 2] = gray;
        rgba[dstOffset + 3] = 255;
        dstOffset += 4;
      }
    case 3:
      for (var i = 0; i < pixelCount; i++) {
        rgba[dstOffset] = image.samples[srcOffset++];
        rgba[dstOffset + 1] = image.samples[srcOffset++];
        rgba[dstOffset + 2] = image.samples[srcOffset++];
        rgba[dstOffset + 3] = 255;
        dstOffset += 4;
      }
    default:
      return null;
  }
  return _DecodedImage(image.width, image.height, rgba, opaque: true);
}

_DecodedImage? _decodeSampledImage(
  cos.CosDocument cosDocument,
  cos.CosDictionary dict,
  Uint8List data,
  int width,
  int height,
  int bits,
  _ImageColorSpace colorSpace,
) {
  final pixelCount = width * height;
  final components = colorSpace.inputComponents;
  if (!_hasEnoughSamples(data, pixelCount * components, bits)) return null;

  final decode = _ImageDecodeRanges.parse(
    cosDocument,
    dict['Decode'],
    colorSpace,
    bits,
  );
  final rgba = Uint8List(pixelCount * 4);
  var sampleIndex = 0;
  var dstOffset = 0;
  final rgb = List<int>.filled(3, 0);
  final componentsBuffer = List<int>.filled(
    math.max(1, colorSpace.inputComponents),
    0,
  );
  final iccTransform = _iccTransformFor(colorSpace);
  for (var i = 0; i < pixelCount; i++) {
    switch (colorSpace.kind) {
      case _ImageColorSpaceKind.gray:
        componentsBuffer[0] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          0,
        );
        colorSpace.toRgbBytes(componentsBuffer, rgb, iccTransform);
        rgba[dstOffset] = rgb[0];
        rgba[dstOffset + 1] = rgb[1];
        rgba[dstOffset + 2] = rgb[2];
      case _ImageColorSpaceKind.rgb:
        componentsBuffer[0] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          0,
        );
        componentsBuffer[1] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          1,
        );
        componentsBuffer[2] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          2,
        );
        colorSpace.toRgbBytes(componentsBuffer, rgb, iccTransform);
        rgba[dstOffset] = rgb[0];
        rgba[dstOffset + 1] = rgb[1];
        rgba[dstOffset + 2] = rgb[2];
      case _ImageColorSpaceKind.cmyk:
        componentsBuffer[0] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          0,
        );
        componentsBuffer[1] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          1,
        );
        componentsBuffer[2] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          2,
        );
        componentsBuffer[3] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          3,
        );
        colorSpace.toRgbBytes(componentsBuffer, rgb, iccTransform);
        rgba[dstOffset] = rgb[0];
        rgba[dstOffset + 1] = rgb[1];
        rgba[dstOffset + 2] = rgb[2];
      case _ImageColorSpaceKind.indexed:
        final index = decode.toIndex(
          _readSample(data, sampleIndex++, bits),
          bits,
          colorSpace.highValue,
        );
        _setIndexedColor(rgba, dstOffset, colorSpace, index, rgb);
    }
    rgba[dstOffset + 3] = 255;
    dstOffset += 4;
  }
  return _DecodedImage(width, height, rgba, opaque: true);
}

_DecodedImage? _decodeCmykJpeg(
  cos.CosDocument cosDocument,
  cos.CosDictionary dict,
  Uint8List bytes,
  _ImageColorSpace colorSpace,
) {
  try {
    final jpeg = image_internal.JpegData()..read(bytes);
    if (jpeg.components.length != 4) return null;
    final width = jpeg.width ?? 0;
    final height = jpeg.height ?? 0;
    if (width <= 0 || height <= 0) return null;

    final decode = _ImageDecodeRanges.parse(
      cosDocument,
      dict['Decode'],
      colorSpace,
      8,
    );
    final rgba = Uint8List(width * height * 4);
    final rgb = List<int>.filled(3, 0);

    final c1 = jpeg.components[0];
    final c2 = jpeg.components[1];
    final c3 = jpeg.components[2];
    final c4 = jpeg.components[3];
    final colorTransform = (jpeg.adobe?.transformCode ?? 0) != 0;
    final componentsBuffer = List<int>.filled(4, 0);
    final iccTransform = _iccTransformFor(colorSpace);
    var dstOffset = 0;

    for (var y = 0; y < height; y++) {
      final line1 = c1.lines[y >> c1.vScaleShift]!;
      final line2 = c2.lines[y >> c2.vScaleShift]!;
      final line3 = c3.lines[y >> c3.vScaleShift]!;
      final line4 = c4.lines[y >> c4.vScaleShift]!;
      for (var x = 0; x < width; x++) {
        final x1 = x >> c1.hScaleShift;
        final x2 = x >> c2.hScaleShift;
        final x3 = x >> c3.hScaleShift;
        final x4 = x >> c4.hScaleShift;
        int cyan;
        int magenta;
        int yellow;
        final black = line4[x4];
        if (colorTransform) {
          final luma = line1[x1];
          final cb = line2[x2] - 128;
          final cr = line3[x3] - 128;
          final scaled = luma << 8;
          cyan = 255 - ((scaled + 359 * cr) >> 8).clamp(0, 255).toInt();
          magenta =
              255 - ((scaled - 88 * cb - 183 * cr) >> 8).clamp(0, 255).toInt();
          yellow = 255 - ((scaled + 454 * cb) >> 8).clamp(0, 255).toInt();
        } else {
          cyan = line1[x1];
          magenta = line2[x2];
          yellow = line3[x3];
        }

        componentsBuffer[0] = decode.toByte(cyan, 8, 0);
        componentsBuffer[1] = decode.toByte(magenta, 8, 1);
        componentsBuffer[2] = decode.toByte(yellow, 8, 2);
        componentsBuffer[3] = decode.toByte(black, 8, 3);
        colorSpace.toRgbBytes(componentsBuffer, rgb, iccTransform);
        rgba[dstOffset] = rgb[0];
        rgba[dstOffset + 1] = rgb[1];
        rgba[dstOffset + 2] = rgb[2];
        rgba[dstOffset + 3] = 255;
        dstOffset += 4;
      }
    }
    return _DecodedImage(width, height, rgba, opaque: true);
  } on Exception {
    return null;
  }
}

int _sampleImageBilinear(
  Uint8List rgba,
  int width,
  int height,
  double ux,
  double uy,
) {
  var sx = ux * width - 0.5;
  var sy = (1 - uy) * height - 0.5;
  if (sx < 0) {
    sx = 0;
  } else {
    final maxX = width - 1.0;
    if (sx > maxX) sx = maxX;
  }
  if (sy < 0) {
    sy = 0;
  } else {
    final maxY = height - 1.0;
    if (sy > maxY) sy = maxY;
  }

  final x0 = sx.floor();
  final y0 = sy.floor();
  final x1 = x0 + 1 < width ? x0 + 1 : x0;
  final y1 = y0 + 1 < height ? y0 + 1 : y0;
  final wx = ((sx - x0) * 256).round();
  final wy = ((sy - y0) * 256).round();
  final ix = 256 - wx;
  final iy = 256 - wy;
  final w00 = ix * iy;
  final w10 = wx * iy;
  final w01 = ix * wy;
  final w11 = wx * wy;
  final o00 = (y0 * width + x0) * 4;
  final o10 = (y0 * width + x1) * 4;
  final o01 = (y1 * width + x0) * 4;
  final o11 = (y1 * width + x1) * 4;

  final r =
      (rgba[o00] * w00 +
          rgba[o10] * w10 +
          rgba[o01] * w01 +
          rgba[o11] * w11 +
          32768) >>>
      16;
  final g =
      (rgba[o00 + 1] * w00 +
          rgba[o10 + 1] * w10 +
          rgba[o01 + 1] * w01 +
          rgba[o11 + 1] * w11 +
          32768) >>>
      16;
  final b =
      (rgba[o00 + 2] * w00 +
          rgba[o10 + 2] * w10 +
          rgba[o01 + 2] * w01 +
          rgba[o11 + 2] * w11 +
          32768) >>>
      16;
  final a =
      (rgba[o00 + 3] * w00 +
          rgba[o10 + 3] * w10 +
          rgba[o01 + 3] * w01 +
          rgba[o11 + 3] * w11 +
          32768) >>>
      16;
  return r | (g << 8) | (b << 16) | (a << 24);
}

int _sampleImageBox(
  Uint8List rgba,
  int width,
  int height,
  double ux,
  double uy,
  double footprintX,
  double footprintY,
) {
  final centerX = ux * width - 0.5;
  final centerY = (1 - uy) * height - 0.5;
  final left = (centerX - footprintX * 0.5).clamp(0.0, width - 1.0);
  final right = (centerX + footprintX * 0.5).clamp(0.0, width - 1.0);
  final top = (centerY - footprintY * 0.5).clamp(0.0, height - 1.0);
  final bottom = (centerY + footprintY * 0.5).clamp(0.0, height - 1.0);
  final xStart = left.floor();
  final xEnd = right.ceil().clamp(0, width - 1).toInt();
  final yStart = top.floor();
  final yEnd = bottom.ceil().clamp(0, height - 1).toInt();

  var total = 0.0;
  var r = 0.0;
  var g = 0.0;
  var b = 0.0;
  var a = 0.0;
  for (var y = yStart; y <= yEnd; y++) {
    final wy = math.min(y + 0.5, bottom) - math.max(y - 0.5, top);
    if (wy <= 0) continue;
    for (var x = xStart; x <= xEnd; x++) {
      final wx = math.min(x + 0.5, right) - math.max(x - 0.5, left);
      if (wx <= 0) continue;
      final weight = wx * wy;
      final offset = (y * width + x) * 4;
      r += rgba[offset] * weight;
      g += rgba[offset + 1] * weight;
      b += rgba[offset + 2] * weight;
      a += rgba[offset + 3] * weight;
      total += weight;
    }
  }
  if (total <= 0) return _sampleImageBilinear(rgba, width, height, ux, uy);
  final rr = (r / total).round().clamp(0, 255).toInt();
  final gg = (g / total).round().clamp(0, 255).toInt();
  final bb = (b / total).round().clamp(0, 255).toInt();
  final aa = (a / total).round().clamp(0, 255).toInt();
  return rr | (gg << 8) | (bb << 16) | (aa << 24);
}

_DecodedImage? _decodeStencilImage(
  PdfImageRequest request,
  cos.CosDocument cosDocument,
  int width,
  int height,
) {
  final data = cosDocument.decodeStreamData(request.stream);
  final rgba = Uint8List(width * height * 4);
  final r = (request.stencilColor.red.clamp(0, 1) * 255).round();
  final g = (request.stencilColor.green.clamp(0, 1) * 255).round();
  final b = (request.stencilColor.blue.clamp(0, 1) * 255).round();
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final bitIndex = y * width + x;
      final byteIndex = bitIndex ~/ 8;
      if (byteIndex >= data.length) continue;
      final bit = 7 - (bitIndex % 8);
      final painted = ((data[byteIndex] >> bit) & 1) != 0;
      final offset = bitIndex * 4;
      rgba[offset] = r;
      rgba[offset + 1] = g;
      rgba[offset + 2] = b;
      rgba[offset + 3] = painted ? 255 : 0;
    }
  }
  return _DecodedImage(width, height, rgba, opaque: false);
}

bool _isSupportedImageBits(int bits) =>
    bits == 1 || bits == 2 || bits == 4 || bits == 8;

bool _hasEnoughSamples(Uint8List data, int sampleCount, int bits) =>
    data.length * 8 >= sampleCount * bits;

int _readSample(Uint8List data, int sampleIndex, int bits) {
  if (bits == 8) return data[sampleIndex];
  final bitOffset = sampleIndex * bits;
  final byte = data[bitOffset >> 3];
  final shift = 8 - bits - (bitOffset & 7);
  return (byte >> shift) & ((1 << bits) - 1);
}

void _cmykToRgb(int c, int m, int y, int k, List<int> rgb) {
  pdfiumCmykToRgb(c, m, y, k, rgb);
}

void _applyDecodedRgbImageColorSpace(
  Uint8List rgba,
  cos.CosDocument cosDocument,
  cos.CosDictionary dict,
  _ImageColorSpace colorSpace,
  int bits,
) {
  if (colorSpace.kind == _ImageColorSpaceKind.cmyk ||
      colorSpace.kind == _ImageColorSpaceKind.indexed) {
    return;
  }
  final decode = _ImageDecodeRanges.parse(
    cosDocument,
    dict['Decode'],
    colorSpace,
    bits,
  );
  if (decode.isDefault01 && colorSpace.iccProfile == null) return;

  final components = List<int>.filled(colorSpace.inputComponents, 0);
  final rgb = List<int>.filled(3, 0);
  final iccTransform = _iccTransformFor(colorSpace);
  for (var i = 0; i < rgba.length; i += 4) {
    if (colorSpace.kind == _ImageColorSpaceKind.gray) {
      components[0] = decode.toByte(rgba[i], 8, 0);
    } else {
      components[0] = decode.toByte(rgba[i], 8, 0);
      components[1] = decode.toByte(rgba[i + 1], 8, 1);
      components[2] = decode.toByte(rgba[i + 2], 8, 2);
    }
    colorSpace.toRgbBytes(components, rgb, iccTransform);
    rgba[i] = rgb[0];
    rgba[i + 1] = rgb[1];
    rgba[i + 2] = rgb[2];
  }
}

void _setIndexedColor(
  Uint8List rgba,
  int dstOffset,
  _ImageColorSpace indexed,
  int index,
  List<int> rgb,
) {
  final base = indexed.base;
  final lookup = indexed.lookup;
  if (base == null || lookup == null) return;

  final componentOffset = index * base.inputComponents;
  if (componentOffset + base.inputComponents > lookup.length) return;
  base.toRgbBytes(lookup.sublist(componentOffset), rgb);
  rgba[dstOffset] = rgb[0];
  rgba[dstOffset + 1] = rgb[1];
  rgba[dstOffset + 2] = rgb[2];
}

enum _ImageColorSpaceKind { gray, rgb, cmyk, indexed }

class _ImageColorSpace {
  const _ImageColorSpace._(
    this.kind, {
    this.base,
    this.lookup,
    this.highValue = 0,
    this.iccProfile,
  });

  factory _ImageColorSpace.gray({IccProfile? iccProfile}) =>
      _ImageColorSpace._(_ImageColorSpaceKind.gray, iccProfile: iccProfile);

  factory _ImageColorSpace.rgb({IccProfile? iccProfile}) =>
      _ImageColorSpace._(_ImageColorSpaceKind.rgb, iccProfile: iccProfile);

  factory _ImageColorSpace.cmyk({IccProfile? iccProfile}) =>
      _ImageColorSpace._(_ImageColorSpaceKind.cmyk, iccProfile: iccProfile);

  factory _ImageColorSpace.indexed({
    required _ImageColorSpace base,
    required Uint8List lookup,
    required int highValue,
  }) => _ImageColorSpace._(
    _ImageColorSpaceKind.indexed,
    base: base,
    lookup: lookup,
    highValue: highValue,
  );

  final _ImageColorSpaceKind kind;
  final _ImageColorSpace? base;
  final Uint8List? lookup;
  final int highValue;
  final IccProfile? iccProfile;

  int get inputComponents => switch (kind) {
    _ImageColorSpaceKind.gray => iccProfile?.channels ?? 1,
    _ImageColorSpaceKind.rgb => iccProfile?.channels ?? 3,
    _ImageColorSpaceKind.cmyk => iccProfile?.channels ?? 4,
    _ImageColorSpaceKind.indexed => 1,
  };

  void toRgbBytes(
    List<int> components,
    List<int> rgb, [
    _IccColorTransform? iccTransform,
  ]) {
    final profile = iccProfile;
    if (profile != null && components.length >= profile.channels) {
      (iccTransform ?? _IccColorTransform(profile)).toRgbBytes(components, rgb);
      return;
    }
    switch (kind) {
      case _ImageColorSpaceKind.gray:
        final gray = components.isEmpty ? 0 : components[0];
        rgb[0] = gray;
        rgb[1] = gray;
        rgb[2] = gray;
      case _ImageColorSpaceKind.rgb:
        rgb[0] = components.isEmpty ? 0 : components[0];
        rgb[1] = components.length < 2 ? 0 : components[1];
        rgb[2] = components.length < 3 ? 0 : components[2];
      case _ImageColorSpaceKind.cmyk:
        _cmykToRgb(
          components.isEmpty ? 0 : components[0],
          components.length < 2 ? 0 : components[1],
          components.length < 3 ? 0 : components[2],
          components.length < 4 ? 0 : components[3],
          rgb,
        );
      case _ImageColorSpaceKind.indexed:
        break;
    }
  }

  static _ImageColorSpace? parse(
    cos.CosDocument cosDocument,
    cos.CosObject? object, {
    _ImageColorContext? context,
    bool useDeviceDefaults = true,
    Set<String>? resolvingNames,
  }) {
    final resolved = cosDocument.resolve(object);
    if (resolved is cos.CosName) {
      return switch (resolved.value) {
        'DeviceGray' || 'G' =>
          useDeviceDefaults
              ? context?.defaultGray ?? _ImageColorSpace.gray()
              : _ImageColorSpace.gray(),
        'DeviceRGB' || 'RGB' =>
          useDeviceDefaults
              ? context?.defaultRgb ?? _ImageColorSpace.rgb()
              : _ImageColorSpace.rgb(),
        'DeviceCMYK' || 'CMYK' =>
          useDeviceDefaults
              ? context?.defaultCmyk ?? _ImageColorSpace.cmyk()
              : _ImageColorSpace.cmyk(),
        _ => context?.resolveNamed(
          cosDocument,
          resolved.value,
          useDeviceDefaults: useDeviceDefaults,
          resolvingNames: resolvingNames,
        ),
      };
    }
    if (resolved is! cos.CosArray || resolved.length == 0) return null;

    final family = _nameValue(cosDocument.resolve(resolved[0]));
    if ((family == 'Indexed' || family == 'I') && resolved.length >= 4) {
      final base = parse(
        cosDocument,
        resolved[1],
        context: context,
        useDeviceDefaults: useDeviceDefaults,
        resolvingNames: resolvingNames,
      );
      if (base == null || base.kind == _ImageColorSpaceKind.indexed) {
        return null;
      }
      final highValue = _intValue(cosDocument.resolve(resolved[2]));
      final lookup = _lookupBytes(cosDocument, resolved[3]);
      if (highValue < 0 || lookup == null) return null;
      return _ImageColorSpace.indexed(
        base: base,
        lookup: lookup,
        highValue: highValue,
      );
    }
    if (family == 'ICCBased' && resolved.length >= 2) {
      final profile = cosDocument.resolve(resolved[1]);
      if (profile is! cos.CosStream) return null;
      final n = _intValue(cosDocument.resolve(profile.dictionary['N']));
      final iccProfile = _parseIccProfile(cosDocument, profile);
      if (iccProfile != null && iccProfile.channels == n) {
        return _iccColorSpace(n, iccProfile);
      }
      final alternate = parse(
        cosDocument,
        profile.dictionary['Alternate'],
        context: context,
        useDeviceDefaults: false,
        resolvingNames: resolvingNames,
      );
      return alternate ?? _deviceColorSpaceForComponents(n);
    }
    return null;
  }
}

int _unitToByte(double value) => (value.clamp(0, 1) * 255).round();

_ImageColorSpace? _iccColorSpace(int components, IccProfile profile) =>
    switch (components) {
      1 => _ImageColorSpace.gray(iccProfile: profile),
      3 => _ImageColorSpace.rgb(iccProfile: profile),
      4 => _ImageColorSpace.cmyk(iccProfile: profile),
      _ => null,
    };

_ImageColorSpace? _deviceColorSpaceForComponents(int components) =>
    switch (components) {
      1 => _ImageColorSpace.gray(),
      3 => _ImageColorSpace.rgb(),
      4 => _ImageColorSpace.cmyk(),
      _ => null,
    };

IccProfile? _parseIccProfile(
  cos.CosDocument cosDocument,
  cos.CosStream profile,
) {
  final cached = _iccProfileCache[profile];
  if (cached != null) return cached.profile;
  try {
    final bytes = cosDocument.decodeStreamData(profile);
    if (_isLikelySrgbIccProfile(bytes)) {
      _iccProfileCache[profile] = const _CachedIccProfile(null);
      return null;
    }
    final parsed = IccProfile.parse(bytes);
    _iccProfileCache[profile] = _CachedIccProfile(parsed);
    return parsed;
  } on Exception {
    _iccProfileCache[profile] = const _CachedIccProfile(null);
    return null;
  }
}

bool _isLikelySrgbIccProfile(Uint8List bytes) {
  if (bytes.length < 128) return false;
  if (String.fromCharCodes(bytes, 16, 20) != 'RGB ') return false;
  return _containsAsciiIgnoreCase(bytes, 'sRGB') ||
      (_containsAsciiIgnoreCase(bytes, 'IEC') &&
          _containsAsciiIgnoreCase(bytes, '61966'));
}

bool _containsAsciiIgnoreCase(Uint8List bytes, String needle) {
  if (needle.isEmpty || bytes.length < needle.length) return false;
  final lowerNeedle = [
    for (var i = 0; i < needle.length; i++) _asciiLower(needle.codeUnitAt(i)),
  ];
  final lastStart = bytes.length - lowerNeedle.length;
  for (var start = 0; start <= lastStart; start++) {
    var matches = true;
    for (var i = 0; i < lowerNeedle.length; i++) {
      if (_asciiLower(bytes[start + i]) != lowerNeedle[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

int _asciiLower(int value) =>
    value >= 0x41 && value <= 0x5a ? value + 0x20 : value;

_IccColorTransform? _iccTransformFor(_ImageColorSpace colorSpace) {
  final profile = colorSpace.iccProfile;
  return profile == null ? null : _IccColorTransform(profile);
}

final _iccProfileCache = Expando<_CachedIccProfile>('dart_pdf_renderer.icc');

class _CachedIccProfile {
  const _CachedIccProfile(this.profile);

  final IccProfile? profile;
}

const _maxIccTransformCacheEntries = 1 << 20;

class _IccColorTransform {
  _IccColorTransform(this.profile)
    : values = List<double>.filled(profile.channels, 0, growable: false);

  final IccProfile profile;
  final List<double> values;
  final _cache = <int, int>{};

  void toRgbBytes(List<int> components, List<int> rgb) {
    final key = _componentKey(components, profile.channels);
    final cached = _cache[key];
    if (cached != null) {
      _unpackRgb(cached, rgb);
      return;
    }

    for (var i = 0; i < profile.channels; i++) {
      values[i] = components[i] / 255;
    }
    final color = profile.toSrgb(values);
    final packed = _packRgb(
      _unitToByte(color.red),
      _unitToByte(color.green),
      _unitToByte(color.blue),
    );
    if (_cache.length < _maxIccTransformCacheEntries) {
      _cache[key] = packed;
    }
    _unpackRgb(packed, rgb);
  }
}

int _componentKey(List<int> components, int channels) => switch (channels) {
  1 => components[0],
  3 => components[0] | (components[1] << 8) | (components[2] << 16),
  4 =>
    components[0] |
        (components[1] << 8) |
        (components[2] << 16) |
        (components[3] << 24),
  _ => Object.hashAll(components.take(channels)),
};

int _packRgb(int red, int green, int blue) => red | (green << 8) | (blue << 16);

void _unpackRgb(int packed, List<int> rgb) {
  rgb[0] = packed & 0xff;
  rgb[1] = (packed >> 8) & 0xff;
  rgb[2] = (packed >> 16) & 0xff;
}

Uint8List? _lookupBytes(cos.CosDocument cosDocument, cos.CosObject object) {
  final resolved = cosDocument.resolve(object);
  if (resolved is cos.CosString) return resolved.bytes;
  if (resolved is cos.CosStream) return cosDocument.decodeStreamData(resolved);
  return null;
}

class _ImageDecodeRanges {
  const _ImageDecodeRanges(this.pairs);

  factory _ImageDecodeRanges.parse(
    cos.CosDocument cosDocument,
    cos.CosObject? object,
    _ImageColorSpace colorSpace,
    int bits,
  ) {
    final components = colorSpace.inputComponents;
    final resolved = cosDocument.resolve(object);
    if (resolved is cos.CosArray && resolved.length >= components * 2) {
      return _ImageDecodeRanges([
        for (var i = 0; i < components; i++)
          _DecodePair(
            _numberValue(cosDocument.resolve(resolved[i * 2])),
            _numberValue(cosDocument.resolve(resolved[i * 2 + 1])),
          ),
      ]);
    }
    final max = colorSpace.kind == _ImageColorSpaceKind.indexed
        ? ((1 << bits) - 1).toDouble()
        : 1.0;
    return _ImageDecodeRanges([
      for (var i = 0; i < components; i++) _DecodePair(0, max),
    ]);
  }

  final List<_DecodePair> pairs;

  bool get isDefault01 {
    for (final pair in pairs) {
      if (pair.min != 0 || pair.max != 1) return false;
    }
    return true;
  }

  int toByte(int sample, int bits, int component) {
    final pair = pairs[component];
    final decoded = pair.decode(sample, bits).clamp(0.0, 1.0);
    return (decoded * 255).round().clamp(0, 255).toInt();
  }

  int toIndex(int sample, int bits, int highValue) {
    final decoded = pairs[0].decode(sample, bits);
    return decoded.round().clamp(0, highValue).toInt();
  }
}

class _DecodePair {
  const _DecodePair(this.min, this.max);

  final double min;
  final double max;

  double decode(int sample, int bits) {
    final maxSample = (1 << bits) - 1;
    if (maxSample <= 0) return min;
    return min + sample * (max - min) / maxSample;
  }
}

class _RgbaSurface {
  _RgbaSurface(this.width, this.height)
    : pixels = Uint8List(width * height * 4);

  final int width;
  final int height;
  final Uint8List pixels;
  _IntRect? _dirtyBounds;

  _IntRect? get dirtyBounds => _dirtyBounds;

  void clear(int r, int g, int b, int a) {
    _dirtyBounds = null;
    if (Endian.host == Endian.little) {
      pixels.buffer.asUint32List().fillRange(
        0,
        width * height,
        (a << 24) | (b << 16) | (g << 8) | r,
      );
      return;
    }
    for (var i = 0; i < pixels.length; i += 4) {
      pixels[i] = r;
      pixels[i + 1] = g;
      pixels[i + 2] = b;
      pixels[i + 3] = a;
    }
  }

  void blendPixel(int x, int y, int r, int g, int b, int a) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    if (a <= 0) return;
    markDirty(_IntRect(x, y, x + 1, y + 1));
    final offset = (y * width + x) * 4;
    if (a >= 255) {
      pixels[offset] = r;
      pixels[offset + 1] = g;
      pixels[offset + 2] = b;
      pixels[offset + 3] = 255;
      return;
    }
    final inv = 255 - a;
    pixels[offset] = (r * a + pixels[offset] * inv) ~/ 255;
    pixels[offset + 1] = (g * a + pixels[offset + 1] * inv) ~/ 255;
    pixels[offset + 2] = (b * a + pixels[offset + 2] * inv) ~/ 255;
    if (a > pixels[offset + 3]) pixels[offset + 3] = a;
  }

  void markDirty(_IntRect bounds) {
    if (bounds.isEmpty) return;
    final clipped = bounds.intersect(_IntRect(0, 0, width, height));
    if (clipped.isEmpty) return;
    final current = _dirtyBounds;
    _dirtyBounds = current == null ? clipped : current.union(clipped);
  }
}

class _Point {
  const _Point(this.x, this.y);

  final double x;
  final double y;

  double distanceTo(_Point other) {
    final dx = other.x - x;
    final dy = other.y - y;
    return math.sqrt(dx * dx + dy * dy);
  }
}

class _DecodedImage {
  const _DecodedImage(
    this.width,
    this.height,
    this.rgba, {
    required this.opaque,
  });

  final int width;
  final int height;
  final Uint8List rgba;
  final bool opaque;

  int get byteLength => rgba.lengthInBytes;
}

class _ScanlineIntersection {
  const _ScanlineIntersection(this.x, this.windingDelta);

  final double x;
  final int windingDelta;
}

class _IntRect {
  const _IntRect(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  bool get isEmpty => left >= right || top >= bottom;
  int get width => right - left;
  int get height => bottom - top;

  _IntRect intersect(_IntRect other) => _IntRect(
    math.max(left, other.left),
    math.max(top, other.top),
    math.min(right, other.right),
    math.min(bottom, other.bottom),
  );

  _IntRect union(_IntRect other) => _IntRect(
    math.min(left, other.left),
    math.min(top, other.top),
    math.max(right, other.right),
    math.max(bottom, other.bottom),
  );

  PdfRenderTraceRegion toTraceRegion() => PdfRenderTraceRegion(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );

  @override
  String toString() => '$left,$top,$right,$bottom';
}

class _FillCoverageMask {
  _FillCoverageMask(_IntRect bounds)
    : originX = bounds.left - 1,
      originY = bounds.top - 1,
      width = bounds.width + 2,
      _values = Uint8List((bounds.width + 2) * (bounds.height + 2)),
      _boundary = Uint8List((bounds.width + 2) * (bounds.height + 2));

  final int originX;
  final int originY;
  final int width;
  final Uint8List _values;
  final Uint8List _boundary;

  void set(int x, int y, bool covered) {
    _values[_offset(x, y)] = covered ? 1 : 0;
  }

  bool contains(int x, int y) => _values[_offset(x, y)] != 0;

  void markBoundary(int x, int y) {
    _boundary[_offset(x, y)] = 1;
  }

  void markBoundaryTransitions(_IntRect bounds) {
    for (var y = bounds.top; y < bounds.bottom; y++) {
      for (var x = bounds.left; x < bounds.right; x++) {
        final offset = _offset(x, y);
        final center = _values[offset];
        var boundary = false;
        for (var dy = -1; dy <= 1 && !boundary; dy++) {
          final row = offset + dy * width;
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            if (_values[row + dx] != center) {
              boundary = true;
              break;
            }
          }
        }
        if (boundary) _boundary[offset] = 1;
      }
    }
  }

  bool isBoundary(int x, int y) => _boundary[_offset(x, y)] != 0;

  int _offset(int x, int y) {
    final localX = x - originX;
    final localY = y - originY;
    return localY * width + localX;
  }
}

class _ClipState {
  const _ClipState(this.bounds, {this.paths = const []});

  final _IntRect bounds;
  final List<_ClipPath> paths;

  bool contains(double x, double y) {
    if (x < bounds.left ||
        x >= bounds.right ||
        y < bounds.top ||
        y >= bounds.bottom) {
      return false;
    }
    for (final path in paths) {
      final inside = path.rule == PdfFillRule.evenOdd
          ? _containsEvenOdd(path.contours, x, y)
          : _containsNonZero(path.contours, x, y);
      if (!inside) return false;
    }
    return true;
  }

  _ClipState intersect(
    _IntRect bounds, {
    required List<List<_Point>> contours,
    required PdfFillRule rule,
  }) => _ClipState(
    this.bounds.intersect(bounds),
    paths: [...paths, _ClipPath(contours, rule)],
  );

  _ClipState intersectBounds(_IntRect bounds) =>
      _ClipState(this.bounds.intersect(bounds), paths: paths);
}

class _ClipPath {
  const _ClipPath(this.contours, this.rule);

  final List<List<_Point>> contours;
  final PdfFillRule rule;
}

_Point _cubic(_Point p0, _Point p1, _Point p2, _Point p3, double t) {
  final mt = 1 - t;
  final a = mt * mt * mt;
  final b = 3 * mt * mt * t;
  final c = 3 * mt * t * t;
  final d = t * t * t;
  return _Point(
    a * p0.x + b * p1.x + c * p2.x + d * p3.x,
    a * p0.y + b * p1.y + c * p2.y + d * p3.y,
  );
}

int _cubicFlattenSegmentCount(_Point p0, _Point p1, _Point p2, _Point p3) {
  final left = math.min(math.min(p0.x, p1.x), math.min(p2.x, p3.x));
  final top = math.min(math.min(p0.y, p1.y), math.min(p2.y, p3.y));
  final right = math.max(math.max(p0.x, p1.x), math.max(p2.x, p3.x));
  final bottom = math.max(math.max(p0.y, p1.y), math.max(p2.y, p3.y));
  final extent = math.max(right - left, bottom - top);
  if (extent >= 96) return _maxCubicFlattenSegments;
  if (extent >= 48) return _midCubicFlattenSegments;
  return _minCubicFlattenSegments;
}

List<List<_Point>> _flattenPath(PdfPath path, {required PdfMatrix transform}) {
  final contours = <List<_Point>>[];
  List<_Point>? current;
  _Point? start;
  _Point? cursor;

  _Point tx(double x, double y) =>
      _Point(transform.transformX(x, y), transform.transformY(x, y));

  for (final segment in path.segments) {
    switch (segment) {
      case PdfMoveTo(:final x, :final y):
        current = <_Point>[];
        contours.add(current);
        start = cursor = tx(x, y);
        current.add(cursor);
      case PdfLineTo(:final x, :final y):
        current ??= <_Point>[];
        if (!contours.contains(current)) contours.add(current);
        cursor = tx(x, y);
        current.add(cursor);
      case PdfCubicTo():
        if (cursor == null) break;
        current ??= <_Point>[];
        if (!contours.contains(current)) contours.add(current);
        final p0 = cursor;
        final p1 = tx(segment.x1, segment.y1);
        final p2 = tx(segment.x2, segment.y2);
        final p3 = tx(segment.x3, segment.y3);
        final segments = _cubicFlattenSegmentCount(p0, p1, p2, p3);
        for (var i = 1; i <= segments; i++) {
          current.add(_cubic(p0, p1, p2, p3, i / segments));
        }
        cursor = p3;
      case PdfClosePath():
        if (current != null && start != null) current.add(start);
        cursor = start;
    }
  }
  return [
    for (final contour in contours)
      if (contour.length >= 2) contour,
  ];
}

bool _containsEvenOdd(List<List<_Point>> contours, double x, double y) {
  var inside = false;
  for (final contour in contours) {
    for (var i = 0, j = contour.length - 1; i < contour.length; j = i++) {
      final pi = contour[i];
      final pj = contour[j];
      if (((pi.y > y) != (pj.y > y)) &&
          x < (pj.x - pi.x) * (y - pi.y) / (pj.y - pi.y) + pi.x) {
        inside = !inside;
      }
    }
  }
  return inside;
}

bool _containsNonZero(List<List<_Point>> contours, double x, double y) {
  var winding = 0;
  for (final contour in contours) {
    for (var i = 0, j = contour.length - 1; i < contour.length; j = i++) {
      final p1 = contour[j];
      final p2 = contour[i];
      if (p1.y <= y) {
        if (p2.y > y && _isLeft(p1, p2, x, y) > 0) winding++;
      } else if (p2.y <= y && _isLeft(p1, p2, x, y) < 0) {
        winding--;
      }
    }
  }
  return winding != 0;
}

bool _isAxisAlignedRectangle(List<List<_Point>> contours) {
  if (contours.length != 1) return false;
  final contour = contours.first;
  if (contour.length != 5) return false;
  if (contour.first.distanceTo(contour.last) > 1e-6) return false;

  var left = double.infinity;
  var top = double.infinity;
  var right = double.negativeInfinity;
  var bottom = double.negativeInfinity;
  for (var i = 0; i < 4; i++) {
    final point = contour[i];
    left = math.min(left, point.x);
    top = math.min(top, point.y);
    right = math.max(right, point.x);
    bottom = math.max(bottom, point.y);
  }
  if ((right - left).abs() < 1e-6 || (bottom - top).abs() < 1e-6) {
    return false;
  }

  var corners = 0;
  for (var i = 0; i < 4; i++) {
    final point = contour[i];
    final onLeft = (point.x - left).abs() < 1e-6;
    final onRight = (point.x - right).abs() < 1e-6;
    final onTop = (point.y - top).abs() < 1e-6;
    final onBottom = (point.y - bottom).abs() < 1e-6;
    if (!(onLeft || onRight) || !(onTop || onBottom)) return false;
    final bit = (onRight ? 1 : 0) | (onBottom ? 2 : 0);
    corners |= 1 << bit;
  }
  return corners == 0x0f;
}

bool _isPixelAlignedRectangle(List<List<_Point>> contours, _IntRect bounds) {
  if (!_isAxisAlignedRectangle(contours)) return false;
  for (var i = 0; i < 4; i++) {
    final point = contours.first[i];
    if ((point.x - point.x.round()).abs() > 1e-6) return false;
    if ((point.y - point.y.round()).abs() > 1e-6) return false;
  }
  return bounds.left >= 0 &&
      bounds.top >= 0 &&
      bounds.right > bounds.left &&
      bounds.bottom > bounds.top;
}

double _isLeft(_Point p1, _Point p2, double x, double y) =>
    (p2.x - p1.x) * (y - p1.y) - (x - p1.x) * (p2.y - p1.y);

double _strokeCoverageAtPoint(
  double x,
  double y,
  _Point p1,
  double dx,
  double dy,
  double lengthSquared,
  double radius,
) {
  final t = (((x - p1.x) * dx + (y - p1.y) * dy) / lengthSquared).clamp(
    0.0,
    1.0,
  );
  final nearestX = p1.x + dx * t;
  final nearestY = p1.y + dy * t;
  final distanceX = x - nearestX;
  final distanceY = y - nearestY;
  final distance = math.sqrt(distanceX * distanceX + distanceY * distanceY);
  return (radius + 0.5 - distance).clamp(0.0, 1.0).toDouble();
}

int _intValue(cos.CosObject? object) => switch (object) {
  cos.CosInteger(:final value) => value,
  cos.CosReal(:final value) => value.round(),
  _ => 0,
};

double _numberValue(cos.CosObject? object) => switch (object) {
  cos.CosInteger(:final value) => value.toDouble(),
  cos.CosReal(:final value) => value,
  _ => 0,
};

String? _nameValue(cos.CosObject? object) => switch (object) {
  cos.CosName(:final value) => value,
  _ => null,
};

List<String> _filterNames(cos.CosDocument cosDocument, cos.CosDictionary dict) {
  final filter = cosDocument.resolve(dict['Filter']);
  if (filter is cos.CosName) return [filter.value];
  if (filter is cos.CosArray) {
    return [
      for (final item in filter.items)
        if (cosDocument.resolve(item) case cos.CosName(:final value)) value,
    ];
  }
  return const [];
}
