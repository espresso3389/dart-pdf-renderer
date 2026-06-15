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

## Target Used So Far

- A representative local PDF with JPX images, ICC color spaces, text outlines,
  transparency groups, and luminosity soft masks.
- Main regression page: the chapter-opener page that exposed the soft-mask bug.
- Broader validation: the full document.

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

## Defect Fixed

### Soft Mask Rendered As Visible Content

The regression page showed a dark horizontal bar where PDFium rendered a pale
gradient bar. The trace showed a `fillPathGradient` event after clipping, and
resource inspection showed the gradient belonged to an `/SMask` luminosity mask:

- `/ExtGState /GS1`
- `/SMask`
- `/S /Luminosity`
- mask group with `/Group <</S /Transparency /CS /DeviceGray>>`
- nested form with axial `/Shading`

The renderer was calling `drawMask()` directly in `endSoftMasked`, so mask
commands were painted visibly onto the page. The fix was:

- record soft-mask drawing commands separately in the display list
- make direct rendering capture soft-masked content into an offscreen surface
- draw the mask into another offscreen surface
- convert mask luminance or alpha to an opacity value
- composite the captured content through that mask into the parent surface
- add axial gradient rasterization so luminosity masks based on axial shading
  can be evaluated instead of using a flat average color

Commit:

```text
76deeb6 Support soft mask compositing
```

Validation:

- `dart analyze`: passed
- `dart test` in `packages/dart_pdf_renderer`: passed
- focused regression crop: dark visible mask disappeared
- whole-PDF scan: chapter-opener horizontal bars no longer dominated the worst
  page list

## Remaining Differences On The Current PDF

### Text Outline Anti-Aliasing Drift

Several text-heavy pages rank high by average delta after the soft-mask fix.
Cropped comparisons show visually similar text, with differences concentrated
along glyph/path edges. The trace for a representative text crop showed only
path fills, not missing image or transparency operations. This is currently
classified as anti-aliasing/path rasterization drift rather than a functional
rendering defect.

### JPX + ICCBased Image Color / Sampling Drift

A representative cover/image page uses a large `JPXDecode` image with an
`ICCBased` color space. The image region differs on most pixels, but with low
average delta and no visible corruption. The renderer already enters the PDF
color-space path when JPX components match the PDF `ColorSpace`, so this is
currently classified as PDFium color-management and/or image-resampling drift
rather than a confirmed bug.

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
