// ignore_for_file: unused_import, implementation_imports

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:image/src/formats/jpeg/jpeg_data.dart' as image_internal;
import 'package:pdf_cos/pdf_cos.dart' as cos;
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart' as graphics;
import 'pdf_display_command.dart';
import 'pdfium_cmyk.dart';
import 'pdf_renderer.dart';
import 'pdf_renderer_direct_device.dart';
import 'pdf_renderer_display_list.dart';
import 'pdf_renderer_geometry.dart';
import 'pdf_renderer_graphics.dart';
import 'pdf_renderer_image.dart';
import 'pdf_renderer_models.dart';
import 'pdf_renderer_recording_device.dart';

class PdfGlyphRasterCache {
  /// Creates a glyph raster cache.
  PdfGlyphRasterCache({
    this.maxEntries = defaultMaxGlyphRasterCacheEntries,
    this.maxGlyphPixels = defaultMaxGlyphRasterPixels,
  });

  /// The maximum number of glyph masks retained.
  final int maxEntries;

  /// The maximum pixel area allowed for a single glyph mask.
  final int maxGlyphPixels;
  final entries = <GlyphRasterKey, GlyphRasterMask>{};
  final outlineKeys = Expando<GlyphOutlineKey>();

  /// The current number of cached glyph masks.
  int get entryCount => entries.length;

  /// Removes all cached glyph masks.
  void clear() {
    entries.clear();
  }

  bool paintGlyph({
    required RgbaSurface surface,
    required ClipState clip,
    required graphics.PdfPath outline,
    required graphics.PdfMatrix transform,
    required graphics.PdfColor color,
    required double alpha,
    PdfRenderTiming? timing,
  }) {
    timing?.glyphRequests++;
    final placement = GlyphRasterPlacement.from(transform);
    final key = GlyphRasterKey.from(
      outlineKeys[outline] ??= GlyphOutlineKey.from(outline),
      placement,
    );
    final cached = entries.remove(key);
    final GlyphRasterMask? mask;
    if (cached != null) {
      timing?.glyphCacheHits++;
      mask = cached;
    } else {
      final stopwatch = timing == null ? null : (Stopwatch()..start());
      mask = createMask(outline, placement);
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
    entries[key] = mask;
    if (entries.length > maxEntries) {
      entries.remove(entries.keys.first);
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

  GlyphRasterMask? createMask(
    graphics.PdfPath outline,
    GlyphRasterPlacement placement,
  ) {
    final contours = flattenPath(
      outline,
      transform: placement.transform,
      closeOpenContours: true,
    );
    final bounds = rawBoundsOf(contours);
    if (bounds == null || bounds.isEmpty) {
      return const GlyphRasterMask.empty();
    }
    if (bounds.width * bounds.height > maxGlyphPixels) return null;

    final coverage = buildPathCoverageAlpha(
      bounds,
      contours,
      graphics.PdfFillRule.nonzero,
    );
    return GlyphRasterMask(
      bounds.left,
      bounds.top,
      bounds.width,
      bounds.height,
      coverage,
    );
  }
}

class GlyphRasterPlacement {
  const GlyphRasterPlacement(
    this.baseX,
    this.baseY,
    this.qa,
    this.qb,
    this.qc,
    this.qd,
    this.qfx,
    this.qfy,
  );

  factory GlyphRasterPlacement.from(graphics.PdfMatrix transform) {
    final fx = quantizeFraction(transform.e);
    final fy = quantizeFraction(transform.f);
    return GlyphRasterPlacement(
      fx.base,
      fy.base,
      quantizeTransform(transform.a),
      quantizeTransform(transform.b),
      quantizeTransform(transform.c),
      quantizeTransform(transform.d),
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

  graphics.PdfMatrix get transform => graphics.PdfMatrix(
    qa / glyphTransformQuantization,
    qb / glyphTransformQuantization,
    qc / glyphTransformQuantization,
    qd / glyphTransformQuantization,
    qfx / glyphSubpixelQuantization,
    qfy / glyphSubpixelQuantization,
  );
}

class GlyphRasterKey {
  const GlyphRasterKey(
    this.outlineKey,
    this.qa,
    this.qb,
    this.qc,
    this.qd,
    this.qfx,
    this.qfy,
  );

  factory GlyphRasterKey.from(
    GlyphOutlineKey outlineKey,
    GlyphRasterPlacement placement,
  ) => GlyphRasterKey(
    outlineKey,
    placement.qa,
    placement.qb,
    placement.qc,
    placement.qd,
    placement.qfx,
    placement.qfy,
  );

  final GlyphOutlineKey outlineKey;
  final int qa;
  final int qb;
  final int qc;
  final int qd;
  final int qfx;
  final int qfy;

  @override
  bool operator ==(Object other) =>
      other is GlyphRasterKey &&
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

class GlyphOutlineKey {
  const GlyphOutlineKey(this.segments, this.hashCode);

  factory GlyphOutlineKey.from(graphics.PdfPath outline) {
    var hash = 0x345678;
    for (final segment in outline.segments) {
      switch (segment) {
        case graphics.PdfMoveTo(:final x, :final y):
          hash = combineHash(hash, 1);
          hash = combineHash(hash, x.hashCode);
          hash = combineHash(hash, y.hashCode);
        case graphics.PdfLineTo(:final x, :final y):
          hash = combineHash(hash, 2);
          hash = combineHash(hash, x.hashCode);
          hash = combineHash(hash, y.hashCode);
        case graphics.PdfCubicTo():
          hash = combineHash(hash, 3);
          hash = combineHash(hash, segment.x1.hashCode);
          hash = combineHash(hash, segment.y1.hashCode);
          hash = combineHash(hash, segment.x2.hashCode);
          hash = combineHash(hash, segment.y2.hashCode);
          hash = combineHash(hash, segment.x3.hashCode);
          hash = combineHash(hash, segment.y3.hashCode);
        case graphics.PdfClosePath():
          hash = combineHash(hash, 4);
      }
    }
    return GlyphOutlineKey(outline.segments, hash);
  }

  final List<graphics.PdfPathSegment> segments;

  @override
  final int hashCode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! GlyphOutlineKey) return false;
    if (hashCode != other.hashCode) return false;
    if (identical(segments, other.segments)) return true;
    if (segments.length != other.segments.length) return false;
    for (var i = 0; i < segments.length; i++) {
      if (!samePathSegment(segments[i], other.segments[i])) return false;
    }
    return true;
  }
}

int combineHash(int hash, int value) =>
    0x1fffffff & (hash + value + ((hash & 0x0007ffff) << 10));

bool samePathSegment(graphics.PdfPathSegment a, graphics.PdfPathSegment b) {
  switch (a) {
    case graphics.PdfMoveTo(:final x, :final y):
      return b is graphics.PdfMoveTo && x == b.x && y == b.y;
    case graphics.PdfLineTo(:final x, :final y):
      return b is graphics.PdfLineTo && x == b.x && y == b.y;
    case graphics.PdfCubicTo():
      return b is graphics.PdfCubicTo &&
          a.x1 == b.x1 &&
          a.y1 == b.y1 &&
          a.x2 == b.x2 &&
          a.y2 == b.y2 &&
          a.x3 == b.x3 &&
          a.y3 == b.y3;
    case graphics.PdfClosePath():
      return b is graphics.PdfClosePath;
  }
}

class GlyphRasterMask {
  const GlyphRasterMask(
    this.originX,
    this.originY,
    this.width,
    this.height,
    this.coverage,
  );

  const GlyphRasterMask.empty()
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
    required RgbaSurface surface,
    required ClipState clip,
    required int baseX,
    required int baseY,
    required graphics.PdfColor color,
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

Uint8List buildPathCoverageAlpha(
  IntRect bounds,
  List<List<Point>> contours,
  graphics.PdfFillRule rule,
) {
  final coverage = Uint8List(bounds.width * bounds.height);
  final events = <ScanlineIntersection>[];
  for (var py = bounds.top; py < bounds.bottom; py++) {
    for (var sy = 0; sy < antiAliasSamplesPerAxis; sy++) {
      final y = py + (sy + 0.5) / antiAliasSamplesPerAxis;
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
          events.add(ScanlineIntersection(x, p2.y > p1.y ? 1 : -1));
        }
      }
      if (events.isEmpty) continue;
      events.sort((a, b) => a.x.compareTo(b.x));

      if (rule == graphics.PdfFillRule.evenOdd) {
        var inside = false;
        var spanStart = 0.0;
        for (final event in events) {
          if (inside) {
            addCoverageSpanSamples(coverage, bounds, py, spanStart, event.x);
          }
          inside = !inside;
          spanStart = event.x;
        }
      } else {
        var winding = 0;
        var spanStart = 0.0;
        for (final event in events) {
          if (winding != 0) {
            addCoverageSpanSamples(coverage, bounds, py, spanStart, event.x);
          }
          winding += event.windingDelta;
          spanStart = event.x;
        }
      }
    }
  }
  for (var i = 0; i < coverage.length; i++) {
    coverage[i] = coverageAlphaForSampleCount(coverage[i]);
  }
  return coverage;
}

int coverageAlphaForSampleCount(int coveredSamples) {
  if (coveredSamples <= 0) return 0;
  if (coveredSamples >= antiAliasSampleCount) return 255;
  return (coveredSamples * 255 / antiAliasSampleCount).round();
}

void addCoverageSpanSamples(
  Uint8List coverage,
  IntRect bounds,
  int py,
  double x1,
  double x2,
) {
  if (x2 <= x1) return;
  final rowOffset = (py - bounds.top) * bounds.width - bounds.left;
  for (var sx = 0; sx < antiAliasSamplesPerAxis; sx++) {
    final offset = (sx + 0.5) / antiAliasSamplesPerAxis;
    final start = math.max(bounds.left, (x1 - offset).ceil());
    final end = math.min(bounds.right, (x2 - offset).ceil());
    for (var px = start; px < end; px++) {
      coverage[rowOffset + px]++;
    }
  }
}

({int base, int fraction}) quantizeFraction(double value) {
  var base = value.floor();
  var fraction = ((value - base) * glyphSubpixelQuantization).round();
  if (fraction >= glyphSubpixelQuantization) {
    base++;
    fraction = 0;
  }
  return (base: base, fraction: fraction);
}

int quantizeTransform(double value) =>
    (value * glyphTransformQuantization).round();

graphics.PdfPath transformPath(
  graphics.PdfPath path,
  graphics.PdfMatrix transform,
) => graphics.PdfPath([
  for (final segment in path.segments)
    switch (segment) {
      graphics.PdfMoveTo(:final x, :final y) => graphics.PdfMoveTo(
        transform.transformX(x, y),
        transform.transformY(x, y),
      ),
      graphics.PdfLineTo(:final x, :final y) => graphics.PdfLineTo(
        transform.transformX(x, y),
        transform.transformY(x, y),
      ),
      graphics.PdfCubicTo() => graphics.PdfCubicTo(
        transform.transformX(segment.x1, segment.y1),
        transform.transformY(segment.x1, segment.y1),
        transform.transformX(segment.x2, segment.y2),
        transform.transformY(segment.x2, segment.y2),
        transform.transformX(segment.x3, segment.y3),
        transform.transformY(segment.x3, segment.y3),
      ),
      graphics.PdfClosePath() => const graphics.PdfClosePath(),
    },
]);

graphics.PdfTextRun transformTextRun(
  graphics.PdfTextRun run,
  graphics.PdfMatrix transform,
) => graphics.PdfTextRun(
  text: run.text,
  transform: run.transform.concat(transform),
  color: run.color,
  width: run.width,
  fontName: run.fontName,
  fontSize: run.fontSize,
  glyphs: run.glyphs,
  invisible: run.invisible,
);
