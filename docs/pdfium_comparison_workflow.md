# PDFium Comparison Workflow

This note records the workflow used to compare the pure Dart renderer against
PDFium, investigate divergences, and fix renderer defects.

## Documentation Privacy

Do not commit local absolute paths, private directory names, or specific
personal PDF file names to repository documentation. Use neutral placeholders
such as `<pdf-file>`, `<pdf-dir>`, `<page>`, and `<out-dir>` instead.

Concrete local filenames can be used in terminal commands while investigating,
but they should stay in local logs, temporary notes, or chat context and should
not become part of committed repository files.

## Tools

Run these commands from
`packages/dart_pdf_renderer_debugging_tools`.

### Compare A Region

```powershell
dart run tool\compare_renderers.dart `
  "<pdf-file>" `
  <page> <left> <top> <right> <bottom> <scale> <out-prefix> `
  --trace --trace-limit 200 --hotspots 10
```

Use this when a suspicious page or region is known. It writes three PNGs:

- `*.dart_pdf.png`
- `*.pdfium.png`
- `*.diff.png`

It also prints trace events and hotspot coordinates.

### Scan A Whole PDF

```powershell
dart run tool\scan_render_diffs.dart `
  "<pdf-file>" `
  --scale 1 --threshold 20 --top 20 --write-worst 10 --out <out-dir>
```

Use this after a local fix to make sure the previous worst pages no longer
dominate the ranking and to discover the next class of divergence.

### Inspect Page Resources

```powershell
dart run tool\inspect_page_resources.dart `
  "<pdf-file>" `
  <page>
```

Use this to inspect page-level resources such as `ExtGState`, `Pattern`,
`Shading`, and `ColorSpace`.

### Inspect Used Images

```powershell
dart run tool\inspect_page_images.dart `
  "<pdf-file>" `
  --pages <page-or-range> --details
```

Use this when the remaining difference is image-wide color or sampling drift.

## Investigation Pattern

1. Run a whole-PDF scan against PDFium.
2. Pick the worst pages by average delta and inspect their hotspots.
3. Compare a tight crop around the hotspot with tracing enabled.
4. Classify the difference:
   - catastrophic image corruption
   - missing rendering feature
   - incorrect compositing or transparency semantics
   - color management / image resampling drift
   - text outline anti-aliasing drift
5. Use resource inspection to identify the PDF feature involved.
6. Fix only the confirmed renderer defect.
7. Run `dart format`, `dart analyze`, focused renderer tests, and the same
   PDFium comparison again.
8. Re-run the whole-PDF scan and compare the new worst-page list.
9. Commit and push each independently solved issue.
10. Remove temporary PNGs under `packages/dart_pdf_renderer_debugging_tools/tmp`
    before committing.

## Batch Workflow For More PDFs

For a local directory of PDFs, use a two-phase process before parallel
implementation:

1. Parent scan phase:
   - enumerate PDFs
   - run PDFium comparison scans
   - record worst pages, hotspots, timings, filters, color spaces, and trace
     signatures
   - do not start code fixes during this phase
2. Parent triage phase:
   - group findings by likely root cause
   - identify duplicates across PDFs
   - order issues by severity and confidence
   - decide which issues are independent enough for parallel worktrees
3. Parallel fix phase:
   - create one git worktree/subagent per independent root cause
   - assign disjoint write scopes
   - require each worker to run focused PDFium comparisons
   - merge/integrate one solved issue at a time
   - commit and push after each solved issue

This avoids multiple workers fixing the same renderer defect from different
example PDFs.
