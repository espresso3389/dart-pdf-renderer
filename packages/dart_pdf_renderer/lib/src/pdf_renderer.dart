// ignore_for_file: unused_import

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;
// ignore: implementation_imports
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

import 'pdf_renderer_display_list.dart';
import 'pdf_renderer_recording_device.dart';
import 'pdf_renderer_glyph.dart';
import 'pdf_renderer_graphics.dart';
import 'pdf_renderer_models.dart';
import 'pdf_renderer_direct_device.dart';
import 'pdf_renderer_image.dart';
import 'pdf_renderer_geometry.dart';

const antiAliasSamplesPerAxis = 4;
const antiAliasSampleCount = antiAliasSamplesPerAxis * antiAliasSamplesPerAxis;
const antiAliasSampleScale = 1 / antiAliasSampleCount;
const minCubicFlattenSegments = 8;
const midCubicFlattenSegments = 12;
const maxCubicFlattenSegments = 16;
const glyphTransformQuantization = 64;
const glyphSubpixelQuantization = 1;
const defaultMaxGlyphRasterPixels = 65536;
const defaultMaxGlyphRasterCacheEntries = 2048;

/// A synchronous renderer for PDF pages backed by the pure Dart renderer.
class PdfPageRenderer {
  /// Creates a renderer for [document].
  ///
  /// Optional cache instances can be supplied to share or control cache state
  /// across renderer instances.
  PdfPageRenderer(
    this.document, {
    PdfGlyphRasterCache? glyphRasterCache,
    PdfImageDecodeCache? imageDecodeCache,
  }) : glyphRasterCache = glyphRasterCache ?? PdfGlyphRasterCache(),
       imageDecodeCache = imageDecodeCache ?? PdfImageDecodeCache();

  /// The PDF document rendered by this instance.
  final PdfDocument document;
  final displayLists = <PdfPageDisplayListKey, PdfPageDisplayList>{};

  /// The glyph raster cache used while rendering text.
  final PdfGlyphRasterCache glyphRasterCache;

  /// The image decode cache used while rendering image XObjects.
  final PdfImageDecodeCache imageDecodeCache;
  late final ImageColorContext documentImageColorContext =
      ImageColorContext.fromDocument(document.cos);

  /// The current number of cached page display lists.
  ///
  /// Each page can have separate entries for annotation and non-annotation
  /// rendering.
  int get displayListCacheEntryCount => displayLists.length;

  /// The page sizes in display coordinate order.
  List<PdfPageSize> get pageSizes => List.unmodifiable([
    for (var i = 0; i < document.pageCount; i++) pageSize(document.page(i)),
  ]);

  /// Removes cached display lists.
  ///
  /// When [pageNumber] is provided, only that 1-based page is cleared. When
  /// [annotations] is provided, only entries for that annotation mode are
  /// cleared. With no filters, the whole display-list cache is cleared.
  ///
  /// Internally, display lists are keyed by the page object's identity rather
  /// than by page number. The page number is resolved through the document's
  /// current page tree at the time this method is called, so page reordering can
  /// update page-number lookup without making existing cache entries depend on
  /// their old positions.
  void clearDisplayListCache({int? pageNumber, bool? annotations}) {
    if (pageNumber == null && annotations == null) {
      displayLists.clear();
      return;
    }
    final pageKey = pageNumber == null
        ? null
        : pageCacheKeyForPageNumber(pageNumber);
    displayLists.removeWhere(
      (key, _) =>
          (pageKey == null || key.page == pageKey) &&
          (annotations == null || key.annotations == annotations),
    );
  }

  /// Removes cached display lists for a single 1-based page.
  ///
  /// The page number is a lookup key into the document's current page order;
  /// the cached entry itself is identified by the page dictionary/reference.
  void clearPageCache(int pageNumber, {bool? annotations}) {
    clearDisplayListCache(pageNumber: pageNumber, annotations: annotations);
  }

  /// Renders a page region to BGRA pixels.
  Uint8List renderBgraRegion({
    required int pageNumber,
    required double x,
    required double y,
    required int width,
    required int height,
    required double pixelRatio,
    required int backgroundColor,
    required bool annotations,
    PdfRenderTiming? timing,
  }) {
    final rgba = renderRgbaRegion(
      pageNumber: pageNumber,
      x: x,
      y: y,
      width: width,
      height: height,
      pixelRatio: pixelRatio,
      backgroundColor: backgroundColor,
      annotations: annotations,
      timing: timing,
    );
    final stopwatch = timing == null ? null : (Stopwatch()..start());
    final bgra = rgbaToBgra(rgba, width: width, height: height);
    if (stopwatch != null) {
      stopwatch.stop();
      timing!.bgraConversionMicroseconds = stopwatch.elapsedMicroseconds;
    }
    return bgra;
  }

  /// Renders a page region to RGBA pixels.
  Uint8List renderRgbaRegion({
    required int pageNumber,
    required double x,
    required double y,
    required int width,
    required int height,
    required double pixelRatio,
    required int backgroundColor,
    required bool annotations,
    PdfRenderTrace? trace,
    PdfRenderTiming? timing,
  }) {
    timing?.reset();
    final page = document.page(pageNumber - 1);
    return renderRgbaDisplayList(
      displayListFor(pageNumber, page, annotations, timing: timing),
      cosDocument: page.document.cos,
      x: x,
      y: y,
      width: width,
      height: height,
      pixelRatio: pixelRatio,
      backgroundColor: backgroundColor,
      glyphRasterCache: glyphRasterCache,
      imageDecodeCache: imageDecodeCache,
      trace: trace,
      timing: timing,
    );
  }

  PdfPageDisplayList displayListFor(
    int pageNumber,
    PdfPage page,
    bool annotations, {
    PdfRenderTiming? timing,
  }) {
    final key = PdfPageDisplayListKey(
      pageCacheKeyForPage(page),
      annotations: annotations,
    );
    final cached = displayLists[key];
    if (cached != null) {
      timing?.displayListCacheHit = true;
      return cached;
    }
    timing?.displayListCacheHit = false;
    final stopwatch = timing == null ? null : (Stopwatch()..start());
    final displayList = buildDisplayList(
      page,
      annotations: annotations,
      documentImageColorContext: documentImageColorContext,
    );
    if (stopwatch != null) {
      stopwatch.stop();
      timing!.displayListBuildMicroseconds = stopwatch.elapsedMicroseconds;
    }
    displayLists[key] = displayList;
    return displayList;
  }

  PdfPageCacheKey pageCacheKeyForPageNumber(int pageNumber) {
    if (pageNumber < 1 || pageNumber > document.pageCount) {
      throw RangeError.range(pageNumber, 1, document.pageCount, 'pageNumber');
    }
    return pageCacheKeyForPage(document.page(pageNumber - 1));
  }

  PdfPageCacheKey pageCacheKeyForPage(PdfPage page) {
    return PdfPageCacheKey(document.cos.referenceTo(page.dict), page.dict);
  }

  static PdfPageSize pageSize(PdfPage page) {
    final box = page.cropBox;
    final swap = page.rotation == 90 || page.rotation == 270;
    return swap
        ? PdfPageSize(box.height, box.width)
        : PdfPageSize(box.width, box.height);
  }

  static PdfPageDisplayList buildDisplayList(
    PdfPage page, {
    required bool annotations,
    required ImageColorContext documentImageColorContext,
  }) {
    final imageColorContexts = collectImageColorContexts(
      page,
      annotations: annotations,
      documentImageColorContext: documentImageColorContext,
    );
    final device = RecordingPdfDevice(
      transform: pageToViewMatrix(page),
      imageColorContexts: imageColorContexts,
      documentImageColorContext: documentImageColorContext,
    );
    final interpreter = PdfInterpreter(cos: page.document.cos, device: device)
      ..drawPage(page);
    if (annotations) interpreter.drawAnnotations(page);
    return PdfPageDisplayList(List.unmodifiable(device.commands));
  }

  static Uint8List renderRgbaDisplayList(
    PdfPageDisplayList displayList, {
    required cos.CosDocument cosDocument,
    required double x,
    required double y,
    required int width,
    required int height,
    required double pixelRatio,
    required int backgroundColor,
    required PdfGlyphRasterCache glyphRasterCache,
    required PdfImageDecodeCache imageDecodeCache,
    PdfRenderTrace? trace,
    PdfRenderTiming? timing,
  }) {
    final clearStopwatch = timing == null ? null : (Stopwatch()..start());
    final surface = RgbaSurface(width, height)
      ..clear(
        (backgroundColor >> 16) & 0xff,
        (backgroundColor >> 8) & 0xff,
        backgroundColor & 0xff,
        (backgroundColor >> 24) & 0xff,
      );
    if (clearStopwatch != null) {
      clearStopwatch.stop();
      timing!.surfaceClearMicroseconds = clearStopwatch.elapsedMicroseconds;
    }
    final viewX = x / pixelRatio;
    final viewY = y / pixelRatio;
    final transform = PdfMatrix.translation(
      -viewX,
      -viewY,
    ).concat(PdfMatrix.scaled(pixelRatio, pixelRatio));
    final replayStopwatch = timing == null ? null : (Stopwatch()..start());
    displayList.replay(
      PdfDirectPdfDevice.internal(
        surface,
        cosDocument: cosDocument,
        transform: transform,
        glyphRasterCache: glyphRasterCache,
        imageDecodeCache: imageDecodeCache,
        trace: trace,
        timing: timing,
      ),
      PdfDisplayRect(
        viewX,
        viewY,
        viewX + width / pixelRatio,
        viewY + height / pixelRatio,
      ),
    );
    if (replayStopwatch != null) {
      replayStopwatch.stop();
      timing!.replayMicroseconds = replayStopwatch.elapsedMicroseconds;
    }
    return surface.pixels;
  }

  static PdfMatrix pageToViewMatrix(PdfPage page) {
    final box = page.cropBox;
    final unrotated = PdfMatrix.translation(-box.left, -box.bottom)
        .concat(const PdfMatrix.scaled(1, -1))
        .concat(PdfMatrix.translation(0, box.height));
    return switch (page.rotation) {
      90 =>
        unrotated
            .concat(const PdfMatrix(0, 1, -1, 0, 0, 0))
            .concat(PdfMatrix.translation(box.height, 0)),
      180 =>
        unrotated
            .concat(const PdfMatrix(-1, 0, 0, -1, 0, 0))
            .concat(PdfMatrix.translation(box.width, box.height)),
      270 =>
        unrotated
            .concat(const PdfMatrix(0, -1, 1, 0, 0, 0))
            .concat(PdfMatrix.translation(0, box.width)),
      _ => unrotated,
    };
  }
}
