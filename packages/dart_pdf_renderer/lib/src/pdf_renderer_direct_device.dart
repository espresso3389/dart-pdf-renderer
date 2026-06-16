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
import 'pdf_renderer_display_list.dart';
import 'pdf_renderer_geometry.dart';
import 'pdf_renderer_glyph.dart';
import 'pdf_renderer_graphics.dart';
import 'pdf_renderer_image.dart';
import 'pdf_renderer_models.dart';
import 'pdf_renderer_recording_device.dart';

class PdfDirectPdfDevice
    implements graphics.PdfDevice, PdfDisplayCommandDevice {
  PdfDirectPdfDevice.internal(
    RgbaSurface surface, {
    required this.cosDocument,
    required graphics.PdfMatrix transform,
    this.glyphRasterCache,
    this.imageDecodeCache,
    this.trace,
    this.timing,
  }) : surfaceStack = [surface],
       transformStack = [transform],
       clipStack = [ClipState(IntRect(0, 0, surface.width, surface.height))];

  final List<RgbaSurface> surfaceStack;

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
  final List<graphics.PdfMatrix> transformStack;
  final List<ClipState> clipStack;
  final List<double> groupAlphaStack = [];

  RgbaSurface get surface => surfaceStack.last;
  graphics.PdfMatrix get transform => transformStack.last;
  ClipState get clip => clipStack.last;

  @override
  void save() {
    transformStack.add(transform);
    clipStack.add(clip);
  }

  @override
  void restore() {
    if (transformStack.length > 1) transformStack.removeLast();
    if (clipStack.length > 1) clipStack.removeLast();
  }

  @override
  void fillPath(
    graphics.PdfPath path,
    graphics.PdfColor color,
    graphics.PdfFillRule rule,
    double alpha,
  ) {
    fillPathInternal(path, color, rule, alpha, operation: 'fillPath');
  }

  @override
  void fillPathGradient(
    graphics.PdfPath path,
    graphics.PdfFillRule rule,
    graphics.PdfGradient gradient,
    double alpha,
  ) {
    fillPathGradientInternal(
      transformPath(path, transform),
      rule,
      transformGradient(gradient, transform),
      alpha,
    );
  }

  @override
  void fillMesh(graphics.PdfMesh mesh, double alpha) {
    if (mesh.vertices.isEmpty) return;
    final path = graphics.PdfPath([
      for (var i = 0; i < mesh.triangles.length; i += 3) ...[
        graphics.PdfMoveTo(
          mesh.vertices[mesh.triangles[i]].x,
          mesh.vertices[mesh.triangles[i]].y,
        ),
        graphics.PdfLineTo(
          mesh.vertices[mesh.triangles[i + 1]].x,
          mesh.vertices[mesh.triangles[i + 1]].y,
        ),
        graphics.PdfLineTo(
          mesh.vertices[mesh.triangles[i + 2]].x,
          mesh.vertices[mesh.triangles[i + 2]].y,
        ),
        const graphics.PdfClosePath(),
      ],
    ]);
    fillPathInternal(
      path,
      mesh.averageColor,
      graphics.PdfFillRule.nonzero,
      alpha,
      operation: 'fillMesh',
      details: 'triangles=${mesh.triangles.length ~/ 3} alpha=${f(alpha)}',
    );
  }

  @override
  void strokePath(
    graphics.PdfPath path,
    graphics.PdfColor color,
    graphics.PdfStroke stroke,
    double alpha,
  ) {
    final contours = flatten(path);
    if (contours.isEmpty) return;
    final bounds = boundsOf(contours)?.intersect(clip.bounds);
    if (bounds != null && !bounds.isEmpty) {
      traceOperation(
        'strokePath',
        bounds,
        '${colorDetails(color, alpha)} width=${f(stroke.width)} '
            'dash=${stroke.dashArray.length} clip=${clip.bounds}',
      );
    }
    final r = (color.red.clamp(0, 1) * 255).round();
    final g = (color.green.clamp(0, 1) * 255).round();
    final b = (color.blue.clamp(0, 1) * 255).round();
    final a = (alpha.clamp(0, 1) * 255).round();
    final width = math.max(1.0, stroke.width * transform.scaleFactor);
    final dashes = [
      for (final dash in stroke.dashArray)
        if (dash > 0) dash * transform.scaleFactor,
    ];
    final phase = stroke.dashPhase * transform.scaleFactor;
    for (final contour in contours) {
      strokeContour(contour, width, dashes, phase, r, g, b, a);
    }
  }

  @override
  void clipPath(graphics.PdfPath path, graphics.PdfFillRule rule) {
    final contours = flatten(path, closeOpenContours: true);
    final bounds = boundsOf(contours);
    if (bounds == null) return;
    traceOperation(
      'clipPath',
      bounds.intersect(clip.bounds),
      'rule=${rule.name} previousClip=${clip.bounds}',
    );
    if (isAxisAlignedRectangle(contours)) {
      clipStack[clipStack.length - 1] = clip.intersectBounds(bounds);
      return;
    }
    clipStack[clipStack.length - 1] = clip.intersect(
      bounds,
      contours: contours,
      rule: rule,
    );
  }

  @override
  void drawText(graphics.PdfTextRun run) {
    if (run.invisible) {
      traceRegion(
        'skipText',
        textRunTraceRegion(run),
        'reason=invisible font=${run.fontName} text="${snippet(run.text)}"',
      );
      return;
    }
    if (run.glyphs == null) {
      traceRegion(
        'skipText',
        textRunTraceRegion(run),
        'reason=noOutlines font=${run.fontName} size=${f(run.fontSize)} '
            'text="${snippet(run.text)}"',
      );
      return;
    }
    final glyphTransform = run.transform.concat(transform);
    for (final glyph in run.glyphs!) {
      final outline = glyph.outline;
      if (outline == null) continue;
      final shifted = graphics.PdfMatrix.translation(
        glyph.offset,
        0,
      ).concat(glyphTransform);
      if (glyphRasterCache?.paintGlyph(
            surface: surface,
            clip: clip,
            outline: outline,
            transform: shifted,
            color: run.color,
            alpha: 1,
            timing: timing,
          ) ??
          false) {
        continue;
      }
      fillPathWithTransform(
        outline,
        run.color,
        graphics.PdfFillRule.nonzero,
        1,
        shifted,
        operation: 'drawText',
        details: 'glyphOffset=${f(glyph.offset)} ${colorDetails(run.color, 1)}',
      );
    }
  }

  @override
  void drawImage(graphics.PdfImageRequest request) {
    drawImageRequest(ImageDrawRequest(request, ImageColorContext.device));
  }

  @override
  void drawImageRequest(Object drawRequest) {
    drawRequest as ImageDrawRequest;
    final request = drawRequest.request;
    final decoded = decodeImage(drawRequest);
    if (decoded == null) return;
    final matrix = request.transform.concat(transform);
    final inverse = matrix.inverted();
    if (inverse == null) return;

    final corners = [
      Point(matrix.transformX(0, 0), matrix.transformY(0, 0)),
      Point(matrix.transformX(1, 0), matrix.transformY(1, 0)),
      Point(matrix.transformX(1, 1), matrix.transformY(1, 1)),
      Point(matrix.transformX(0, 1), matrix.transformY(0, 1)),
    ];
    final bounds = boundsOf([corners])?.intersect(clip.bounds);
    if (bounds == null || bounds.isEmpty) return;
    traceOperation(
      'drawImage',
      bounds,
      'source=${decoded.width}x${decoded.height} alpha=${f(request.alpha)} '
          'clip=${clip.bounds}',
    );

    final alpha = (request.alpha.clamp(0, 1) * 255).round();
    final needsClip = clip.paths.isNotEmpty;
    if (!needsClip && alpha >= 255 && decoded.opaque) {
      drawOpaqueImageNoClip(bounds, inverse, decoded);
      return;
    }

    final dstPixels = surface.pixels;
    final dstWidth = surface.width;
    surface.markDirty(bounds);
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
        if (needsClip && !clip.contains(px + 0.5, sy)) {
          px++;
          ux += stepUx;
          uy += stepUy;
          continue;
        }
        if (ux >= 0 && ux <= 1 && uy >= 0 && uy <= 1) {
          final sample = sampleImageBilinear(
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

  void drawOpaqueImageNoClip(
    IntRect bounds,
    graphics.PdfMatrix inverse,
    DecodedImage decoded,
  ) {
    final dstPixels = surface.pixels;
    final dstWidth = surface.width;
    surface.markDirty(bounds);
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
                ? sampleImageBox(
                    srcPixels,
                    srcWidth,
                    srcHeight,
                    ux,
                    uy,
                    footprintX,
                    footprintY,
                  )
                : sampleImageBilinear(srcPixels, srcWidth, srcHeight, ux, uy);
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
          final sample = sampleImageBilinear(
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
  void setBlendMode(graphics.PdfBlendMode mode) {
    traceOperation('setBlendMode', clip.bounds, mode.name);
  }

  @override
  void beginGroup(double alpha, {bool knockout = false}) {
    traceOperation(
      'beginGroup',
      clip.bounds,
      'alpha=${f(alpha)} knockout=$knockout',
    );
    groupAlphaStack.add(alpha.clamp(0, 1));
    surfaceStack.add(RgbaSurface(surface.width, surface.height));
  }

  @override
  void endGroup() {
    if (surfaceStack.length <= 1) return;
    final layer = surfaceStack.removeLast();
    final alpha = groupAlphaStack.isEmpty ? 1.0 : groupAlphaStack.removeLast();
    traceOperation('endGroup', clip.bounds, 'alpha=${f(alpha)}');
    final parent = surface;
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
    traceOperation('beginSoftMasked', clip.bounds);
    surfaceStack.add(RgbaSurface(surface.width, surface.height));
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
    traceRegion(
      'endSoftMasked',
      rectToTraceRegion(backdrop),
      'luminosity=$luminosity backdropLuminance=${f(backdropLuminance)} '
          'transferScale=${f(transferScale)} '
          'transferOffset=${f(transferOffset)}',
    );
    if (surfaceStack.length <= 1) {
      return;
    }
    final content = surfaceStack.removeLast();
    final mask = RgbaSurface(surface.width, surface.height);
    surfaceStack.add(mask);
    drawMask();
    surfaceStack.removeLast();
    compositeSoftMaskedContent(
      content,
      mask,
      luminosity: luminosity,
      backdropLuminance: backdropLuminance,
      transferScale: transferScale,
      transferOffset: transferOffset,
    );
  }

  void compositeSoftMaskedContent(
    RgbaSurface content,
    RgbaSurface mask, {
    required bool luminosity,
    required double backdropLuminance,
    required double transferScale,
    required double transferOffset,
  }) {
    final dirtyBounds = content.dirtyBounds;
    if (dirtyBounds == null || dirtyBounds.isEmpty) return;
    final parent = surface;
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
                  luminance(
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

  void fillPathInternal(
    graphics.PdfPath path,
    graphics.PdfColor color,
    graphics.PdfFillRule rule,
    double alpha, {
    required String operation,
    String? details,
  }) {
    fillPathWithTransform(
      path,
      color,
      rule,
      alpha,
      transform,
      operation: operation,
      details: details,
    );
  }

  void fillPathWithTransform(
    graphics.PdfPath path,
    graphics.PdfColor color,
    graphics.PdfFillRule rule,
    double alpha,
    graphics.PdfMatrix transform, {
    required String operation,
    String? details,
  }) {
    final contours = flatten(path, matrix: transform, closeOpenContours: true);
    if (contours.isEmpty) return;
    final bounds = boundsOf(contours)?.intersect(clip.bounds);
    if (bounds == null || bounds.isEmpty) return;
    traceOperation(
      operation,
      bounds,
      details ??
          '${colorDetails(color, alpha)} rule=${rule.name} '
              'clip=${clip.bounds}',
    );

    final r = (color.red.clamp(0, 1) * 255).round();
    final g = (color.green.clamp(0, 1) * 255).round();
    final b = (color.blue.clamp(0, 1) * 255).round();
    final a = (alpha.clamp(0, 1) * 255).round();
    if (clip.paths.isEmpty && isPixelAlignedRectangle(contours, bounds)) {
      fillRectangle(bounds, r, g, b, a);
      return;
    }
    final mask = buildFillCoverageMask(bounds, contours, rule);
    final dstPixels = surface.pixels;
    final dstWidth = surface.width;
    surface.markDirty(bounds);
    final maskValues = mask.values;
    final maskBoundary = mask.boundary;
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
        final coveredSamples = fillCoverageSamples(px, py, contours, rule);
        if (coveredSamples != 0) {
          final coverageAlpha = (a * coveredSamples * antiAliasSampleScale)
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

  void fillPathGradientInternal(
    graphics.PdfPath path,
    graphics.PdfFillRule rule,
    graphics.PdfGradient gradient,
    double alpha,
  ) {
    if (gradient.isRadial || gradient.coords.length < 4) {
      fillPathInternal(
        path,
        gradient.averageColor,
        rule,
        alpha,
        operation: 'fillPathGradient',
        details: 'alpha=${f(alpha)} rule=${rule.name} fallback=averageColor',
      );
      return;
    }

    final contours = flatten(
      path,
      matrix: graphics.PdfMatrix.identity,
      closeOpenContours: true,
    );
    if (contours.isEmpty) return;
    final bounds = boundsOf(contours)?.intersect(clip.bounds);
    if (bounds == null || bounds.isEmpty) return;
    traceOperation(
      'fillPathGradient',
      bounds,
      'alpha=${f(alpha)} rule=${rule.name} type=axial '
          'coords=${gradient.coords.map(f).join(',')} '
          'line=${gradientLineDetails(gradient)} '
          'c0=${colorDetails(gradient.colors.first, 1)} '
          'cN=${colorDetails(gradient.colors.last, 1)} '
          'clip=${clip.bounds}',
    );

    final a = (alpha.clamp(0, 1) * 255).round();
    if (a <= 0) return;
    final mask = buildFillCoverageMask(bounds, contours, rule);
    final dstPixels = surface.pixels;
    final dstWidth = surface.width;
    surface.markDirty(bounds);
    final maskValues = mask.values;
    final maskBoundary = mask.boundary;
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
            final color = axialGradientColorAt(gradient, px + 0.5, py + 0.5);
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
        final coveredSamples = fillCoverageSamples(px, py, contours, rule);
        if (coveredSamples != 0) {
          final color = axialGradientColorAt(gradient, px + 0.5, py + 0.5);
          if (color != null) {
            final coverageAlpha = (a * coveredSamples * antiAliasSampleScale)
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

  void fillRectangle(IntRect bounds, int r, int g, int b, int a) {
    if (a <= 0) return;
    final clipped = bounds.intersect(clip.bounds);
    if (clipped.isEmpty) return;
    final dstPixels = surface.pixels;
    final dstWidth = surface.width;
    surface.markDirty(clipped);
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

  FillCoverageMask buildFillCoverageMask(
    IntRect bounds,
    List<List<Point>> contours,
    graphics.PdfFillRule rule,
  ) {
    final mask = FillCoverageMask(bounds);
    if (clip.paths.isEmpty) {
      buildFillCoverageMaskByScanline(mask, bounds, contours, rule);
    } else {
      buildFillCoverageMaskByPointTest(mask, bounds, contours, rule);
    }
    mask.markBoundaryTransitions(bounds);
    markFillBoundaryPixels(mask, bounds, contours);
    return mask;
  }

  void buildFillCoverageMaskByPointTest(
    FillCoverageMask mask,
    IntRect bounds,
    List<List<Point>> contours,
    graphics.PdfFillRule rule,
  ) {
    for (var py = bounds.top - 1; py <= bounds.bottom; py++) {
      final y = py + 0.5;
      for (var px = bounds.left - 1; px <= bounds.right; px++) {
        final x = px + 0.5;
        mask.set(px, py, fillCoversPoint(contours, rule, x, y));
      }
    }
  }

  void buildFillCoverageMaskByScanline(
    FillCoverageMask mask,
    IntRect bounds,
    List<List<Point>> contours,
    graphics.PdfFillRule rule,
  ) {
    final events = <ScanlineIntersection>[];
    final clipBounds = clip.bounds;
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
            markFillSpan(mask, py, spanStart, event.x, minX, maxX);
          }
          inside = !inside;
          spanStart = event.x;
        }
      } else {
        var winding = 0;
        var spanStart = 0.0;
        for (final event in events) {
          if (winding != 0) {
            markFillSpan(mask, py, spanStart, event.x, minX, maxX);
          }
          winding += event.windingDelta;
          spanStart = event.x;
        }
      }
    }
  }

  void markFillSpan(
    FillCoverageMask mask,
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

  void markFillBoundaryPixels(
    FillCoverageMask mask,
    IntRect bounds,
    List<List<Point>> contours,
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

  int fillCoverageSamples(
    int px,
    int py,
    List<List<Point>> contours,
    graphics.PdfFillRule rule,
  ) {
    var coveredSamples = 0;
    for (var sy = 0; sy < antiAliasSamplesPerAxis; sy++) {
      final y = py + (sy + 0.5) / antiAliasSamplesPerAxis;
      for (var sx = 0; sx < antiAliasSamplesPerAxis; sx++) {
        final x = px + (sx + 0.5) / antiAliasSamplesPerAxis;
        if (fillCoversPoint(contours, rule, x, y)) coveredSamples++;
      }
    }
    return coveredSamples;
  }

  bool fillCoversPoint(
    List<List<Point>> contours,
    graphics.PdfFillRule rule,
    double x,
    double y,
  ) {
    final inside = rule == graphics.PdfFillRule.evenOdd
        ? containsEvenOdd(contours, x, y)
        : containsNonZero(contours, x, y);
    return inside && clip.contains(x, y);
  }

  void traceOperation(String operation, IntRect bounds, [String? details]) {
    trace?.add(
      operation,
      bounds.toTraceRegion(),
      details: details == null
          ? 'groupDepth=${surfaceStack.length - 1}'
          : '$details groupDepth=${surfaceStack.length - 1}',
    );
  }

  void traceRegion(
    String operation,
    PdfRenderTraceRegion bounds, [
    String? details,
  ]) {
    trace?.add(
      operation,
      bounds,
      details: details == null
          ? 'groupDepth=${surfaceStack.length - 1}'
          : '$details groupDepth=${surfaceStack.length - 1}',
    );
  }

  String colorDetails(graphics.PdfColor color, double alpha) =>
      'rgb=${f(color.red)},${f(color.green)},${f(color.blue)} '
      'alpha=${f(alpha)}';

  String gradientLineDetails(graphics.PdfGradient gradient) {
    final coords = gradient.coords;
    if (coords.length < 4) return '(none)';
    final matrix = gradient.transform;
    final x0 = matrix.transformX(coords[0], coords[1]);
    final y0 = matrix.transformY(coords[0], coords[1]);
    final x1 = matrix.transformX(coords[2], coords[3]);
    final y1 = matrix.transformY(coords[2], coords[3]);
    return '${f(x0)},${f(y0)}->${f(x1)},${f(y1)}';
  }

  String f(double value) => value.toStringAsFixed(3);

  PdfRenderTraceRegion rectToTraceRegion(PdfRect rect) {
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
    final bounds = boundsOf([points]);
    return bounds?.toTraceRegion() ?? const PdfRenderTraceRegion(0, 0, 0, 0);
  }

  PdfRenderTraceRegion textRunTraceRegion(graphics.PdfTextRun run) {
    final matrix = run.transform.concat(transform);
    final corners = [
      Point(matrix.transformX(0, -0.25), matrix.transformY(0, -0.25)),
      Point(
        matrix.transformX(run.width, -0.25),
        matrix.transformY(run.width, -0.25),
      ),
      Point(matrix.transformX(run.width, 1), matrix.transformY(run.width, 1)),
      Point(matrix.transformX(0, 1), matrix.transformY(0, 1)),
    ];
    final bounds = boundsOf([corners]);
    return bounds?.toTraceRegion() ?? const PdfRenderTraceRegion(0, 0, 0, 0);
  }

  String snippet(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 48) return normalized;
    return '${normalized.substring(0, 45)}...';
  }

  List<List<Point>> flatten(
    graphics.PdfPath path, {
    graphics.PdfMatrix? matrix,
    bool closeOpenContours = false,
  }) {
    return flattenPath(
      path,
      transform: matrix ?? transform,
      closeOpenContours: closeOpenContours,
    );
  }

  IntRect? boundsOf(List<List<Point>> contours) {
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
    return IntRect(
      left.floor().clamp(0, surface.width),
      top.floor().clamp(0, surface.height),
      right.ceil().clamp(0, surface.width),
      bottom.ceil().clamp(0, surface.height),
    );
  }

  void strokeContour(
    List<Point> points,
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
      final direction = Point(
        (end.x - start.x) / remaining,
        (end.y - start.y) / remaining,
      );
      while (remaining > 1e-6) {
        final length = math.min(remaining, dashRemaining);
        final segmentEnd = Point(
          start.x + direction.x * length,
          start.y + direction.y * length,
        );
        if (dashOn) {
          drawStrokeSegment(start, segmentEnd, width, r, g, b, a);
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

  void drawStrokeSegment(
    Point p1,
    Point p2,
    double width,
    int r,
    int g,
    int b,
    int a,
  ) {
    final radius = width / 2;
    final antialiasRadius = radius + 0.5;
    final bounds = IntRect(
      (math.min(p1.x, p2.x) - antialiasRadius).floor().clamp(0, surface.width),
      (math.min(p1.y, p2.y) - antialiasRadius).floor().clamp(0, surface.height),
      (math.max(p1.x, p2.x) + antialiasRadius).ceil().clamp(0, surface.width),
      (math.max(p1.y, p2.y) + antialiasRadius).ceil().clamp(0, surface.height),
    ).intersect(clip.bounds);
    if (bounds.isEmpty) return;
    final dx = p2.x - p1.x;
    final dy = p2.y - p1.y;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= 1e-12) return;
    for (var py = bounds.top; py < bounds.bottom; py++) {
      for (var px = bounds.left; px < bounds.right; px++) {
        final coverage = strokeCoverageAtPixel(
          px,
          py,
          p1,
          dx,
          dy,
          lengthSquared,
          radius,
        );
        if (coverage <= 0) continue;
        surface.blendPixel(px, py, r, g, b, (a * coverage).round());
      }
    }
  }

  double strokeCoverageAtPixel(
    int px,
    int py,
    Point p1,
    double dx,
    double dy,
    double lengthSquared,
    double radius,
  ) {
    var coverage = 0.0;
    for (var sy = 0; sy < antiAliasSamplesPerAxis; sy++) {
      final y = py + (sy + 0.5) / antiAliasSamplesPerAxis;
      for (var sx = 0; sx < antiAliasSamplesPerAxis; sx++) {
        final x = px + (sx + 0.5) / antiAliasSamplesPerAxis;
        if (!clip.contains(x, y)) continue;
        coverage += strokeCoverageAtPoint(
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
    return coverage * antiAliasSampleScale;
  }

  DecodedImage? decodeImage(ImageDrawRequest request) {
    final cache = imageDecodeCache;
    return cache == null
        ? decodePdfImage(request, cosDocument)
        : cache.decode(request, cosDocument);
  }
}
