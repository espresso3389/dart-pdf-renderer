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
    final data = await _worker._runOnRendererCancelable<TransferableTypedData>(
      _rendererId,
      (renderer) {
        final bgra = _debugTimeSync(
          'renderBgraRegion '
          'page=$pageNumber '
          'region=${x.toStringAsFixed(1)},${y.toStringAsFixed(1)} '
          '${width}x$height '
          'pixelRatio=${pixelRatio.toStringAsFixed(3)}',
          () => renderer.renderBgraRegion(
            pageNumber: pageNumber,
            x: x,
            y: y,
            width: width,
            height: height,
            pixelRatio: pixelRatio,
            backgroundColor: backgroundColor,
            annotations: annotations,
          ),
        );
        return TransferableTypedData.fromList([bgra]);
      },
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
    return _worker._runOnRenderer<void>(
      _rendererId,
      (renderer) => renderer.clearDisplayListCache(
        pageNumber: pageNumber,
        annotations: annotations,
      ),
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
    await _worker._run<void>((state) {
      state.renderers.remove(_rendererId);
    });
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
    final isolate = await Isolate.spawn(_workerMain, readyPort.sendPort);

    final ready = await readyPort.first;
    readyPort.close();
    if (ready is SendPort) {
      return PdfPageAsyncRendererWorker._(isolate, ready);
    }
    isolate.kill(priority: Isolate.immediate);
    if (ready is _WorkerError) {
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
    final result = await _run<_OpenResult>(
      (state) => state.open(
        TransferableTypedData.fromList([documentBytes]),
        password,
        maxDownscaledImagePixels,
      ),
    );
    return PdfPageAsyncRenderer._(this, result.rendererId, result.pageSizes);
  }

  Future<R> _runOnRenderer<R>(
    _PdfRendererId rendererId,
    R Function(PdfPageRenderer renderer) callback,
  ) {
    return _run<R>(
      (state) => callback(state.rendererFor(rendererId)),
      rendererId: rendererId,
    );
  }

  Future<R?> _runOnRendererCancelable<R>(
    _PdfRendererId rendererId,
    R Function(PdfPageRenderer renderer) callback, {
    PdfRenderCancellationToken? cancellationToken,
  }) {
    return _runCancelable<R>(
      (state) => callback(state.rendererFor(rendererId)),
      rendererId: rendererId,
      cancellationToken: cancellationToken,
    );
  }

  Future<R> _run<R>(
    R Function(_PdfRendererWorkerState state) callback, {
    _PdfRendererId? rendererId,
  }) async {
    _checkNotDisposed();
    final receivePort = ReceivePort();
    try {
      _sendPort.send((
        sendPort: receivePort.sendPort,
        rendererId: rendererId,
        cancellationTokenId: null,
        callback: callback,
      ));
      final response = await receivePort.first;
      if (response is _WorkerError) {
        throw StateError('${response.error}\n${response.stackTrace}');
      }
      return response as R;
    } finally {
      receivePort.close();
    }
  }

  Future<R?> _runCancelable<R>(
    R Function(_PdfRendererWorkerState state) callback, {
    _PdfRendererId? rendererId,
    PdfRenderCancellationToken? cancellationToken,
  }) async {
    _checkNotDisposed();
    if (cancellationToken?.isCancelled ?? false) return null;
    final receivePort = ReceivePort();
    try {
      _sendPort.send((
        sendPort: receivePort.sendPort,
        rendererId: rendererId,
        cancellationTokenId: cancellationToken?._id,
        callback: callback,
      ));
      cancellationToken?._markRequestSent();
      final response = await receivePort.first;
      if (response is _WorkerCanceled) return null;
      if (response is _WorkerError) {
        throw StateError('${response.error}\n${response.stackTrace}');
      }
      return response as R;
    } finally {
      receivePort.close();
    }
  }

  /// Stops the worker isolate and releases all renderer resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final receivePort = ReceivePort();
    try {
      _sendPort.send((
        sendPort: receivePort.sendPort,
        rendererId: null,
        cancellationTokenId: null,
        callback: (_PdfRendererWorkerState state) {
          state.stop();
        },
      ));
      final response = await receivePort.first;
      if (response is _WorkerError) {
        throw StateError('${response.error}\n${response.stackTrace}');
      }
    } finally {
      receivePort.close();
      _isolate.kill(priority: Isolate.beforeNextEvent);
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('PdfPageAsyncRendererWorker is disposed.');
    }
  }

  static void _workerMain(SendPort readyPort) {
    final commandPort = ReceivePort();
    try {
      final state = _PdfRendererWorkerState(commandPort);
      final queue = Queue<_WorkerJob>();
      var scheduled = false;

      void scheduleNext() {
        if (scheduled || state.stopped) return;
        scheduled = true;
        Timer.run(() {
          scheduled = false;
          if (state.stopped || queue.isEmpty) return;
          _executeJob(queue.removeFirst(), state);
          if (!state.stopped && queue.isNotEmpty) scheduleNext();
        });
      }

      readyPort.send(commandPort.sendPort);
      commandPort.listen((message) {
        if (message is _CancelJob) {
          queue.removeWhere((job) => _cancelIfQueued(job, message));
          return;
        }
        if (state.stopped) return;
        if (message is! _WorkerJob) return;
        queue.add(message);
        scheduleNext();
      });
    } catch (error, stackTrace) {
      commandPort.close();
      readyPort.send((
        error: error.toString(),
        stackTrace: stackTrace.toString(),
      ));
    }
  }
}

void _executeJob(_WorkerJob job, _PdfRendererWorkerState state) {
  try {
    job.sendPort.send(job.callback(state));
  } catch (error, stackTrace) {
    job.sendPort.send((
      error: error.toString(),
      stackTrace: stackTrace.toString(),
    ));
  }
}

bool _cancelIfQueued(_WorkerJob job, _CancelJob cancel) {
  if (job.rendererId != cancel.rendererId ||
      job.cancellationTokenId != cancel.cancellationTokenId) {
    return false;
  }
  job.sendPort.send((canceled: true));
  return true;
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

  _OpenResult open(
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
    return (rendererId: id, pageSizes: renderer.pageSizes);
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
    _sendPort.send((rendererId: _rendererId, cancellationTokenId: _id));
  }
}

typedef _PdfRendererCancellationTokenId = int;

/// Opaque id for a worker-side [PdfPageRenderer].
///
/// A [PdfPageAsyncRenderer] stores this id so every render/cache/dispose
/// callback can identify which document renderer in the shared worker should
/// handle the request. Cancellation uses this together with
/// [_PdfRendererCancellationTokenId] so queued jobs from different documents do
/// not collide.
typedef _PdfRendererId = int;

typedef _WorkerJob = ({
  SendPort sendPort,
  _PdfRendererId? rendererId,
  _PdfRendererCancellationTokenId? cancellationTokenId,
  Object? Function(_PdfRendererWorkerState state) callback,
});

typedef _CancelJob = ({
  _PdfRendererId rendererId,
  _PdfRendererCancellationTokenId cancellationTokenId,
});

typedef _WorkerError = ({String error, String stackTrace});
typedef _WorkerCanceled = ({bool canceled});
typedef _OpenResult = ({
  _PdfRendererId rendererId,
  List<PdfPageSize> pageSizes,
});
