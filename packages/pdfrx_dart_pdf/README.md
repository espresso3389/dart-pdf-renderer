# pdfrx_dart_pdf

`pdfrx_dart_pdf` is an experimental bridge that runs the `pdfrx` Flutter viewer
API on top of the pure-Dart PDF implementation provided by `dart_pdf_renderer`.

The package installs a custom `PdfrxEntryFunctions` implementation so existing
`pdfrx` widgets can open and render PDF documents through dart-pdf rather than
the default PDFium backend.

## Features

- Implements `PdfrxEntryFunctions` with dart-pdf backed document loading.
- Supports `PdfDocument.openData`, `openFile`, `openAsset`, `openCustom`, and
  file/HTTP(S) `openUri`.
- Adapts dart-pdf pages to `pdfrx.PdfDocument` and `pdfrx.PdfPage`.
- Renders pages through `dart_pdf_renderer.PdfPageRenderer` and converts the
  result to `pdfrx.PdfImage`.
- Includes a Flutter example based on the upstream `pdfrx` sample viewer.

## Getting Started

Add the package and its runtime dependencies:

```yaml
dependencies:
  pdfrx_dart_pdf:
    path: .
  pdfrx: ^2.4.4
  dart_pdf_renderer: ^0.1.0
  pdf_cos: ^0.1.0
  pdf_document: ^0.1.0
```

Then install the backend before using `pdfrx` document APIs or viewer widgets:

```dart
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfrx_dart_pdf/pdfrx_dart_pdf.dart';

void main() {
  pdfrxUseDartPdf();
  runApp(const MyApp());
}
```

## Usage

Use `pdfrx` normally after calling `pdfrxUseDartPdf()`:

```dart
class MyPdfView extends StatelessWidget {
  const MyPdfView({required this.data, super.key});

  final Uint8List data;

  @override
  Widget build(BuildContext context) {
    return PdfViewer.data(
      data,
      sourceName: 'document.pdf',
    );
  }
}
```

The example app under `example/` copies the upstream `pdfrx` sample viewer and
initializes this backend in `main()`.

```sh
cd example
flutter run
```

## Current Limitations

This is an adapter layer for evaluation. Some PDFium-specific features are not
available through the dart-pdf backend yet:

- Creating new documents through `pdfrx.PdfDocument.createNew`.
- Creating documents from JPEG data through `createFromJpegData`.
- Native document handles.
- Text extraction and link extraction currently return empty results.
- Page mutation and assembly are not implemented.

## License

MIT, matching `pdfrx`.
