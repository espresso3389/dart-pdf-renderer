import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pdf_document/pdf_document.dart';

import 'pdf_renderer.dart';

/// An asynchronous renderer for one PDF document hosted by a
/// [PdfPageAsyncRendererWorker].
///
/// This object is a lightweight handle that lives on the caller isolate. The
/// real [PdfPageRenderer] and [PdfDocument] live inside the worker isolate, and
/// [_rendererId] identifies that renderer in the worker's renderer table. This
/// keeps multiple documents on one worker isolate so they can share worker-wide
/// caches such as glyph rasterization and, in the future, font substitution
/// state.
///
/// Call [dispose] when the document is closed. Disposing this handle releases
/// only the document renderer in the worker; it does not stop the worker or
/// clear caches shared with other renderers.
class PdfPageAsyncRenderer {
  PdfPageAsyncRenderer._(this._worker, this._rendererId, this.pageSizes);

  final PdfPageAsyncRendererWorker _worker;
  final _PdfRendererId _rendererId;

  /// The page sizes in display coordinate order.
  ///
  /// These are captured when the document is opened in the worker and mirrored
  /// onto this handle so callers do not need a worker round trip just to lay out
  /// page placeholders.
  final List<PdfPageSize> pageSizes;
  var _nextCancellationTokenId = 0;
  bool _disposed = false;

  /// Creates a cancellation token for a future render request on this renderer.
  ///
  /// Tokens are bound to the renderer that created them. Passing a token from
  /// another [PdfPageAsyncRenderer] to [renderBgraRegion] throws, because the
  /// worker queue identifies cancellable jobs by the pair of document renderer
  /// id and token id.
  PdfRenderCancellationToken createCancellationToken() =>
      PdfRenderCancellationToken._(
        _worker._sendPort,
        _rendererId,
        _nextCancellationTokenId++,
      );

  /// Renders a page region to BGRA pixels on the worker isolate.
  ///
  /// Returns `null` when [cancellationToken] is cancelled before the render
  /// starts. The request is queued behind other requests submitted to the same
  /// [PdfPageAsyncRendererWorker], including requests for other open documents.
  Future<Uint8List?> renderBgraRegion({
    required int pageNumber,
    required double x,
    required double y,
    required int width,
    required int height,
    required double pixelRatio,
    required int backgroundColor,
    required bool annotations,
    PdfRenderCancellationToken? cancellationToken,
  }) async {
    _checkNotDisposed();
    if (cancellationToken != null &&
        (cancellationToken._sendPort != _worker._sendPort ||
            cancellationToken._rendererId != _rendererId)) {
      throw ArgumentError.value(
        cancellationToken,
        'cancellationToken',
        'Cancellation token was created by a different renderer.',
      );
    }
    if (cancellationToken?.isCancelled ?? false) return null;
    final data = await _worker._renderBgraRegion(
      _rendererId,
      _PdfRendererRenderParams(
        pageNumber: pageNumber,
        x: x,
        y: y,
        width: width,
        height: height,
        pixelRatio: pixelRatio,
        backgroundColor: backgroundColor,
        annotations: annotations,
      ),
      cancellationToken: cancellationToken,
    );
    return data?.materialize().asUint8List();
  }

  /// Removes cached display lists for this document renderer.
  ///
  /// The cache lives in the worker-side [PdfPageRenderer], not in this handle.
  /// If [pageNumber] is supplied, it is resolved in the worker against the
  /// document's current page order and then mapped to the page's stable cache
  /// identity. This means page reordering can change which page number resolves
  /// to which cache entry without making page numbers part of the internal
  /// cache key.
  Future<void> clearDisplayListCache({int? pageNumber, bool? annotations}) {
    _checkNotDisposed();
    return _worker._clearDisplayListCache(
      _rendererId,
      pageNumber: pageNumber,
      annotations: annotations,
    );
  }

  /// Removes cached display lists for a single 1-based page.
  ///
  /// This is a convenience wrapper around [clearDisplayListCache]. The page
  /// number is interpreted in the document's current page order.
  Future<void> clearPageCache(int pageNumber, {bool? annotations}) {
    return clearDisplayListCache(
      pageNumber: pageNumber,
      annotations: annotations,
    );
  }

  /// Releases this document renderer from its worker.
  ///
  /// Shared worker caches remain alive for other document renderers hosted by
  /// the same [PdfPageAsyncRendererWorker]. Stop the worker itself with
  /// [PdfPageAsyncRendererWorker.dispose] when those shared caches should be
  /// discarded too.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _worker._disposeRenderer(_rendererId);
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('PdfPageAsyncRenderer is disposed.');
    }
  }
}

/// A shared isolate-backed renderer worker that can host multiple documents.
///
/// The worker owns one isolate and a FIFO render queue. Each call to [openData]
/// creates a worker-side [PdfPageRenderer] and returns a [PdfPageAsyncRenderer]
/// handle for it. Requests from all handles are serialized through the same
/// queue, which reduces parallelism but allows expensive worker-wide state to
/// be shared across open documents.
///
/// Currently, glyph raster masks are shared at the worker level, while decoded
/// image caches are document-renderer local. This keeps large image cache
/// pressure isolated per document while still sharing glyph work across
/// documents. Font substitution caches should also live at this worker level.
class PdfPageAsyncRendererWorker {
  PdfPageAsyncRendererWorker._(this._isolate, this._sendPort);

  final Isolate _isolate;
  final SendPort _sendPort;
  bool _disposed = false;

  /// Starts a renderer worker isolate.
  ///
  /// The returned worker is initially empty. Use [openData] to open one or more
  /// documents on it, and [dispose] to stop the isolate and release all
  /// worker-side renderers and caches.
  static Future<PdfPageAsyncRendererWorker> create() async {
    final readyPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      _PdfRendererWorkerInit(readyPort.sendPort),
    );

    final ready = await readyPort.first;
    readyPort.close();
    if (ready is _PdfRendererWorkerReady) {
      return PdfPageAsyncRendererWorker._(isolate, ready.sendPort);
    }
    isolate.kill(priority: Isolate.immediate);
    if (ready is _PdfRendererWorkerError) {
      throw StateError('${ready.error}\n${ready.stackTrace}');
    }
    throw StateError('Unexpected renderer worker initialization response.');
  }

  /// Opens [documentBytes] in this worker and returns a document renderer.
  ///
  /// The bytes are transferred to the worker isolate, opened as a
  /// [PdfDocument], and wrapped by a worker-side [PdfPageRenderer]. The returned
  /// [PdfPageAsyncRenderer] contains only the renderer id and page sizes needed
  /// to address that worker-side renderer from the caller isolate.
  Future<PdfPageAsyncRenderer> openData(
    Uint8List documentBytes, {
    String password = '',
    int? maxDownscaledImagePixels,
  }) async {
    _checkNotDisposed();
    final response = await _sendRequest(
      _PdfRendererOpenRequest(
        TransferableTypedData.fromList([documentBytes]),
        password,
        maxDownscaledImagePixels,
      ),
    );
    response as _PdfRendererOpenResult;
    return PdfPageAsyncRenderer._(
      this,
      response.rendererId,
      response.pageSizes,
    );
  }

  Future<TransferableTypedData?> _renderBgraRegion(
    _PdfRendererId rendererId,
    _PdfRendererRenderParams params, {
    PdfRenderCancellationToken? cancellationToken,
  }) async {
    _checkNotDisposed();
    if (cancellationToken?.isCancelled ?? false) return null;
    return await _sendRequest<TransferableTypedData>(
      _PdfRendererRenderRequest(
        rendererId,
        params,
        cancellationTokenId: cancellationToken?._id,
      ),
      cancellationToken: cancellationToken,
      nullableOnCancel: true,
    );
  }

  Future<void> _disposeRenderer(_PdfRendererId rendererId) async {
    if (_disposed) return;
    await _sendRequest(_PdfRendererDisposeRequest(rendererId));
  }

  Future<void> _clearDisplayListCache(
    _PdfRendererId rendererId, {
    int? pageNumber,
    bool? annotations,
  }) async {
    _checkNotDisposed();
    await _sendRequest(
      _PdfRendererClearDisplayListCacheRequest(
        rendererId,
        pageNumber: pageNumber,
        annotations: annotations,
      ),
    );
  }

  /// Stops the worker isolate and releases all renderer resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final receivePort = ReceivePort();
    try {
      _sendPort.send(_PdfRendererStopRequest(receivePort.sendPort));
      final response = await receivePort.first;
      if (response is _PdfRendererCallError) {
        throw StateError('${response.error}\n${response.stackTrace}');
      }
    } finally {
      receivePort.close();
      _isolate.kill(priority: Isolate.beforeNextEvent);
    }
  }

  Future<R?> _sendRequest<R>(
    _PdfRendererWorkerRequest<R> request, {
    PdfRenderCancellationToken? cancellationToken,
    bool nullableOnCancel = false,
  }) async {
    final receivePort = ReceivePort();
    try {
      _sendPort.send(request.bind(receivePort.sendPort));
      cancellationToken?._markRequestSent();
      final response = await receivePort.first;
      if (response is _PdfRendererCallCanceled) {
        if (nullableOnCancel) return null;
        throw StateError('Renderer worker request was canceled.');
      }
      if (response is _PdfRendererCallError) {
        throw StateError('${response.error}\n${response.stackTrace}');
      }
      return response as R;
    } finally {
      receivePort.close();
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('PdfPageAsyncRendererWorker is disposed.');
    }
  }

  static void _workerMain(_PdfRendererWorkerInit init) {
    final commandPort = ReceivePort();
    try {
      final state = _PdfRendererWorkerState(commandPort);
      final queue = Queue<_PdfRendererBoundRequest>();
      var scheduled = false;

      void scheduleNext() {
        if (scheduled || state.stopped) return;
        scheduled = true;
        Timer.run(() {
          scheduled = false;
          if (state.stopped || queue.isEmpty) return;
          queue.removeFirst().execute(state);
          if (!state.stopped && queue.isNotEmpty) scheduleNext();
        });
      }

      init.readyPort.send(_PdfRendererWorkerReady(commandPort.sendPort));
      commandPort.listen((message) {
        if (message is _PdfRendererCancelRequest) {
          queue.removeWhere((call) => call.cancelIfQueued(message));
          return;
        }
        if (state.stopped) return;
        if (message is! _PdfRendererBoundRequest) return;
        queue.add(message);
        scheduleNext();
      });
    } catch (error, stackTrace) {
      commandPort.close();
      init.readyPort.send(
        _PdfRendererWorkerError(error.toString(), stackTrace.toString()),
      );
    }
  }
}

T _debugTimeSync<T>(String label, T Function() action) {
  Stopwatch? stopwatch;
  assert(() {
    stopwatch = Stopwatch()..start();
    return true;
  }());
  try {
    return action();
  } finally {
    assert(() {
      stopwatch!.stop();
      developer.log(
        '$label took ${stopwatch!.elapsedMilliseconds} ms',
        name: 'dart_pdf_renderer.render',
      );
      return true;
    }());
  }
}

class _PdfRendererWorkerInit {
  const _PdfRendererWorkerInit(this.readyPort);

  final SendPort readyPort;
}

class _PdfRendererWorkerReady {
  const _PdfRendererWorkerReady(this.sendPort);

  final SendPort sendPort;
}

class _PdfRendererWorkerError {
  const _PdfRendererWorkerError(this.error, this.stackTrace);

  final String error;
  final String stackTrace;
}

class _PdfRendererWorkerState {
  _PdfRendererWorkerState(this.receivePort);

  final ReceivePort receivePort;

  // Worker-side document renderers addressed from the caller isolate by
  // _PdfRendererId. The caller cannot hold these objects directly because they
  // live in this isolate.
  final renderers = <_PdfRendererId, PdfPageRenderer>{};

  // Shared across all renderers hosted by this worker. Image decode caches stay
  // renderer-local because large image pressure is usually document-specific.
  final glyphRasterCache = PdfGlyphRasterCache();
  var _nextRendererId = 0;
  var stopped = false;

  _PdfRendererOpenResult open(
    TransferableTypedData documentBytes,
    String password,
    int? maxDownscaledImagePixels,
  ) {
    final bytes = documentBytes.materialize().asUint8List();
    final document = PdfDocument.open(bytes, password: password);
    final renderer = PdfPageRenderer(
      document,
      glyphRasterCache: glyphRasterCache,
      imageDecodeCache: PdfImageDecodeCache(
        maxDownscaledImagePixels: maxDownscaledImagePixels,
      ),
    );
    final id = _nextRendererId++;
    renderers[id] = renderer;
    return _PdfRendererOpenResult(id, renderer.pageSizes);
  }

  PdfPageRenderer rendererFor(_PdfRendererId rendererId) {
    final renderer = renderers[rendererId];
    if (renderer == null) {
      throw StateError('PdfPageAsyncRenderer is disposed.');
    }
    return renderer;
  }

  void stop() {
    stopped = true;
    renderers.clear();
    receivePort.close();
  }
}

/// Cancellation token for queued asynchronous render requests.
class PdfRenderCancellationToken {
  PdfRenderCancellationToken._(this._sendPort, this._rendererId, this._id);

  final SendPort _sendPort;
  final _PdfRendererId _rendererId;
  final _PdfRendererCancellationTokenId _id;
  var _isCancelled = false;
  var _requestSent = false;
  var _cancellationSent = false;

  /// Whether cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// Requests cancellation of the associated render request.
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _sendCancellationIfReady();
  }

  void _markRequestSent() {
    _requestSent = true;
    _sendCancellationIfReady();
  }

  void _sendCancellationIfReady() {
    if (!_isCancelled || !_requestSent || _cancellationSent) return;
    _cancellationSent = true;
    _sendPort.send(_PdfRendererCancelRequest(_rendererId, _id));
  }
}

typedef _PdfRendererCancellationTokenId = int;

/// Opaque id for a worker-side [PdfPageRenderer].
///
/// A [PdfPageAsyncRenderer] stores this id so every render/cache/dispose
/// message can identify which document renderer in the shared worker should
/// handle the request. Cancellation uses this together with
/// [_PdfRendererCancellationTokenId] so queued jobs from different documents do
/// not collide.
typedef _PdfRendererId = int;

class _PdfRendererRenderParams {
  const _PdfRendererRenderParams({
    required this.annotations,
    required this.backgroundColor,
    required this.height,
    required this.pageNumber,
    required this.pixelRatio,
    required this.width,
    required this.x,
    required this.y,
  });

  final bool annotations;
  final int backgroundColor;
  final int height;
  final int pageNumber;
  final double pixelRatio;
  final int width;
  final double x;
  final double y;
}

abstract class _PdfRendererWorkerRequest<R> {
  const _PdfRendererWorkerRequest({this.rendererId, this.cancellationTokenId});

  // Null only for worker-level requests such as opening a new document or
  // stopping the worker. Renderer-specific requests must carry the id returned
  // by _PdfRendererOpenResult.
  final _PdfRendererId? rendererId;
  final _PdfRendererCancellationTokenId? cancellationTokenId;

  R run(_PdfRendererWorkerState state);

  _PdfRendererBoundRequest<R> bind(SendPort sendPort) =>
      _PdfRendererBoundRequest<R>(sendPort, this);
}

class _PdfRendererBoundRequest<R> {
  const _PdfRendererBoundRequest(this.sendPort, this.request);

  final SendPort sendPort;
  final _PdfRendererWorkerRequest<R> request;

  void execute(_PdfRendererWorkerState state) {
    try {
      sendPort.send(request.run(state));
    } catch (error, stackTrace) {
      sendPort.send(
        _PdfRendererCallError(error.toString(), stackTrace.toString()),
      );
    }
  }

  bool cancelIfQueued(_PdfRendererCancelRequest cancel) {
    if (request.rendererId != cancel.rendererId ||
        request.cancellationTokenId != cancel.cancellationTokenId) {
      return false;
    }
    sendPort.send(const _PdfRendererCallCanceled());
    return true;
  }
}

class _PdfRendererOpenRequest
    extends _PdfRendererWorkerRequest<_PdfRendererOpenResult> {
  const _PdfRendererOpenRequest(
    this.documentBytes,
    this.password,
    this.maxDownscaledImagePixels,
  );

  final TransferableTypedData documentBytes;
  final String password;
  final int? maxDownscaledImagePixels;

  @override
  _PdfRendererOpenResult run(_PdfRendererWorkerState state) =>
      state.open(documentBytes, password, maxDownscaledImagePixels);
}

class _PdfRendererOpenResult {
  const _PdfRendererOpenResult(this.rendererId, this.pageSizes);

  final _PdfRendererId rendererId;
  final List<PdfPageSize> pageSizes;
}

class _PdfRendererRenderRequest
    extends _PdfRendererWorkerRequest<TransferableTypedData> {
  const _PdfRendererRenderRequest(
    _PdfRendererId rendererId,
    this.params, {
    super.cancellationTokenId,
  }) : super(rendererId: rendererId);

  final _PdfRendererRenderParams params;

  @override
  TransferableTypedData run(_PdfRendererWorkerState state) {
    final bgra = _debugTimeSync(
      'renderBgraRegion '
      'page=${params.pageNumber} '
      'region=${params.x.toStringAsFixed(1)},'
      '${params.y.toStringAsFixed(1)} '
      '${params.width}x${params.height} '
      'pixelRatio=${params.pixelRatio.toStringAsFixed(3)}',
      () => state
          .rendererFor(rendererId!)
          .renderBgraRegion(
            pageNumber: params.pageNumber,
            x: params.x,
            y: params.y,
            width: params.width,
            height: params.height,
            pixelRatio: params.pixelRatio,
            backgroundColor: params.backgroundColor,
            annotations: params.annotations,
          ),
    );
    return TransferableTypedData.fromList([bgra]);
  }
}

class _PdfRendererDisposeRequest extends _PdfRendererWorkerRequest<void> {
  const _PdfRendererDisposeRequest(_PdfRendererId rendererId)
    : super(rendererId: rendererId);

  @override
  void run(_PdfRendererWorkerState state) {
    state.renderers.remove(rendererId);
  }
}

class _PdfRendererClearDisplayListCacheRequest
    extends _PdfRendererWorkerRequest<void> {
  const _PdfRendererClearDisplayListCacheRequest(
    _PdfRendererId rendererId, {
    this.pageNumber,
    this.annotations,
  }) : super(rendererId: rendererId);

  final int? pageNumber;
  final bool? annotations;

  @override
  void run(_PdfRendererWorkerState state) {
    state
        .rendererFor(rendererId!)
        .clearDisplayListCache(
          pageNumber: pageNumber,
          annotations: annotations,
        );
  }
}

class _PdfRendererStopRequest extends _PdfRendererBoundRequest<void> {
  _PdfRendererStopRequest(SendPort sendPort)
    : super(sendPort, const _PdfRendererStopWorkerRequest());
}

class _PdfRendererStopWorkerRequest extends _PdfRendererWorkerRequest<void> {
  const _PdfRendererStopWorkerRequest();

  @override
  void run(_PdfRendererWorkerState state) {
    state.stop();
  }
}

class _PdfRendererCallError {
  const _PdfRendererCallError(this.error, this.stackTrace);

  final String error;
  final String stackTrace;
}

class _PdfRendererCallCanceled {
  const _PdfRendererCallCanceled();
}

class _PdfRendererCancelRequest {
  const _PdfRendererCancelRequest(this.rendererId, this.cancellationTokenId);

  final _PdfRendererId rendererId;
  final _PdfRendererCancellationTokenId cancellationTokenId;
}
