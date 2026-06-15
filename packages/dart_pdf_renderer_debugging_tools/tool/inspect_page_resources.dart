import 'dart:io';

import 'package:pdf_cos/pdf_cos.dart' as cos;
import 'package:pdf_document/pdf_document.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart run tool/inspect_page_resources.dart <pdf> <page>',
    );
    exitCode = 64;
    return;
  }
  final document = PdfDocument.open(File(args[0]).readAsBytesSync());
  final page = document.page(int.parse(args[1]) - 1);
  final resources = document.cos.resolve(page.resources);
  if (resources is! cos.CosDictionary) return;
  for (final key in ['ExtGState', 'Pattern', 'Shading', 'ColorSpace']) {
    final value = document.cos.resolve(resources[key]);
    stdout.writeln('$key: ${_describe(document.cos, value)}');
    if (value is cos.CosDictionary) {
      for (final entry in value.entries.entries) {
        stdout.writeln(
          '  /${entry.key}: ${_describe(document.cos, document.cos.resolve(entry.value))}',
        );
        final resolved = document.cos.resolve(entry.value);
        if (resolved is cos.CosDictionary) {
          for (final child in resolved.entries.entries) {
            stdout.writeln(
              '    /${child.key}: ${_describe(document.cos, document.cos.resolve(child.value))}',
            );
          }
        }
      }
    }
  }
}

String _describe(cos.CosDocument document, cos.CosObject? object) {
  if (object == null) return 'null';
  final resolved = document.resolve(object);
  return switch (resolved) {
    cos.CosName(:final value) => '/$value',
    cos.CosInteger(:final value) => '$value',
    cos.CosReal(:final value) => '$value',
    cos.CosBoolean(:final value) => '$value',
    cos.CosString(:final bytes) => 'string(${bytes.length})',
    cos.CosArray(:final items) =>
      '[${items.map((e) => _describe(document, e)).join(' ')}]',
    cos.CosStream(:final dictionary, :final rawBytes) =>
      'stream(${rawBytes.length} bytes ${_describe(document, dictionary)})',
    cos.CosDictionary(:final entries) =>
      '<<${entries.entries.map((e) => '/${e.key} ${_describe(document, e.value)}').join(' ')}>>',
    _ => resolved.toString(),
  };
}
