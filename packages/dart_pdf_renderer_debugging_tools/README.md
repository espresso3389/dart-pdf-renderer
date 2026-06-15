# dart_pdf_renderer_debugging_tools

Debugging and renderer comparison tools for `dart_pdf_renderer`.

This package is intentionally separate from `dart_pdf_renderer` so the renderer
package does not depend on `pdfrx_engine` during normal development or tests.
The scripts under `tool/` may use PDFium through `pdfrx_engine` as a
development-time oracle.
