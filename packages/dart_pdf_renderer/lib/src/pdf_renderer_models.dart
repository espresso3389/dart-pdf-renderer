part of 'pdf_renderer.dart';

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
