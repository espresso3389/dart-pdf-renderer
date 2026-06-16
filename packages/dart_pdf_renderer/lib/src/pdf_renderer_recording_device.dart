// ignore_for_file: unused_import, implementation_imports

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;
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
        PdfStrokePathCommand,
        RecordingPdfDevice;
import 'pdf_display_command.dart';
import 'pdfium_cmyk.dart';
import 'pdf_renderer.dart';
import 'pdf_renderer_direct_device.dart';
import 'pdf_renderer_display_list.dart';
import 'pdf_renderer_geometry.dart';
import 'pdf_renderer_glyph.dart';
import 'pdf_renderer_graphics.dart';
import 'pdf_renderer_image.dart';
import 'pdf_renderer_models.dart';

class RecordingPdfDevice implements PdfDevice {
  RecordingPdfDevice({
    required this.transform,
    required this.imageColorContexts,
    required this.documentImageColorContext,
  });

  final PdfMatrix transform;
  final Map<cos.CosStream, ImageColorContext> imageColorContexts;
  final ImageColorContext documentImageColorContext;
  final commandStack = <List<PdfDisplayCommand>>[<PdfDisplayCommand>[]];

  List<PdfDisplayCommand> get commands => commandStack.first;

  void addCommand(PdfDisplayCommand command) {
    commandStack.last.add(command);
  }

  @override
  void save() {
    addCommand(const PdfSaveCommand());
  }

  @override
  void restore() {
    addCommand(const PdfRestoreCommand());
  }

  @override
  void fillPath(PdfPath path, PdfColor color, PdfFillRule rule, double alpha) {
    final transformed = transformPath(path, transform);
    addCommand(
      PdfFillPathCommand(
        transformed,
        color,
        rule,
        alpha,
        pathBounds(transformed),
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
    final transformed = transformPath(path, transform);
    addCommand(
      PdfFillPathGradientCommand(
        transformed,
        rule,
        transformGradient(gradient, transform),
        alpha,
        pathBounds(transformed),
      ),
    );
  }

  @override
  void fillMesh(PdfMesh mesh, double alpha) {
    final transformed = transformMesh(mesh, transform);
    addCommand(PdfFillMeshCommand(transformed, alpha, meshBounds(transformed)));
  }

  @override
  void strokePath(
    PdfPath path,
    PdfColor color,
    PdfStroke stroke,
    double alpha,
  ) {
    final transformed = transformPath(path, transform);
    final bounds = pathBounds(transformed)?.inflate(stroke.width / 2 + 1);
    addCommand(
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
    addCommand(PdfClipPathCommand(transformPath(path, transform), rule));
  }

  @override
  void drawText(PdfTextRun run) {
    final transformed = transformTextRun(run, transform);
    if (run.invisible) {
      addCommand(PdfDrawTextCommand(transformed, null));
      return;
    }
    addCommand(
      PdfDrawTextCommand(transformed, textRunBounds(transformed)?.inflate(2)),
    );
  }

  @override
  void drawImage(PdfImageRequest request) {
    final transformed = transformImageDrawRequest(
      ImageDrawRequest(
        request,
        imageColorContexts[request.stream] ?? documentImageColorContext,
      ),
      transform,
    );
    addCommand(
      PdfDrawImageCommand(transformed, imageRequestBounds(transformed.request)),
    );
  }

  @override
  void setBlendMode(PdfBlendMode mode) {
    addCommand(PdfSetBlendModeCommand(mode));
  }

  @override
  void beginGroup(double alpha, {bool knockout = false}) {
    addCommand(PdfBeginGroupCommand(alpha, knockout: knockout));
  }

  @override
  void endGroup() {
    addCommand(const PdfEndGroupCommand());
  }

  @override
  void beginSoftMasked() {
    addCommand(const PdfBeginSoftMaskCommand());
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
    commandStack.add(<PdfDisplayCommand>[]);
    drawMask();
    final maskCommands = List<PdfDisplayCommand>.unmodifiable(
      commandStack.removeLast(),
    );
    addCommand(
      PdfEndSoftMaskCommand(
        luminosity: luminosity,
        backdrop: transformRect(backdrop, transform),
        maskCommands: maskCommands,
        backdropLuminance: backdropLuminance,
        transferScale: transferScale,
        transferOffset: transferOffset,
      ),
    );
  }
}

/// Cache for rasterized glyph masks.
