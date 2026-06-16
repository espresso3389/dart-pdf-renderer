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
        PdfStrokePathCommand;
import 'pdf_display_command.dart';
import 'pdfium_cmyk.dart';

part 'pdf_renderer_display_list.dart';
part 'pdf_renderer_recording_device.dart';
part 'pdf_renderer_glyph.dart';
part 'pdf_renderer_graphics.dart';
part 'pdf_renderer_models.dart';
part 'pdf_renderer_direct_device.dart';
part 'pdf_renderer_image.dart';
part 'pdf_renderer_geometry.dart';

const _antiAliasSamplesPerAxis = 4;
const _antiAliasSampleCount =
    _antiAliasSamplesPerAxis * _antiAliasSamplesPerAxis;
const _antiAliasSampleScale = 1 / _antiAliasSampleCount;
const _minCubicFlattenSegments = 8;
const _midCubicFlattenSegments = 12;
const _maxCubicFlattenSegments = 16;
const _glyphTransformQuantization = 64;
const _glyphSubpixelQuantization = 1;
const _defaultMaxGlyphRasterPixels = 65536;
const _defaultMaxGlyphRasterCacheEntries = 2048;

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
  final _displayLists = <_PdfPageDisplayListKey, _PdfPageDisplayList>{};

  /// The glyph raster cache used while rendering text.
  final PdfGlyphRasterCache glyphRasterCache;

  /// The image decode cache used while rendering image XObjects.
  final PdfImageDecodeCache imageDecodeCache;
  late final _ImageColorContext _documentImageColorContext =
      _ImageColorContext.fromDocument(document.cos);

  /// The current number of cached page display lists.
  ///
  /// Each page can have separate entries for annotation and non-annotation
  /// rendering.
  int get displayListCacheEntryCount => _displayLists.length;

  /// The page sizes in display coordinate order.
  List<PdfPageSize> get pageSizes => List.unmodifiable([
    for (var i = 0; i < document.pageCount; i++) _pageSize(document.page(i)),
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
      _displayLists.clear();
      return;
    }
    final pageKey = pageNumber == null
        ? null
        : _pageCacheKeyForPageNumber(pageNumber);
    _displayLists.removeWhere(
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
    final bgra = _rgbaToBgra(rgba, width: width, height: height);
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
    return _renderRgbaDisplayList(
      _displayListFor(pageNumber, page, annotations, timing: timing),
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

  _PdfPageDisplayList _displayListFor(
    int pageNumber,
    PdfPage page,
    bool annotations, {
    PdfRenderTiming? timing,
  }) {
    final key = _PdfPageDisplayListKey(
      _pageCacheKeyForPage(page),
      annotations: annotations,
    );
    final cached = _displayLists[key];
    if (cached != null) {
      timing?.displayListCacheHit = true;
      return cached;
    }
    timing?.displayListCacheHit = false;
    final stopwatch = timing == null ? null : (Stopwatch()..start());
    final displayList = _buildDisplayList(
      page,
      annotations: annotations,
      documentImageColorContext: _documentImageColorContext,
    );
    if (stopwatch != null) {
      stopwatch.stop();
      timing!.displayListBuildMicroseconds = stopwatch.elapsedMicroseconds;
    }
    _displayLists[key] = displayList;
    return displayList;
  }

  _PdfPageCacheKey _pageCacheKeyForPageNumber(int pageNumber) {
    if (pageNumber < 1 || pageNumber > document.pageCount) {
      throw RangeError.range(pageNumber, 1, document.pageCount, 'pageNumber');
    }
    return _pageCacheKeyForPage(document.page(pageNumber - 1));
  }

  _PdfPageCacheKey _pageCacheKeyForPage(PdfPage page) {
    return _PdfPageCacheKey(document.cos.referenceTo(page.dict), page.dict);
  }

  static PdfPageSize _pageSize(PdfPage page) {
    final box = page.cropBox;
    final swap = page.rotation == 90 || page.rotation == 270;
    return swap
        ? PdfPageSize(box.height, box.width)
        : PdfPageSize(box.width, box.height);
  }

  static _PdfPageDisplayList _buildDisplayList(
    PdfPage page, {
    required bool annotations,
    required _ImageColorContext documentImageColorContext,
  }) {
    final imageColorContexts = _collectImageColorContexts(
      page,
      annotations: annotations,
      documentImageColorContext: documentImageColorContext,
    );
    final device = _RecordingPdfDevice(
      transform: _pageToViewMatrix(page),
      imageColorContexts: imageColorContexts,
      documentImageColorContext: documentImageColorContext,
    );
    final interpreter = PdfInterpreter(cos: page.document.cos, device: device)
      ..drawPage(page);
    if (annotations) interpreter.drawAnnotations(page);
    return _PdfPageDisplayList(List.unmodifiable(device.commands));
  }

  static Uint8List _renderRgbaDisplayList(
    _PdfPageDisplayList displayList, {
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
    final surface = _RgbaSurface(width, height)
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
      PdfDirectPdfDevice._(
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

  static PdfMatrix _pageToViewMatrix(PdfPage page) {
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
