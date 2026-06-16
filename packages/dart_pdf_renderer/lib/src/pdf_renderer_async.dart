import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pdf_document/pdf_document.dart';

import 'pdf_renderer.dart';

/// An isolate-backed asynchronous PDF page renderer.
class PdfPageAsyncRenderer {
  PdfPageAsyncRenderer._(this._worker, this._rendererId, this.pageSizes);

  final PdfPageAsyncRendererWorker _worker;
  final _PdfRendererId _rendererId;

  /// The page sizes in display coordinate order.
  final List<PdfPageSize> pageSizes;
  var _nextCancellationTokenId = 0;
  bool _disposed = false;

  /// Creates a cancellation token for a future render request.
  PdfRenderCancellationToken createCancellationToken() =>
      PdfRenderCancellationToken._(
        _worker._sendPort,
        _rendererId,
        _nextCancellationTokenId++,
      );

  /// Renders a page region to BGRA pixels on the worker isolate.
  ///
  /// Returns `null` when [cancellationToken] is cancelled before the render
  /// starts.
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
    if (_disposed) {
      throw StateError('PdfPageAsyncRenderer is disposed.');
    }
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
    final data = await _worker
        ._compute<_PdfRendererRenderParams, TransferableTypedData>(
          _rendererId,
          (renderer, params) {
            final bgra = _debugTimeSync(
              'renderBgraRegion '
              'page=${params.pageNumber} '
              'region=${params.x.toStringAsFixed(1)},'
              '${params.y.toStringAsFixed(1)} '
              '${params.width}x${params.height} '
              'pixelRatio=${params.pixelRatio.toStringAsFixed(3)}',
              () => renderer.renderBgraRegion(
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
          },
          (
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
  Future<void> clearDisplayListCache({int? pageNumber, bool? annotations}) {
    _checkNotDisposed();
    return _worker._clearDisplayListCache(
      _rendererId,
      pageNumber: pageNumber,
      annotations: annotations,
    );
  }

  /// Removes cached display lists for a single 1-based page.
  Future<void> clearPageCache(int pageNumber, {bool? annotations}) {
    return clearDisplayListCache(
      pageNumber: pageNumber,
      annotations: annotations,
    );
  }

  /// Releases this document renderer from its worker.
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
class PdfPageAsyncRendererWorker {
  PdfPageAsyncRendererWorker._(this._isolate, this._sendPort);

  final Isolate _isolate;
  final SendPort _sendPort;
  bool _disposed = false;

  /// Starts a renderer worker isolate.
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
  Future<PdfPageAsyncRenderer> openData(
    Uint8List documentBytes, {
    String password = '',
    int? maxDownscaledImagePixels,
  }) async {
    if (_disposed) {
      throw StateError('PdfPageAsyncRendererWorker is disposed.');
    }
    final receivePort = ReceivePort();
    try {
      _sendPort.send(
        _PdfRendererOpenRequest(
          receivePort.sendPort,
          TransferableTypedData.fromList([documentBytes]),
          password,
          maxDownscaledImagePixels,
        ),
      );
      final response = await receivePort.first;
      if (response is _PdfRendererCallError) {
        throw StateError('${response.error}\n${response.stackTrace}');
      }
      response as _PdfRendererOpenResult;
      return PdfPageAsyncRenderer._(
        this,
        response.rendererId,
        response.pageSizes,
      );
    } finally {
      receivePort.close();
    }
  }

  Future<R?> _compute<M, R>(
    _PdfRendererId rendererId,
    _PdfRendererComputeCallback<M, R> callback,
    M message, {
    PdfRenderCancellationToken? cancellationToken,
  }) async {
    if (_disposed) {
      throw StateError('PdfPageAsyncRendererWorker is disposed.');
    }
    if (cancellationToken?.isCancelled ?? false) return null;

    final receivePort = ReceivePort();
    try {
      _sendPort.send(
        _PdfRendererComputeParams<M, R>(
          receivePort.sendPort,
          rendererId,
          callback,
          message,
          cancellationTokenId: cancellationToken?._id,
        ),
      );
      cancellationToken?._markRequestSent();
      final response = await receivePort.first;
      if (response is _PdfRendererCallCanceled) return null;
      if (response is _PdfRendererCallError) {
        throw StateError('${response.error}\n${response.stackTrace}');
      }
      return response as R;
    } finally {
      receivePort.close();
    }
  }

  Future<void> _disposeRenderer(_PdfRendererId rendererId) async {
    if (_disposed) return;
    final receivePort = ReceivePort();
    try {
      _sendPort.send(
        _PdfRendererDisposeRequest(receivePort.sendPort, rendererId),
      );
      final response = await receivePort.first;
      if (response is _PdfRendererCallError) {
        throw StateError('${response.error}\n${response.stackTrace}');
      }
    } finally {
      receivePort.close();
    }
  }

  Future<void> _clearDisplayListCache(
    _PdfRendererId rendererId, {
    int? pageNumber,
    bool? annotations,
  }) async {
    if (_disposed) {
      throw StateError('PdfPageAsyncRendererWorker is disposed.');
    }
    final receivePort = ReceivePort();
    try {
      _sendPort.send(
        _PdfRendererClearDisplayListCacheRequest(
          receivePort.sendPort,
          rendererId,
          pageNumber: pageNumber,
          annotations: annotations,
        ),
      );
      final response = await receivePort.first;
      if (response is _PdfRendererCallError) {
        throw StateError('${response.error}\n${response.stackTrace}');
      }
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

  static void _workerMain(_PdfRendererWorkerInit init) {
    final commandPort = ReceivePort();
    try {
      final state = _PdfRendererWorkerState(commandPort);
      final queue = Queue<_PdfRendererWorkerMessage>();
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
        if (message is! _PdfRendererWorkerMessage) return;
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
  final renderers = <_PdfRendererId, PdfPageRenderer>{};
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

typedef _PdfRendererComputeCallback<M, R> =
    R Function(PdfPageRenderer renderer, M message);

typedef _PdfRendererCancellationTokenId = int;
typedef _PdfRendererId = int;

typedef _PdfRendererRenderParams = ({
  bool annotations,
  int backgroundColor,
  int height,
  int pageNumber,
  double pixelRatio,
  int width,
  double x,
  double y,
});

abstract class _PdfRendererWorkerMessage<R> {
  _PdfRendererWorkerMessage(
    this.sendPort,
    this.rendererId, {
    this.cancellationTokenId,
  });

  final SendPort sendPort;
  final _PdfRendererId? rendererId;
  final _PdfRendererCancellationTokenId? cancellationTokenId;

  R run(_PdfRendererWorkerState state);

  void execute(_PdfRendererWorkerState state) {
    try {
      sendPort.send(run(state));
    } catch (error, stackTrace) {
      sendPort.send(
        _PdfRendererCallError(error.toString(), stackTrace.toString()),
      );
    }
  }

  bool cancelIfQueued(_PdfRendererCancelRequest request) {
    if (rendererId != request.rendererId ||
        cancellationTokenId != request.cancellationTokenId) {
      return false;
    }
    sendPort.send(const _PdfRendererCallCanceled());
    return true;
  }
}

class _PdfRendererComputeParams<M, R> extends _PdfRendererWorkerMessage<R> {
  _PdfRendererComputeParams(
    super.sendPort,
    super.rendererId,
    this.callback,
    this.message, {
    super.cancellationTokenId,
  });

  final _PdfRendererComputeCallback<M, R> callback;
  final M message;

  @override
  R run(_PdfRendererWorkerState state) {
    final id = rendererId;
    final renderer = id == null ? null : state.renderers[id];
    if (renderer == null) {
      throw StateError('PdfPageAsyncRenderer is disposed.');
    }
    return callback(renderer, message);
  }
}

class _PdfRendererOpenRequest
    extends _PdfRendererWorkerMessage<_PdfRendererOpenResult> {
  _PdfRendererOpenRequest(
    SendPort sendPort,
    this.documentBytes,
    this.password,
    this.maxDownscaledImagePixels,
  ) : super(sendPort, null);

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

class _PdfRendererDisposeRequest extends _PdfRendererWorkerMessage<void> {
  _PdfRendererDisposeRequest(super.sendPort, super.rendererId);

  @override
  void run(_PdfRendererWorkerState state) {
    final id = rendererId;
    if (id != null) state.renderers.remove(id);
  }
}

class _PdfRendererClearDisplayListCacheRequest
    extends _PdfRendererWorkerMessage<void> {
  _PdfRendererClearDisplayListCacheRequest(
    super.sendPort,
    super.rendererId, {
    this.pageNumber,
    this.annotations,
  });

  final int? pageNumber;
  final bool? annotations;

  @override
  void run(_PdfRendererWorkerState state) {
    final id = rendererId;
    final renderer = id == null ? null : state.renderers[id];
    if (renderer == null) {
      throw StateError('PdfPageAsyncRenderer is disposed.');
    }
    renderer.clearDisplayListCache(
      pageNumber: pageNumber,
      annotations: annotations,
    );
  }
}

class _PdfRendererStopRequest extends _PdfRendererWorkerMessage<void> {
  _PdfRendererStopRequest(SendPort sendPort) : super(sendPort, null);

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
