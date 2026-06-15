# dart_pdf_renderer

A pure-Dart PDF page renderer with synchronous and isolate-backed asynchronous
APIs.

The package is intentionally independent from pdfrx and `pdfrx_engine`.
PDFium comparison tools live in the sibling
`dart_pdf_renderer_debugging_tools` package.

The scripts under `tool/source_gen/` document how PDFium-derived CMYK fallback
code in `lib/src/pdfium_cmyk.dart` was generated and checked.
