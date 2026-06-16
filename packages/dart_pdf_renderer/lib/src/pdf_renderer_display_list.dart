part of 'pdf_renderer.dart';

class _PdfPageDisplayList {
  const _PdfPageDisplayList(this.commands);

  final List<PdfDisplayCommand> commands;

  void replay(PdfDirectPdfDevice device, PdfDisplayRect visibleBounds) {
    for (final command in commands) {
      if (command.shouldReplay(visibleBounds)) {
        final stopwatch = device.timing == null ? null : (Stopwatch()..start());
        command.replay(device);
        if (stopwatch != null) {
          stopwatch.stop();
          device.timing!._addCommandTime(
            command,
            stopwatch.elapsedMicroseconds,
          );
        }
      } else {
        device.timing?.culledCommands++;
      }
    }
  }
}

class _PdfPageDisplayListKey {
  const _PdfPageDisplayListKey(this.page, {required this.annotations});

  final _PdfPageCacheKey page;
  final bool annotations;

  @override
  bool operator ==(Object other) =>
      other is _PdfPageDisplayListKey &&
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
class _PdfPageCacheKey {
  const _PdfPageCacheKey(this.reference, this.dictionary);

  final cos.CosReference? reference;
  final cos.CosDictionary dictionary;

  @override
  bool operator ==(Object other) {
    if (other is! _PdfPageCacheKey) return false;
    final ref = reference;
    final otherRef = other.reference;
    if (ref != null || otherRef != null) return ref == otherRef;
    return identical(dictionary, other.dictionary);
  }

  @override
  int get hashCode => reference?.hashCode ?? identityHashCode(dictionary);
}

Map<cos.CosStream, _ImageColorContext> _collectImageColorContexts(
  PdfPage page, {
  required bool annotations,
  required _ImageColorContext documentImageColorContext,
}) {
  final collector = _ImageColorContextCollector(
    page.document.cos,
    documentImageColorContext,
  );
  collector.walkPage(page);
  if (annotations) collector.walkAnnotations(page);
  return collector.imageContexts;
}

class _ImageColorContextCollector {
  _ImageColorContextCollector(this.cosDocument, this.documentImageColorContext);

  final cos.CosDocument cosDocument;
  final _ImageColorContext documentImageColorContext;
  final imageContexts = Map<cos.CosStream, _ImageColorContext>.identity();
  final _resourceContexts =
      Map<cos.CosDictionary, _ImageColorContext>.identity();
  final _visitedForms = <cos.CosStream>{};

  void walkPage(PdfPage page) {
    _walkOperations(
      ContentStreamParser.parse(page.contentBytes()),
      page.resources,
      _contextForResources(page.resources),
      0,
    );
  }

  void walkAnnotations(PdfPage page) {
    for (final annotation in page.annotations) {
      if (annotation.isHidden || annotation.isNoView) continue;
      if (annotation.subtype == 'Popup') continue;
      final form = annotation.normalAppearance;
      if (form == null) continue;
      _walkForm(form, page.resources, _contextForResources(page.resources), 0);
    }
  }

  _ImageColorContext _contextForResources(cos.CosDictionary resources) =>
      _resourceContexts.putIfAbsent(
        resources,
        () => _ImageColorContext.fromResources(
          cosDocument,
          resources,
          parent: documentImageColorContext,
        ),
      );

  void _walkOperations(
    List<ContentOperation> operations,
    cos.CosDictionary resources,
    _ImageColorContext context,
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
      final subtype = _nameValue(
        cosDocument.resolve(xObject.dictionary['Subtype']),
      );
      if (subtype == 'Image') {
        imageContexts.putIfAbsent(xObject, () => context);
      } else if (subtype == 'Form') {
        _walkForm(xObject, resources, context, depth + 1);
      }
    }
  }

  void _walkForm(
    cos.CosStream form,
    cos.CosDictionary outerResources,
    _ImageColorContext outerContext,
    int depth,
  ) {
    if (!_visitedForms.add(form)) return;
    final innerResources = cosDocument.resolve(form.dictionary['Resources']);
    final resources = innerResources is cos.CosDictionary
        ? innerResources
        : outerResources;
    final context = innerResources is cos.CosDictionary
        ? _contextForResources(innerResources)
        : outerContext;
    try {
      final content = cosDocument.decodeStreamData(form);
      _walkOperations(
        ContentStreamParser.parse(content),
        resources,
        context,
        depth,
      );
    } on Exception {
      return;
    }
  }
}
