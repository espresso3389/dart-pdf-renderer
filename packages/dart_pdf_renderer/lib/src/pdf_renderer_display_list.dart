// ignore_for_file: unused_import, implementation_imports

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:image/src/formats/jpeg/jpeg_data.dart' as image_internal;
import 'package:pdf_cos/pdf_cos.dart' as cos;
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart' as graphics;
import 'pdf_display_command.dart';
import 'pdfium_cmyk.dart';
import 'pdf_renderer.dart';
import 'pdf_renderer_direct_device.dart';
import 'pdf_renderer_geometry.dart';
import 'pdf_renderer_glyph.dart';
import 'pdf_renderer_graphics.dart';
import 'pdf_renderer_image.dart';
import 'pdf_renderer_models.dart';
import 'pdf_renderer_recording_device.dart';

class PdfPageDisplayList {
  const PdfPageDisplayList(this.commands);

  final List<PdfDisplayCommand> commands;

  void replay(PdfDirectPdfDevice device, PdfDisplayRect visibleBounds) {
    for (final command in commands) {
      if (command.shouldReplay(visibleBounds)) {
        final stopwatch = device.timing == null ? null : (Stopwatch()..start());
        command.replay(device);
        if (stopwatch != null) {
          stopwatch.stop();
          device.timing!.addCommandTime(command, stopwatch.elapsedMicroseconds);
        }
      } else {
        device.timing?.culledCommands++;
      }
    }
  }
}

class PdfPageDisplayListKey {
  const PdfPageDisplayListKey(this.page, {required this.annotations});

  final PdfPageCacheKey page;
  final bool annotations;

  @override
  bool operator ==(Object other) =>
      other is PdfPageDisplayListKey &&
      other.page == page &&
      other.annotations == annotations;

  @override
  int get hashCode => Object.hash(page, annotations);
}

/// Stable identity for a page cache entry.
///
/// Page numbers are deliberately not part of this key. For ordinary indirect
/// pages, the object reference survives page reordering and is the strongest
/// identity we have. For direct page dictionaries, object identity is the
/// fallback. If editing replaces a page dictionary with a new object, it gets a
/// new cache key and old entries can be evicted normally.
class PdfPageCacheKey {
  const PdfPageCacheKey(this.reference, this.dictionary);

  final cos.CosReference? reference;
  final cos.CosDictionary dictionary;

  @override
  bool operator ==(Object other) {
    if (other is! PdfPageCacheKey) return false;
    final ref = reference;
    final otherRef = other.reference;
    if (ref != null || otherRef != null) return ref == otherRef;
    return identical(dictionary, other.dictionary);
  }

  @override
  int get hashCode => reference?.hashCode ?? identityHashCode(dictionary);
}

Map<cos.CosStream, ImageColorContext> collectImageColorContexts(
  PdfPage page, {
  required bool annotations,
  required ImageColorContext documentImageColorContext,
}) {
  final collector = ImageColorContextCollector(
    page.document.cos,
    documentImageColorContext,
  );
  collector.walkPage(page);
  if (annotations) collector.walkAnnotations(page);
  return collector.imageContexts;
}

class ImageColorContextCollector {
  ImageColorContextCollector(this.cosDocument, this.documentImageColorContext);

  final cos.CosDocument cosDocument;
  final ImageColorContext documentImageColorContext;
  final imageContexts = Map<cos.CosStream, ImageColorContext>.identity();
  final resourceContexts = Map<cos.CosDictionary, ImageColorContext>.identity();
  final visitedForms = <cos.CosStream>{};

  void walkPage(PdfPage page) {
    walkOperations(
      graphics.ContentStreamParser.parse(page.contentBytes()),
      page.resources,
      contextForResources(page.resources),
      0,
    );
  }

  void walkAnnotations(PdfPage page) {
    for (final annotation in page.annotations) {
      if (annotation.isHidden || annotation.isNoView) continue;
      if (annotation.subtype == 'Popup') continue;
      final form = annotation.normalAppearance;
      if (form == null) continue;
      walkForm(form, page.resources, contextForResources(page.resources), 0);
    }
  }

  ImageColorContext contextForResources(cos.CosDictionary resources) =>
      resourceContexts.putIfAbsent(
        resources,
        () => ImageColorContext.fromResources(
          cosDocument,
          resources,
          parent: documentImageColorContext,
        ),
      );

  void walkOperations(
    List<graphics.ContentOperation> operations,
    cos.CosDictionary resources,
    ImageColorContext context,
    int depth,
  ) {
    if (depth > 16) return;
    for (final operation in operations) {
      if (operation.operator != 'Do' || operation.operands.isEmpty) continue;
      final name = operation.operands.last;
      if (name is! cos.CosName) continue;
      final xObjectGroup = cosDocument.resolve(resources['XObject']);
      if (xObjectGroup is! cos.CosDictionary) continue;
      final xObject = cosDocument.resolve(xObjectGroup[name.value]);
      if (xObject is! cos.CosStream) continue;
      final subtype = nameValue(
        cosDocument.resolve(xObject.dictionary['Subtype']),
      );
      if (subtype == 'Image') {
        imageContexts.putIfAbsent(xObject, () => context);
      } else if (subtype == 'Form') {
        walkForm(xObject, resources, context, depth + 1);
      }
    }
  }

  void walkForm(
    cos.CosStream form,
    cos.CosDictionary outerResources,
    ImageColorContext outerContext,
    int depth,
  ) {
    if (!visitedForms.add(form)) return;
    final innerResources = cosDocument.resolve(form.dictionary['Resources']);
    final resources = innerResources is cos.CosDictionary
        ? innerResources
        : outerResources;
    final context = innerResources is cos.CosDictionary
        ? contextForResources(innerResources)
        : outerContext;
    try {
      final content = cosDocument.decodeStreamData(form);
      walkOperations(
        graphics.ContentStreamParser.parse(content),
        resources,
        context,
        depth,
      );
    } on Exception {
      return;
    }
  }
}
