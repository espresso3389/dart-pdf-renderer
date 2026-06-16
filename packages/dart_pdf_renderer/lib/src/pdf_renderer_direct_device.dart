part of 'pdf_renderer.dart';

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
    final contours = _flatten(path, closeOpenContours: true);
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
    final contours = _flatten(
      path,
      transform: transform,
      closeOpenContours: true,
    );
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

    final contours = _flatten(
      path,
      transform: PdfMatrix.identity,
      closeOpenContours: true,
    );
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

  List<List<_Point>> _flatten(
    PdfPath path, {
    PdfMatrix? transform,
    bool closeOpenContours = false,
  }) {
    return _flattenPath(
      path,
      transform: transform ?? _transform,
      closeOpenContours: closeOpenContours,
    );
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
