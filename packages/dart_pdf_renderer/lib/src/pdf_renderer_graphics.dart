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
import 'pdf_renderer_glyph.dart';
import 'pdf_renderer_image.dart';
import 'pdf_renderer_models.dart';
import 'pdf_renderer_recording_device.dart';

class ImageDrawRequest {
  const ImageDrawRequest(this.request, this.colorContext);

  final graphics.PdfImageRequest request;
  final ImageColorContext colorContext;
}

ImageDrawRequest transformImageDrawRequest(
  ImageDrawRequest request,
  graphics.PdfMatrix transform,
) => ImageDrawRequest(
  graphics.PdfImageRequest(
    stream: request.request.stream,
    transform: request.request.transform.concat(transform),
    alpha: request.request.alpha,
    isStencil: request.request.isStencil,
    stencilColor: request.request.stencilColor,
    isInline: request.request.isInline,
  ),
  request.colorContext,
);

graphics.PdfMesh transformMesh(
  graphics.PdfMesh mesh,
  graphics.PdfMatrix transform,
) => graphics.PdfMesh([
  for (final vertex in mesh.vertices)
    graphics.PdfMeshVertex(
      transform.transformX(vertex.x, vertex.y),
      transform.transformY(vertex.x, vertex.y),
      vertex.color,
    ),
], mesh.triangles);

graphics.PdfGradient transformGradient(
  graphics.PdfGradient gradient,
  graphics.PdfMatrix transform,
) => graphics.PdfGradient(
  isRadial: gradient.isRadial,
  coords: gradient.coords,
  colors: gradient.colors,
  stops: gradient.stops,
  transform: gradient.transform.concat(transform),
  extendStart: gradient.extendStart,
  extendEnd: gradient.extendEnd,
);

PdfRect transformRect(PdfRect rect, graphics.PdfMatrix transform) {
  final points = [
    Point(
      transform.transformX(rect.left, rect.top),
      transform.transformY(rect.left, rect.top),
    ),
    Point(
      transform.transformX(rect.right, rect.top),
      transform.transformY(rect.right, rect.top),
    ),
    Point(
      transform.transformX(rect.right, rect.bottom),
      transform.transformY(rect.right, rect.bottom),
    ),
    Point(
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

graphics.PdfColor? axialGradientColorAt(
  graphics.PdfGradient gradient,
  double x,
  double y,
) {
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
  return interpolateGradientColor(gradient, t);
}

graphics.PdfColor? interpolateGradientColor(
  graphics.PdfGradient gradient,
  double t,
) {
  final colors = gradient.colors;
  if (colors.isEmpty) return null;
  if (colors.length == 1) return colors.first;
  final stops = gradient.stops;
  if (stops.length != colors.length) {
    final scaled = t.clamp(0.0, 1.0) * (colors.length - 1);
    final index = scaled.floor().clamp(0, colors.length - 2);
    return lerpColor(colors[index], colors[index + 1], scaled - index);
  }
  if (t <= stops.first) return colors.first;
  for (var i = 1; i < stops.length; i++) {
    final stop = stops[i];
    if (t <= stop) {
      final previous = stops[i - 1];
      final span = stop - previous;
      final local = span.abs() <= 1e-12 ? 0.0 : (t - previous) / span;
      return lerpColor(colors[i - 1], colors[i], local);
    }
  }
  return colors.last;
}

graphics.PdfColor lerpColor(
  graphics.PdfColor a,
  graphics.PdfColor b,
  double t,
) {
  final local = t.clamp(0.0, 1.0);
  return graphics.PdfColor(
    a.red + (b.red - a.red) * local,
    a.green + (b.green - a.green) * local,
    a.blue + (b.blue - a.blue) * local,
  );
}

double luminance(int r, int g, int b) =>
    (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;

PdfDisplayRect? pathBounds(graphics.PdfPath path) {
  final points = <Point>[];
  for (final segment in path.segments) {
    switch (segment) {
      case graphics.PdfMoveTo(:final x, :final y) ||
          graphics.PdfLineTo(:final x, :final y):
        points.add(Point(x, y));
      case graphics.PdfCubicTo():
        points.add(Point(segment.x1, segment.y1));
        points.add(Point(segment.x2, segment.y2));
        points.add(Point(segment.x3, segment.y3));
      case graphics.PdfClosePath():
        break;
    }
  }
  return pointsBounds(points);
}

PdfDisplayRect? textRunBounds(graphics.PdfTextRun run) {
  final matrix = run.transform;
  return pointsBounds([
    Point(matrix.transformX(0, -0.25), matrix.transformY(0, -0.25)),
    Point(
      matrix.transformX(run.width, -0.25),
      matrix.transformY(run.width, -0.25),
    ),
    Point(matrix.transformX(run.width, 1), matrix.transformY(run.width, 1)),
    Point(matrix.transformX(0, 1), matrix.transformY(0, 1)),
  ]);
}

PdfDisplayRect? imageRequestBounds(
  graphics.PdfImageRequest request,
) => pointsBounds([
  Point(request.transform.transformX(0, 0), request.transform.transformY(0, 0)),
  Point(request.transform.transformX(1, 0), request.transform.transformY(1, 0)),
  Point(request.transform.transformX(1, 1), request.transform.transformY(1, 1)),
  Point(request.transform.transformX(0, 1), request.transform.transformY(0, 1)),
]);

PdfDisplayRect? meshBounds(graphics.PdfMesh mesh) => pointsBounds([
  for (final vertex in mesh.vertices) Point(vertex.x, vertex.y),
]);

PdfDisplayRect? pointsBounds(List<Point> points) {
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

IntRect? rawBoundsOf(List<List<Point>> contours) {
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
  return IntRect(left.floor(), top.floor(), right.ceil(), bottom.ceil());
}

/// The visible size of a PDF page after page rotation is applied.
