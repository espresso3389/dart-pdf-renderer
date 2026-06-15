import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pdf_document/pdf_document.dart';

import 'pdf_renderer.dart';

/// An isolate-backed asynchronous PDF page renderer.
class PdfPageAsyncRenderer {
  PdfPageAsyncRenderer._(this._isolate, this._sendPort, this.pageSizes);

  final Isolate _isolate;
  final SendPort _sendPort;

  /// The page sizes in display coordinate order.
  final List<PdfPageSize> pageSizes;
  var _nextCancellationTokenId = 0;
  bool _disposed = false;

  /// Creates an asynchronous renderer from PDF [documentBytes].
  static Future<PdfPageAsyncRenderer> create(
    Uint8List documentBytes, {
    String password = '',
    int? maxDownscaledImagePixels,
  }) async {
    final readyPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      _PdfRendererWorkerInit(
        readyPort.sendPort,
        TransferableTypedData.fromList([documentBytes]),
        password,
        maxDownscaledImagePixels,
      ),
    );

    final ready = await readyPort.first;
    readyPort.close();
    if (ready is _PdfRendererWorkerReady) {
      final renderer = PdfPageAsyncRenderer._(
        isolate,
        ready.sendPort,
        ready.pageSizes,
      );
      return renderer;
    }
    isolate.kill(priority: Isolate.immediate);
    if (ready is _PdfRendererWorkerError) {
      throw StateError('${ready.error}\n${ready.stackTrace}');
    }
    throw StateError('Unexpected renderer worker initialization response.');
  }

  /// Creates a cancellation token for a future render request.
  PdfRenderCancellationToken createCancellationToken() =>
      PdfRenderCancellationToken._(_sendPort, _nextCancellationTokenId++);

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
    if (cancellationToken?.isCancelled ?? false) return null;
    final data =
        await _compute<_PdfRendererRenderParams, TransferableTypedData>(
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

  Future<R?> _compute<M, R>(
    _PdfRendererComputeCallback<M, R> callback,
    M message, {
    PdfRenderCancellationToken? cancellationToken,
  }) async {
    if (_disposed) {
      throw StateError('PdfPageAsyncRenderer is disposed.');
    }
    if (cancellationToken?.isCancelled ?? false) return null;

    final receivePort = ReceivePort();
    try {
      _sendPort.send(
        _PdfRendererComputeParams<M, R>(
          receivePort.sendPort,
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

  /// Stops the worker isolate and releases renderer resources.
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
      final bytes = init.documentBytes.materialize().asUint8List();
      final document = PdfDocument.open(bytes, password: init.password);
      final renderer = PdfPageRenderer(
        document,
        imageDecodeCache: PdfImageDecodeCache(
          maxDownscaledImagePixels: init.maxDownscaledImagePixels,
        ),
      );
      final state = _PdfRendererWorkerState(commandPort, renderer);
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

      init.readyPort.send(
        _PdfRendererWorkerReady(commandPort.sendPort, renderer.pageSizes),
      );
      commandPort.listen((message) {
        if (message is int) {
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
  const _PdfRendererWorkerInit(
    this.readyPort,
    this.documentBytes,
    this.password,
    this.maxDownscaledImagePixels,
  );

  final SendPort readyPort;
  final TransferableTypedData documentBytes;
  final String password;
  final int? maxDownscaledImagePixels;
}

class _PdfRendererWorkerReady {
  const _PdfRendererWorkerReady(this.sendPort, this.pageSizes);

  final SendPort sendPort;
  final List<PdfPageSize> pageSizes;
}

class _PdfRendererWorkerError {
  const _PdfRendererWorkerError(this.error, this.stackTrace);

  final String error;
  final String stackTrace;
}

class _PdfRendererWorkerState {
  _PdfRendererWorkerState(this.receivePort, this.renderer);

  final ReceivePort receivePort;
  final PdfPageRenderer renderer;
  var stopped = false;

  void stop() {
    stopped = true;
    receivePort.close();
  }
}

/// Cancellation token for queued asynchronous render requests.
class PdfRenderCancellationToken {
  PdfRenderCancellationToken._(this._sendPort, this._id);

  final SendPort _sendPort;
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
    _sendPort.send(_id);
  }
}

typedef _PdfRendererComputeCallback<M, R> =
    R Function(PdfPageRenderer renderer, M message);

typedef _PdfRendererCancellationTokenId = int;

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
  _PdfRendererWorkerMessage(this.sendPort, {this.cancellationTokenId});

  final SendPort sendPort;
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

  bool cancelIfQueued(_PdfRendererCancellationTokenId token) {
    if (cancellationTokenId != token) return false;
    sendPort.send(const _PdfRendererCallCanceled());
    return true;
  }
}

class _PdfRendererComputeParams<M, R> extends _PdfRendererWorkerMessage<R> {
  _PdfRendererComputeParams(
    super.sendPort,
    this.callback,
    this.message, {
    super.cancellationTokenId,
  });

  final _PdfRendererComputeCallback<M, R> callback;
  final M message;

  @override
  R run(_PdfRendererWorkerState state) => callback(state.renderer, message);
}

class _PdfRendererStopRequest extends _PdfRendererWorkerMessage<void> {
  _PdfRendererStopRequest(super.sendPort);

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
