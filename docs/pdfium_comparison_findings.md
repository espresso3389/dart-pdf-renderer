# PDFium Comparison Findings

This file records renderer issues and follow-up findings discovered by PDFium
comparison. Keep entries free of local absolute paths, private directory names,
and specific personal PDF file names.

## Fixed Issues

### Soft Mask Rendered As Visible Content

- Status: fixed
- Commit: `76deeb6 Support soft mask compositing`
- Area: `packages/dart_pdf_renderer`
- Feature: luminosity soft masks, transparency groups, axial shading

A regression page showed a dark horizontal bar where PDFium rendered a pale
gradient bar. The render trace showed a `fillPathGradient` event after clipping,
and resource inspection showed that the gradient belonged to an `/SMask`
luminosity mask rather than normal page content.

The broken behavior was that `endSoftMasked` called `drawMask()` directly, so
mask commands were painted visibly onto the page.

The fix:

- records soft-mask drawing commands separately in the display list
- captures soft-masked content into an offscreen surface
- draws the mask into a separate offscreen surface
- converts mask luminance or alpha to opacity
- composites the captured content through that mask into the parent surface
- rasterizes axial gradients so luminosity masks based on axial shading can be
  evaluated instead of using a flat average color

Validation:

- `dart analyze`: passed
- `dart test` in `packages/dart_pdf_renderer`: passed
- focused regression crop: visible mask disappeared
- whole-document scan: the affected chapter-opener pages no longer dominated
  the worst-page list

## Classified Non-Defect Or Follow-Up Findings

### Text Outline Anti-Aliasing Drift

- Status: classified, not fixed
- Area: path filling / glyph outline rasterization

Several text-heavy pages rank high by average delta after the soft-mask fix.
Cropped comparisons show visually similar text, with differences concentrated
along glyph or path edges. Representative traces show path fills rather than
missing images or transparency operations.

Current classification: anti-aliasing or path-rasterization drift, not a
confirmed functional rendering defect.

### JPX + ICCBased Image Color / Sampling Drift

- Status: classified, not fixed
- Area: image color conversion / image resampling

A representative cover or image-heavy page uses a large `JPXDecode` image with
an `ICCBased` color space. The image region differs on most pixels, but with
low average delta and no visible corruption.

The renderer enters the PDF color-space path when JPX components match the PDF
`ColorSpace`, so this is currently classified as PDFium color-management and/or
image-resampling drift rather than a confirmed renderer bug.

## Entry Template

### Short Problem Name

- Status: fixed | investigating | classified, not fixed
- Commit: `<sha> <subject>` if fixed
- Area: affected package or renderer subsystem
- Feature: PDF feature or renderer behavior

Summary of the symptom, root cause, fix, and validation. Do not include local
absolute paths or private PDF filenames.
