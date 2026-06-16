part of 'pdf_renderer.dart';

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
