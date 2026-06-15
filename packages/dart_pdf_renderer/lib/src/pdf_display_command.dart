import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

/// A replay target for recorded PDF display commands.
abstract class PdfDisplayCommandDevice {
  /// Saves the current graphics state.
  void save();

  /// Restores the most recently saved graphics state.
  void restore();

  /// Fills [path] with [color], [rule], and [alpha].
  void fillPath(PdfPath path, PdfColor color, PdfFillRule rule, double alpha);

  /// Fills [path] with [gradient], [rule], and [alpha].
  void fillPathGradient(
    PdfPath path,
    PdfFillRule rule,
    PdfGradient gradient,
    double alpha,
  );

  /// Fills [mesh] with [alpha].
  void fillMesh(PdfMesh mesh, double alpha);

  /// Strokes [path] with [color], [stroke], and [alpha].
  void strokePath(PdfPath path, PdfColor color, PdfStroke stroke, double alpha);

  /// Clips subsequent drawing to [path] using [rule].
  void clipPath(PdfPath path, PdfFillRule rule);

  /// Draws a decoded text [run].
  void drawText(PdfTextRun run);

  /// Draws an image request object understood by the target device.
  void drawImageRequest(Object request);

  /// Sets the current blend [mode].
  void setBlendMode(PdfBlendMode mode);

  /// Begins an isolated transparency group with [alpha].
  ///
  /// If [knockout] is true, overlapping objects in the group knock out earlier
  /// objects instead of compositing over them.
  void beginGroup(double alpha, {bool knockout = false});

  /// Ends the current transparency group.
  void endGroup();

  /// Begins recording drawing commands that are affected by a soft mask.
  void beginSoftMasked();

  /// Ends the current soft-masked drawing section.
  void endSoftMasked({
    required bool luminosity,
    required PdfRect backdrop,
    required void Function() drawMask,
    double backdropLuminance = 0,
    double transferScale = 1,
    double transferOffset = 0,
  });
}

/// A recorded rendering command for a PDF page.
abstract class PdfDisplayCommand {
  /// Creates a command with optional replay [bounds].
  const PdfDisplayCommand([this.bounds]);

  /// The visible bounds affected by this command, or `null` if unknown.
  final PdfDisplayRect? bounds;

  /// Returns whether this command intersects [visibleBounds].
  bool shouldReplay(PdfDisplayRect visibleBounds) =>
      bounds == null || bounds!.intersects(visibleBounds);

  /// Replays this command to [device].
  void replay(PdfDisplayCommandDevice device);
}

/// A command that saves graphics state.
class PdfSaveCommand extends PdfDisplayCommand {
  /// Creates a save-state command.
  const PdfSaveCommand();

  @override
  void replay(PdfDisplayCommandDevice device) => device.save();
}

/// A command that restores graphics state.
class PdfRestoreCommand extends PdfDisplayCommand {
  /// Creates a restore-state command.
  const PdfRestoreCommand();

  @override
  void replay(PdfDisplayCommandDevice device) => device.restore();
}

/// A command that fills a path.
class PdfFillPathCommand extends PdfDisplayCommand {
  /// Creates a path-fill command.
  const PdfFillPathCommand(
    this.path,
    this.color,
    this.rule,
    this.alpha,
    super.bounds,
  );

  /// The path to fill.
  final PdfPath path;

  /// The fill color.
  final PdfColor color;

  /// The fill rule.
  final PdfFillRule rule;

  /// The fill alpha.
  final double alpha;

  @override
  void replay(PdfDisplayCommandDevice device) =>
      device.fillPath(path, color, rule, alpha);
}

/// A command that fills a path with a gradient.
class PdfFillPathGradientCommand extends PdfDisplayCommand {
  /// Creates a gradient path-fill command.
  const PdfFillPathGradientCommand(
    this.path,
    this.rule,
    this.gradient,
    this.alpha,
    super.bounds,
  );

  /// The path to fill.
  final PdfPath path;

  /// The fill rule.
  final PdfFillRule rule;

  /// The gradient to paint.
  final PdfGradient gradient;

  /// The fill alpha.
  final double alpha;

  @override
  void replay(PdfDisplayCommandDevice device) =>
      device.fillPathGradient(path, rule, gradient, alpha);
}

/// A command that fills a mesh.
class PdfFillMeshCommand extends PdfDisplayCommand {
  /// Creates a mesh-fill command.
  const PdfFillMeshCommand(this.mesh, this.alpha, super.bounds);

  /// The mesh to fill.
  final PdfMesh mesh;

  /// The fill alpha.
  final double alpha;

  @override
  void replay(PdfDisplayCommandDevice device) => device.fillMesh(mesh, alpha);
}

/// A command that strokes a path.
class PdfStrokePathCommand extends PdfDisplayCommand {
  /// Creates a path-stroke command.
  const PdfStrokePathCommand(
    this.path,
    this.color,
    this.stroke,
    this.alpha,
    super.bounds,
  );

  /// The path to stroke.
  final PdfPath path;

  /// The stroke color.
  final PdfColor color;

  /// The stroke style.
  final PdfStroke stroke;

  /// The stroke alpha.
  final double alpha;

  @override
  void replay(PdfDisplayCommandDevice device) =>
      device.strokePath(path, color, stroke, alpha);
}

/// A command that clips subsequent drawing to a path.
class PdfClipPathCommand extends PdfDisplayCommand {
  /// Creates a clipping command.
  const PdfClipPathCommand(this.path, this.rule);

  /// The clipping path.
  final PdfPath path;

  /// The clipping rule.
  final PdfFillRule rule;

  @override
  void replay(PdfDisplayCommandDevice device) => device.clipPath(path, rule);
}

/// A command that draws text.
class PdfDrawTextCommand extends PdfDisplayCommand {
  /// Creates a text drawing command.
  const PdfDrawTextCommand(this.run, super.bounds);

  /// The decoded text run to draw.
  final PdfTextRun run;

  @override
  void replay(PdfDisplayCommandDevice device) => device.drawText(run);
}

/// A command that draws an image.
class PdfDrawImageCommand extends PdfDisplayCommand {
  /// Creates an image drawing command.
  const PdfDrawImageCommand(this.request, super.bounds);

  /// The image request object understood by the rendering device.
  final Object request;

  @override
  void replay(PdfDisplayCommandDevice device) =>
      device.drawImageRequest(request);
}

/// A command that changes blend mode.
class PdfSetBlendModeCommand extends PdfDisplayCommand {
  /// Creates a blend-mode command.
  const PdfSetBlendModeCommand(this.mode);

  /// The blend mode to use for subsequent drawing.
  final PdfBlendMode mode;

  @override
  void replay(PdfDisplayCommandDevice device) => device.setBlendMode(mode);
}

/// A command that begins a transparency group.
class PdfBeginGroupCommand extends PdfDisplayCommand {
  /// Creates a begin-group command.
  const PdfBeginGroupCommand(this.alpha, {this.knockout = false});

  /// The group alpha.
  final double alpha;

  /// Whether objects in the group knock out earlier group content.
  final bool knockout;

  @override
  void replay(PdfDisplayCommandDevice device) =>
      device.beginGroup(alpha, knockout: knockout);
}

/// A command that ends a transparency group.
class PdfEndGroupCommand extends PdfDisplayCommand {
  /// Creates an end-group command.
  const PdfEndGroupCommand();

  @override
  void replay(PdfDisplayCommandDevice device) => device.endGroup();
}

/// A command that begins a soft-masked drawing section.
class PdfBeginSoftMaskCommand extends PdfDisplayCommand {
  /// Creates a begin-soft-mask command.
  const PdfBeginSoftMaskCommand();

  @override
  void replay(PdfDisplayCommandDevice device) => device.beginSoftMasked();
}

/// A command that ends a soft-masked drawing section.
class PdfEndSoftMaskCommand extends PdfDisplayCommand {
  /// Creates an end-soft-mask command.
  const PdfEndSoftMaskCommand({
    required this.luminosity,
    required this.backdrop,
    required this.maskCommands,
    this.backdropLuminance = 0,
    this.transferScale = 1,
    this.transferOffset = 0,
  });

  /// Whether the mask alpha is derived from rendered luminance.
  final bool luminosity;

  /// The backdrop rectangle used by the soft mask.
  final PdfRect backdrop;

  /// The commands that render the mask shape.
  final List<PdfDisplayCommand> maskCommands;

  /// The fallback luminance for unpainted mask pixels.
  final double backdropLuminance;

  /// The linear transfer scale applied to mask values.
  final double transferScale;

  /// The linear transfer offset applied to mask values.
  final double transferOffset;

  @override
  void replay(PdfDisplayCommandDevice device) {
    device.endSoftMasked(
      luminosity: luminosity,
      backdrop: backdrop,
      backdropLuminance: backdropLuminance,
      transferScale: transferScale,
      transferOffset: transferOffset,
      drawMask: () {
        for (final command in maskCommands) {
          command.replay(device);
        }
      },
    );
  }
}

/// A rectangle in display-list coordinate space.
class PdfDisplayRect {
  /// Creates a display rectangle from its edges.
  const PdfDisplayRect(this.left, this.top, this.right, this.bottom);

  /// The left edge.
  final double left;

  /// The top edge.
  final double top;

  /// The right edge.
  final double right;

  /// The bottom edge.
  final double bottom;

  /// Returns whether this rectangle intersects [other].
  bool intersects(PdfDisplayRect other) =>
      left <= other.right &&
      right >= other.left &&
      top <= other.bottom &&
      bottom >= other.top;

  /// Returns a rectangle expanded by [amount] in all directions.
  PdfDisplayRect inflate(double amount) => PdfDisplayRect(
    left - amount,
    top - amount,
    right + amount,
    bottom + amount,
  );
}
