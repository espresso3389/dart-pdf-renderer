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
import 'pdf_renderer_glyph.dart';
import 'pdf_renderer_graphics.dart';
import 'pdf_renderer_image.dart';
import 'pdf_renderer_models.dart';
import 'pdf_renderer_recording_device.dart';

class RgbaSurface {
  RgbaSurface(this.width, this.height) : pixels = Uint8List(width * height * 4);

  final int width;
  final int height;
  final Uint8List pixels;
  IntRect? dirtyBoundsValue;

  IntRect? get dirtyBounds => dirtyBoundsValue;

  void clear(int r, int g, int b, int a) {
    dirtyBoundsValue = null;
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
    markDirty(IntRect(x, y, x + 1, y + 1));
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

  void markDirty(IntRect bounds) {
    if (bounds.isEmpty) return;
    final clipped = bounds.intersect(IntRect(0, 0, width, height));
    if (clipped.isEmpty) return;
    final current = dirtyBoundsValue;
    dirtyBoundsValue = current == null ? clipped : current.union(clipped);
  }
}

class Point {
  const Point(this.x, this.y);

  final double x;
  final double y;

  double distanceTo(Point other) {
    final dx = other.x - x;
    final dy = other.y - y;
    return math.sqrt(dx * dx + dy * dy);
  }
}

class DecodedImage {
  const DecodedImage(
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

class ScanlineIntersection {
  const ScanlineIntersection(this.x, this.windingDelta);

  final double x;
  final int windingDelta;
}

class IntRect {
  const IntRect(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  bool get isEmpty => left >= right || top >= bottom;
  int get width => right - left;
  int get height => bottom - top;

  IntRect intersect(IntRect other) => IntRect(
    math.max(left, other.left),
    math.max(top, other.top),
    math.min(right, other.right),
    math.min(bottom, other.bottom),
  );

  IntRect union(IntRect other) => IntRect(
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

class FillCoverageMask {
  FillCoverageMask(IntRect bounds)
    : originX = bounds.left - 1,
      originY = bounds.top - 1,
      width = bounds.width + 2,
      values = Uint8List((bounds.width + 2) * (bounds.height + 2)),
      boundary = Uint8List((bounds.width + 2) * (bounds.height + 2));

  final int originX;
  final int originY;
  final int width;
  final Uint8List values;
  final Uint8List boundary;

  void set(int x, int y, bool covered) {
    values[offsetOf(x, y)] = covered ? 1 : 0;
  }

  bool contains(int x, int y) => values[offsetOf(x, y)] != 0;

  void markBoundary(int x, int y) {
    boundary[offsetOf(x, y)] = 1;
  }

  void markBoundaryTransitions(IntRect bounds) {
    for (var y = bounds.top; y < bounds.bottom; y++) {
      for (var x = bounds.left; x < bounds.right; x++) {
        final offset = offsetOf(x, y);
        final center = values[offset];
        var isBoundary = false;
        for (var dy = -1; dy <= 1 && !isBoundary; dy++) {
          final row = offset + dy * width;
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            if (values[row + dx] != center) {
              isBoundary = true;
              break;
            }
          }
        }
        if (isBoundary) boundary[offset] = 1;
      }
    }
  }

  bool isBoundary(int x, int y) => boundary[offsetOf(x, y)] != 0;

  int offsetOf(int x, int y) {
    final localX = x - originX;
    final localY = y - originY;
    return localY * width + localX;
  }
}

class ClipState {
  const ClipState(this.bounds, {this.paths = const []});

  final IntRect bounds;
  final List<ClipPath> paths;

  bool contains(double x, double y) {
    if (x < bounds.left ||
        x >= bounds.right ||
        y < bounds.top ||
        y >= bounds.bottom) {
      return false;
    }
    for (final path in paths) {
      final inside = path.rule == graphics.PdfFillRule.evenOdd
          ? containsEvenOdd(path.contours, x, y)
          : containsNonZero(path.contours, x, y);
      if (!inside) return false;
    }
    return true;
  }

  ClipState intersect(
    IntRect bounds, {
    required List<List<Point>> contours,
    required graphics.PdfFillRule rule,
  }) => ClipState(
    this.bounds.intersect(bounds),
    paths: [...paths, ClipPath(contours, rule)],
  );

  ClipState intersectBounds(IntRect bounds) =>
      ClipState(this.bounds.intersect(bounds), paths: paths);
}

class ClipPath {
  const ClipPath(this.contours, this.rule);

  final List<List<Point>> contours;
  final graphics.PdfFillRule rule;
}

Point cubic(Point p0, Point p1, Point p2, Point p3, double t) {
  final mt = 1 - t;
  final a = mt * mt * mt;
  final b = 3 * mt * mt * t;
  final c = 3 * mt * t * t;
  final d = t * t * t;
  return Point(
    a * p0.x + b * p1.x + c * p2.x + d * p3.x,
    a * p0.y + b * p1.y + c * p2.y + d * p3.y,
  );
}

int cubicFlattenSegmentCount(Point p0, Point p1, Point p2, Point p3) {
  final left = math.min(math.min(p0.x, p1.x), math.min(p2.x, p3.x));
  final top = math.min(math.min(p0.y, p1.y), math.min(p2.y, p3.y));
  final right = math.max(math.max(p0.x, p1.x), math.max(p2.x, p3.x));
  final bottom = math.max(math.max(p0.y, p1.y), math.max(p2.y, p3.y));
  final extent = math.max(right - left, bottom - top);
  if (extent >= 96) return maxCubicFlattenSegments;
  if (extent >= 48) return midCubicFlattenSegments;
  return minCubicFlattenSegments;
}

List<List<Point>> flattenPath(
  graphics.PdfPath path, {
  required graphics.PdfMatrix transform,
  bool closeOpenContours = false,
}) {
  final contours = <List<Point>>[];
  List<Point>? current;
  Point? start;
  Point? cursor;

  void closeCurrentContour() {
    final contour = current;
    final startPoint = start;
    if (!closeOpenContours || contour == null || startPoint == null) return;
    if (contour.isEmpty || contour.last.distanceTo(startPoint) > 1e-6) {
      contour.add(startPoint);
    }
  }

  Point tx(double x, double y) =>
      Point(transform.transformX(x, y), transform.transformY(x, y));

  for (final segment in path.segments) {
    switch (segment) {
      case graphics.PdfMoveTo(:final x, :final y):
        closeCurrentContour();
        current = <Point>[];
        contours.add(current);
        start = cursor = tx(x, y);
        current.add(cursor);
      case graphics.PdfLineTo(:final x, :final y):
        current ??= <Point>[];
        if (!contours.contains(current)) contours.add(current);
        cursor = tx(x, y);
        current.add(cursor);
      case graphics.PdfCubicTo():
        if (cursor == null) break;
        current ??= <Point>[];
        if (!contours.contains(current)) contours.add(current);
        final p0 = cursor;
        final p1 = tx(segment.x1, segment.y1);
        final p2 = tx(segment.x2, segment.y2);
        final p3 = tx(segment.x3, segment.y3);
        final segments = cubicFlattenSegmentCount(p0, p1, p2, p3);
        for (var i = 1; i <= segments; i++) {
          current.add(cubic(p0, p1, p2, p3, i / segments));
        }
        cursor = p3;
      case graphics.PdfClosePath():
        if (current != null && start != null) current.add(start);
        cursor = start;
    }
  }
  closeCurrentContour();
  return [
    for (final contour in contours)
      if (contour.length >= 2) contour,
  ];
}

bool containsEvenOdd(List<List<Point>> contours, double x, double y) {
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

bool containsNonZero(List<List<Point>> contours, double x, double y) {
  var winding = 0;
  for (final contour in contours) {
    for (var i = 0, j = contour.length - 1; i < contour.length; j = i++) {
      final p1 = contour[j];
      final p2 = contour[i];
      if (p1.y <= y) {
        if (p2.y > y && isLeft(p1, p2, x, y) > 0) winding++;
      } else if (p2.y <= y && isLeft(p1, p2, x, y) < 0) {
        winding--;
      }
    }
  }
  return winding != 0;
}

bool isAxisAlignedRectangle(List<List<Point>> contours) {
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

bool isPixelAlignedRectangle(List<List<Point>> contours, IntRect bounds) {
  if (!isAxisAlignedRectangle(contours)) return false;
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

double isLeft(Point p1, Point p2, double x, double y) =>
    (p2.x - p1.x) * (y - p1.y) - (x - p1.x) * (p2.y - p1.y);

double strokeCoverageAtPoint(
  double x,
  double y,
  Point p1,
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

int intValue(cos.CosObject? object) => switch (object) {
  cos.CosInteger(:final value) => value,
  cos.CosReal(:final value) => value.round(),
  _ => 0,
};

double numberValue(cos.CosObject? object) => switch (object) {
  cos.CosInteger(:final value) => value.toDouble(),
  cos.CosReal(:final value) => value,
  _ => 0,
};

String? nameValue(cos.CosObject? object) => switch (object) {
  cos.CosName(:final value) => value,
  _ => null,
};

List<String> filterNames(cos.CosDocument cosDocument, cos.CosDictionary dict) {
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
