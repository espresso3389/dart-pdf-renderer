import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_pdf_renderer/dart_pdf_renderer.dart';
import 'package:pdf_cos/pdf_cos.dart' as cos;
import 'package:pdf_document/pdf_document.dart' as dart_pdf;
import 'package:pdf_graphics/pdf_graphics.dart' as pdf_graphics;
import 'package:pdfrx_engine/pdfrx_engine.dart' as pdfrx;

/// Installs the dart-pdf backed implementation as pdfrx's active backend.
void installPdfrxDartPdfBackend() {
  pdfrx.PdfrxEntryFunctions.instance = PdfrxDartPdfEntryFunctions();
}

/// A [pdfrx.PdfrxEntryFunctions] implementation backed by dart-pdf.
class PdfrxDartPdfEntryFunctions implements pdfrx.PdfrxEntryFunctions {
  const PdfrxDartPdfEntryFunctions();

  @override
  pdfrx.PdfrxBackendType get backendType => pdfrx.PdfrxBackendType.unknown;

  @override
  Future<void> init() async {}

  @override
  Future<T> suspendPdfiumWorkerDuringAction<T>(
    FutureOr<T> Function() action,
  ) async => action();

  @override
  Future<R> compute<M, R>(
    FutureOr<R> Function(M message) callback,
    M message,
  ) async => callback(message);

  @override
  Future<void> stopBackgroundWorker() async {}

  @override
  Future<pdfrx.PdfDocument> openAsset(
    String name, {
    pdfrx.PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
  }) => Future.error(
    UnsupportedError(
      'openAsset is not available in pure Dart. Use openFile/openData instead.',
    ),
  );

  @override
  Future<pdfrx.PdfDocument> openData(
    Uint8List data, {
    pdfrx.PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    String? sourceName,
    bool allowDataOwnershipTransfer = false,
    bool useProgressiveLoading = false,
    void Function()? onDispose,
  }) async {
    final opened = await _openWithPassword(
      data,
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
    );
    final originalBytes = Uint8List.fromList(data);
    final asyncRenderer = await PdfPageAsyncRenderer.create(
      originalBytes,
      password: opened.password,
    );
    return _DartPdfDocument(
      opened.document,
      sourceName: sourceName ?? 'memory:',
      originalBytes: originalBytes,
      asyncRenderer: asyncRenderer,
      onDispose: onDispose,
    );
  }

  @override
  Future<pdfrx.PdfDocument> openFile(
    String filePath, {
    pdfrx.PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
  }) async {
    final data = await File(filePath).readAsBytes();
    return openData(
      data,
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      sourceName: filePath,
      useProgressiveLoading: useProgressiveLoading,
    );
  }

  @override
  Future<pdfrx.PdfDocument> openCustom({
    required FutureOr<int> Function(Uint8List buffer, int position, int size)
    read,
    required int fileSize,
    required String sourceName,
    pdfrx.PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
    int? maxSizeToCacheOnMemory,
    void Function()? onDispose,
  }) async {
    final data = Uint8List(fileSize);
    var position = 0;
    while (position < fileSize) {
      final readSize = await read(data, position, fileSize - position);
      if (readSize <= 0) break;
      position += readSize;
    }
    if (position != fileSize) {
      throw StateError(
        'Custom PDF source ended at $position of $fileSize bytes.',
      );
    }
    return openData(
      data,
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      sourceName: sourceName,
      useProgressiveLoading: useProgressiveLoading,
      onDispose: onDispose,
    );
  }

  @override
  Future<pdfrx.PdfDocument> openUri(
    Uri uri, {
    pdfrx.PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
    pdfrx.PdfDownloadProgressCallback? progressCallback,
    bool preferRangeAccess = false,
    Map<String, String>? headers,
    bool withCredentials = false,
    Duration? timeout,
  }) async {
    if (uri.isScheme('file')) {
      return openFile(
        uri.toFilePath(),
        passwordProvider: passwordProvider,
        firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
        useProgressiveLoading: useProgressiveLoading,
      );
    }

    final client = HttpClient();
    try {
      final request = await client
          .getUrl(uri)
          .timeout(timeout ?? const Duration(seconds: 30));
      headers?.forEach(request.headers.add);
      final response = await request.close().timeout(
        timeout ?? const Duration(seconds: 30),
      );
      final total = response.contentLength >= 0 ? response.contentLength : null;
      var downloaded = 0;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        downloaded += chunk.length;
        progressCallback?.call(downloaded, total);
      }
      return openData(
        builder.takeBytes(),
        passwordProvider: passwordProvider,
        firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
        sourceName: uri.toString(),
        useProgressiveLoading: useProgressiveLoading,
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<pdfrx.PdfDocument> createNew({required String sourceName}) =>
      Future.error(
        UnsupportedError('createNew is not implemented by pdfrx_dart_pdf.'),
      );

  @override
  Future<pdfrx.PdfDocument> createFromJpegData(
    Uint8List jpegData, {
    required double width,
    required double height,
    required String sourceName,
  }) => Future.error(
    UnsupportedError(
      'createFromJpegData is not implemented by pdfrx_dart_pdf.',
    ),
  );

  @override
  Future<void> configureFontEnvironment({
    String? fontCachePath,
    List<String> fontPaths = const [],
  }) async {}

  @override
  Future<void> reloadFonts() async {}

  @override
  Future<void> addFontData({
    required String face,
    required Uint8List data,
    String? resolvedFace,
  }) async {}

  @override
  Future<void> addFontFile({
    required String face,
    required String filePath,
    String? resolvedFace,
  }) async {}

  @override
  Future<void> clearAllFontData() async {}
}

Future<_DartPdfOpenResult> _openWithPassword(
  Uint8List data, {
  pdfrx.PdfPasswordProvider? passwordProvider,
  required bool firstAttemptByEmptyPassword,
}) async {
  final tried = <String>{};

  Future<dart_pdf.PdfDocument> tryPassword(String password) async {
    tried.add(password);
    return dart_pdf.PdfDocument.open(data, password: password);
  }

  if (firstAttemptByEmptyPassword) {
    try {
      return _DartPdfOpenResult(await tryPassword(''), '');
    } on cos.CosPasswordException {
      // Ask the provider below.
    }
  }

  while (passwordProvider != null) {
    final password = await passwordProvider();
    if (password == null) break;
    if (tried.contains(password)) continue;
    try {
      return _DartPdfOpenResult(await tryPassword(password), password);
    } on cos.CosPasswordException {
      // Keep asking until pdfrx-style provider gives up.
    }
  }

  if (!firstAttemptByEmptyPassword && !tried.contains('')) {
    return _DartPdfOpenResult(await tryPassword(''), '');
  }

  throw cos.CosPasswordException();
}

class _DartPdfOpenResult {
  const _DartPdfOpenResult(this.document, this.password);

  final dart_pdf.PdfDocument document;
  final String password;
}

class _DartPdfDocument extends pdfrx.PdfDocument {
  _DartPdfDocument(
    this._document, {
    required super.sourceName,
    required this._originalBytes,
    required this._asyncRenderer,
    this._onDispose,
  }) {
    _pages = List.unmodifiable([
      for (var i = 0; i < _document.pageCount; i++)
        _DartPdfPage(
          this,
          _document.page(i),
          i + 1,
          _asyncRenderer.pageSizes[i],
        ),
    ]);
  }

  final dart_pdf.PdfDocument _document;
  final Uint8List _originalBytes;
  final void Function()? _onDispose;
  final _events = StreamController<pdfrx.PdfDocumentEvent>.broadcast();

  late List<pdfrx.PdfPage> _pages;
  final PdfPageAsyncRenderer _asyncRenderer;
  bool _disposed = false;

  @override
  pdfrx.PdfPermissions? get permissions => null;

  @override
  bool get isEncrypted => _document.cos.isEncrypted;

  @override
  Stream<pdfrx.PdfDocumentEvent> get events => _events.stream;

  @override
  List<pdfrx.PdfPage> get pages => _pages;

  @override
  set pages(List<pdfrx.PdfPage> value) {
    throw UnsupportedError(
      'Changing pages is not implemented by pdfrx_dart_pdf.',
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _asyncRenderer.dispose();
    } catch (_) {
      // Ignore renderer shutdown failures during document disposal.
    }
    _onDispose?.call();
    await _events.close();
  }

  Future<Uint8List?> renderBgraRegion({
    required int pageNumber,
    required double x,
    required double y,
    required int width,
    required int height,
    required double pixelRatio,
    required int backgroundColor,
    required bool annotations,
    pdfrx.PdfPageRenderCancellationToken? cancellationToken,
  }) async {
    final bgra = await _asyncRenderer.renderBgraRegion(
      pageNumber: pageNumber,
      x: x,
      y: y,
      width: width,
      height: height,
      pixelRatio: pixelRatio,
      backgroundColor: backgroundColor,
      annotations: annotations,
      cancellationToken: cancellationToken is _DartPdfCancellationToken
          ? cancellationToken._token
          : null,
    );
    return bgra;
  }

  @override
  Future<void> loadPagesProgressively<T>({
    pdfrx.PdfPageLoadingCallback<T>? onPageLoadProgress,
    T? data,
    Duration loadUnitDuration = const Duration(milliseconds: 250),
  }) async {
    if (onPageLoadProgress != null) {
      await onPageLoadProgress(pages.length, pages.length, data);
    }
  }

  @override
  Future<List<pdfrx.PdfOutlineNode>> loadOutline() async {
    final outlines = _document.cos.resolve(_document.catalog['Outlines']);
    if (outlines is! cos.CosDictionary) return const [];

    final first = _document.cos.resolve(outlines['First']);
    if (first is! cos.CosDictionary) return const [];

    return List.unmodifiable(_outlineSiblings(first, <cos.CosDictionary>{}));
  }

  List<pdfrx.PdfOutlineNode> _outlineSiblings(
    cos.CosDictionary first,
    Set<cos.CosDictionary> visited,
  ) {
    final nodes = <pdfrx.PdfOutlineNode>[];
    cos.CosDictionary? current = first;

    while (current != null && visited.add(current)) {
      final node = _outlineNode(current, visited);
      if (node != null) nodes.add(node);

      final next = _document.cos.resolve(current['Next']);
      current = next is cos.CosDictionary ? next : null;
    }

    return nodes;
  }

  pdfrx.PdfOutlineNode? _outlineNode(
    cos.CosDictionary dict,
    Set<cos.CosDictionary> visited,
  ) {
    final title = _document.cos.resolve(dict['Title']);
    if (title is! cos.CosString) return null;

    final firstChild = _document.cos.resolve(dict['First']);
    final children = firstChild is cos.CosDictionary
        ? _outlineSiblings(firstChild, visited)
        : const <pdfrx.PdfOutlineNode>[];

    return pdfrx.PdfOutlineNode(
      title: title.text,
      dest: _outlineDest(dict),
      children: List.unmodifiable(children),
    );
  }

  pdfrx.PdfDest? _outlineDest(cos.CosDictionary dict) {
    final direct = dart_pdf.PdfDestination.parse(_document, dict['Dest']);
    if (direct != null) return _toPdfrxDest(direct);

    final action = dart_pdf.PdfAction.parse(_document, dict['A']);
    if (action is dart_pdf.PdfGoToAction) {
      return _toPdfrxDest(action.destination);
    }
    return null;
  }

  @override
  bool isIdenticalDocumentHandle(Object? other) =>
      other is _DartPdfDocument && identical(other._document, _document);

  @override
  Future<bool> assemble() async => false;

  @override
  Future<Uint8List> encodePdf({
    bool incremental = false,
    bool removeSecurity = false,
  }) async => Uint8List.fromList(_originalBytes);

  @override
  Future<T> useNativeDocumentHandle<T>(
    FutureOr<T> Function(int nativeDocumentHandle) task,
  ) => Future.error(
    UnsupportedError(
      'Native document handles are not available in pdfrx_dart_pdf.',
    ),
  );

  @override
  Future<void> reloadPages({List<int>? pageNumbersToReload}) async {}
}

class _DartPdfPage extends pdfrx.PdfPage {
  _DartPdfPage(this.document, this._page, this.pageNumber, this._pageSize);

  final dart_pdf.PdfPage _page;
  final PdfPageSize _pageSize;

  @override
  final _DartPdfDocument document;

  @override
  final int pageNumber;

  @override
  double get width => _pageSize.width;

  @override
  double get height => _pageSize.height;

  @override
  pdfrx.PdfPageRotation get rotation {
    final quarterTurns = (_page.rotation ~/ 90) % 4;
    return pdfrx.PdfPageRotation.values[quarterTurns];
  }

  @override
  bool get isLoaded => true;

  @override
  pdfrx.PdfPageRenderCancellationToken createCancellationToken() =>
      _DartPdfCancellationToken(
        document._asyncRenderer.createCancellationToken(),
      );

  @override
  Future<pdfrx.PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    pdfrx.PdfPageRotation? rotationOverride,
    pdfrx.PdfAnnotationRenderingMode annotationRenderingMode =
        pdfrx.PdfAnnotationRenderingMode.annotationAndForms,
    int flags = pdfrx.PdfPageRenderFlags.none,
    pdfrx.PdfPageRenderCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken != null &&
        cancellationToken is! _DartPdfCancellationToken) {
      throw ArgumentError(
        'cancellationToken must be created by PdfPage.createCancellationToken().',
        'cancellationToken',
      );
    }
    if (cancellationToken?.isCanceled ?? false) return null;

    final pageWidth = fullWidth ?? this.width;
    final pageHeight = fullHeight ?? this.height;
    final pixelRatio = (pageWidth / this.width).clamp(0.01, 100.0);
    final targetWidth = width ?? pageWidth.ceil();
    final targetHeight = height ?? pageHeight.ceil();
    if (targetWidth < 1 || targetHeight < 1) return null;

    final bgra = await document.renderBgraRegion(
      pageNumber: pageNumber,
      x: x.toDouble(),
      y: y.toDouble(),
      width: targetWidth,
      height: targetHeight,
      pixelRatio: pixelRatio,
      backgroundColor: backgroundColor ?? 0xffffffff,
      annotations:
          annotationRenderingMode != pdfrx.PdfAnnotationRenderingMode.none,
      cancellationToken: cancellationToken,
    );

    if (bgra == null) return null;
    if (cancellationToken?.isCanceled ?? false) return null;
    return pdfrx.PdfImage.createFromBgraData(
      bgra,
      width: targetWidth,
      height: targetHeight,
    );
  }

  @override
  Future<pdfrx.PdfPageRawText?> loadText() async {
    final text = pdf_graphics.PdfTextExtractor.extract(
      document._document,
      pageNumber - 1,
    );
    if (text.text.isEmpty) {
      return pdfrx.PdfPageRawText('', const []);
    }

    final charRects = <pdfrx.PdfRect>[];
    pdfrx.PdfRect? previousRect;
    for (var i = 0; i < text.text.length; i++) {
      final rects = text.rectsFor(i, i + 1);
      final rect = rects.isEmpty ? previousRect : _toPdfrxRect(rects.first);
      charRects.add(rect ?? pdfrx.PdfRect.empty);
      previousRect = rect ?? previousRect;
    }

    return pdfrx.PdfPageRawText(text.text, charRects);
  }

  @override
  Future<List<pdfrx.PdfLink>> loadLinks({
    bool compact = false,
    bool enableAutoLinkDetection = true,
  }) async {
    final links = <pdfrx.PdfLink>[];

    for (final annotation in _page.annotations) {
      if (annotation is! dart_pdf.PdfLinkAnnotation) continue;
      final link = _linkFromAnnotation(annotation);
      if (link != null) links.add(link);
    }

    if (enableAutoLinkDetection) {
      links.addAll(await _loadDetectedWebLinks());
    }

    if (compact) {
      return List.unmodifiable([for (final link in links) link.compact()]);
    }
    return List.unmodifiable(links);
  }

  pdfrx.PdfLink? _linkFromAnnotation(dart_pdf.PdfLinkAnnotation annotation) {
    final rect = _toPdfrxRect(annotation.rect);
    final metadata = _annotationMetadata(annotation);
    final action = annotation.action;

    if (action is dart_pdf.PdfUriAction) {
      return pdfrx.PdfLink(
        [rect],
        url: Uri.tryParse(action.uri),
        annotation: metadata,
      );
    }
    if (action is dart_pdf.PdfGoToAction) {
      return pdfrx.PdfLink(
        [rect],
        dest: _toPdfrxDest(action.destination),
        annotation: metadata,
      );
    }
    if (metadata != null) {
      return pdfrx.PdfLink([rect], annotation: metadata);
    }
    return null;
  }

  Future<List<pdfrx.PdfLink>> _loadDetectedWebLinks() async {
    final text = await loadText();
    if (text == null || text.fullText.isEmpty) return const [];

    final links = <pdfrx.PdfLink>[];
    final urlPattern = RegExp(r"""https?://[^\s<>()\[\]{}"'`]+""");
    for (final match in urlPattern.allMatches(text.fullText)) {
      final rects = text.charRects
          .sublist(match.start, match.end)
          .where((rect) => rect.isNotEmpty)
          .toList();
      if (rects.isEmpty) continue;
      links.add(
        pdfrx.PdfLink([_mergeRects(rects)], url: Uri.tryParse(match.group(0)!)),
      );
    }
    return links;
  }
}

pdfrx.PdfRect _toPdfrxRect(dart_pdf.PdfRect rect) =>
    pdfrx.PdfRect(rect.left, rect.top, rect.right, rect.bottom);

pdfrx.PdfDest _toPdfrxDest(dart_pdf.PdfDestination destination) =>
    pdfrx.PdfDest(
      destination.pageIndex + 1,
      pdfrx.PdfDestCommand.parse(destination.fit),
      List.unmodifiable(destination.params),
    );

pdfrx.PdfAnnotation? _annotationMetadata(dart_pdf.PdfAnnotation annotation) {
  String? stringEntry(String key) {
    final value = annotation.document.cos.resolve(annotation.dict[key]);
    return value is cos.CosString ? value.text : null;
  }

  final metadata = pdfrx.PdfAnnotation(
    title: annotation.author,
    content: annotation.contents,
    subject: stringEntry('Subj'),
    modificationDate: pdfrx.PdfDateTime.fromPdfDateString(stringEntry('M')),
    creationDate: pdfrx.PdfDateTime.fromPdfDateString(
      stringEntry('CreationDate'),
    ),
  );
  return metadata.isEmpty ? null : metadata;
}

pdfrx.PdfRect _mergeRects(Iterable<pdfrx.PdfRect> rects) {
  final iterator = rects.iterator;
  if (!iterator.moveNext()) return pdfrx.PdfRect.empty;

  var left = iterator.current.left;
  var top = iterator.current.top;
  var right = iterator.current.right;
  var bottom = iterator.current.bottom;
  while (iterator.moveNext()) {
    final rect = iterator.current;
    if (rect.left < left) left = rect.left;
    if (rect.top > top) top = rect.top;
    if (rect.right > right) right = rect.right;
    if (rect.bottom < bottom) bottom = rect.bottom;
  }
  return pdfrx.PdfRect(left, top, right, bottom);
}

class _DartPdfCancellationToken
    implements pdfrx.PdfPageRenderCancellationToken {
  _DartPdfCancellationToken(this._token);

  final PdfRenderCancellationToken _token;

  @override
  void cancel() => _token.cancel();

  @override
  bool get isCanceled => _token.isCancelled;
}
