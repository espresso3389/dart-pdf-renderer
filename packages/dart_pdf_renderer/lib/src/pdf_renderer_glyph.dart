part of 'pdf_renderer.dart';

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
    final contours = _flattenPath(
      outline,
      transform: placement.transform,
      closeOpenContours: true,
    );
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
