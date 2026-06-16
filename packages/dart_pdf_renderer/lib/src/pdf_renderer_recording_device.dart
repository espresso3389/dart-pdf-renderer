part of 'pdf_renderer.dart';

class _RecordingPdfDevice implements PdfDevice {
  _RecordingPdfDevice({
    required this.transform,
    required this.imageColorContexts,
    required this.documentImageColorContext,
  });

  final PdfMatrix transform;
  final Map<cos.CosStream, _ImageColorContext> imageColorContexts;
  final _ImageColorContext documentImageColorContext;
  final _commandStack = <List<PdfDisplayCommand>>[<PdfDisplayCommand>[]];

  List<PdfDisplayCommand> get commands => _commandStack.first;

  void _addCommand(PdfDisplayCommand command) {
    _commandStack.last.add(command);
  }

  @override
  void save() {
    _addCommand(const PdfSaveCommand());
  }

  @override
  void restore() {
    _addCommand(const PdfRestoreCommand());
  }

  @override
  void fillPath(PdfPath path, PdfColor color, PdfFillRule rule, double alpha) {
    final transformed = _transformPath(path, transform);
    _addCommand(
      PdfFillPathCommand(
        transformed,
        color,
        rule,
        alpha,
        _pathBounds(transformed),
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
    final transformed = _transformPath(path, transform);
    _addCommand(
      PdfFillPathGradientCommand(
        transformed,
        rule,
        _transformGradient(gradient, transform),
        alpha,
        _pathBounds(transformed),
      ),
    );
  }

  @override
  void fillMesh(PdfMesh mesh, double alpha) {
    final transformed = _transformMesh(mesh, transform);
    _addCommand(
      PdfFillMeshCommand(transformed, alpha, _meshBounds(transformed)),
    );
  }

  @override
  void strokePath(
    PdfPath path,
    PdfColor color,
    PdfStroke stroke,
    double alpha,
  ) {
    final transformed = _transformPath(path, transform);
    final bounds = _pathBounds(transformed)?.inflate(stroke.width / 2 + 1);
    _addCommand(
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
    _addCommand(PdfClipPathCommand(_transformPath(path, transform), rule));
  }

  @override
  void drawText(PdfTextRun run) {
    final transformed = _transformTextRun(run, transform);
    if (run.invisible) {
      _addCommand(PdfDrawTextCommand(transformed, null));
      return;
    }
    _addCommand(
      PdfDrawTextCommand(transformed, _textRunBounds(transformed)?.inflate(2)),
    );
  }

  @override
  void drawImage(PdfImageRequest request) {
    final transformed = _transformImageDrawRequest(
      _ImageDrawRequest(
        request,
        imageColorContexts[request.stream] ?? documentImageColorContext,
      ),
      transform,
    );
    _addCommand(
      PdfDrawImageCommand(
        transformed,
        _imageRequestBounds(transformed.request),
      ),
    );
  }

  @override
  void setBlendMode(PdfBlendMode mode) {
    _addCommand(PdfSetBlendModeCommand(mode));
  }

  @override
  void beginGroup(double alpha, {bool knockout = false}) {
    _addCommand(PdfBeginGroupCommand(alpha, knockout: knockout));
  }

  @override
  void endGroup() {
    _addCommand(const PdfEndGroupCommand());
  }

  @override
  void beginSoftMasked() {
    _addCommand(const PdfBeginSoftMaskCommand());
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
    _commandStack.add(<PdfDisplayCommand>[]);
    drawMask();
    final maskCommands = List<PdfDisplayCommand>.unmodifiable(
      _commandStack.removeLast(),
    );
    _addCommand(
      PdfEndSoftMaskCommand(
        luminosity: luminosity,
        backdrop: _transformRect(backdrop, transform),
        maskCommands: maskCommands,
        backdropLuminance: backdropLuminance,
        transferScale: transferScale,
        transferOffset: transferOffset,
      ),
    );
  }
}

/// Cache for rasterized glyph masks.
