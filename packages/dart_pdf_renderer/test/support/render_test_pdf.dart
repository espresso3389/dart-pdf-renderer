import 'dart:convert';
import 'dart:typed_data';

Uint8List imageXObjectPdf(
  String imageDictionary,
  List<int> imageData, {
  String extraCatalogEntries = '',
  String extraPageResources = '',
  List<TestPdfDictionaryObject> extraDictionaryObjects = const [],
  List<TestPdfStreamObject> extraObjects = const [],
}) {
  final out = BytesBuilder();
  final offsets = <int, int>{};

  void addAscii(String value) => out.add(latin1.encode(value));

  void addObject(int id, List<int> body) {
    offsets[id] = out.length;
    addAscii('$id 0 obj\n');
    out.add(body);
    addAscii('\nendobj\n');
  }

  List<int> ascii(String value) => latin1.encode(value);

  List<int> streamObject(String dictionary, List<int> stream) {
    final body = BytesBuilder()
      ..add(ascii('$dictionary\nstream\n'))
      ..add(stream)
      ..add(ascii('\nendstream'));
    return body.toBytes();
  }

  addAscii('%PDF-1.4\n');
  addObject(1, ascii('<< /Type /Catalog /Pages 2 0 R $extraCatalogEntries >>'));
  addObject(2, ascii('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'));
  addObject(
    3,
    ascii(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 16 16] '
      '/Resources << /XObject << /Im0 4 0 R >> $extraPageResources >> '
      '/Contents 5 0 R >>',
    ),
  );
  addObject(4, streamObject(imageDictionary, imageData));
  final content = ascii('q\n16 0 0 16 0 0 cm\n/Im0 Do\nQ\n');
  addObject(5, streamObject('<< /Length ${content.length} >>', content));
  for (final object in extraDictionaryObjects) {
    addObject(object.id, ascii(object.dictionary));
  }
  for (final object in extraObjects) {
    addObject(object.id, streamObject(object.dictionary, object.stream));
  }

  final xrefOffset = out.length;
  final maxObjectId = offsets.keys.reduce((a, b) => a > b ? a : b);
  addAscii('xref\n0 ${maxObjectId + 1}\n');
  addAscii('0000000000 65535 f \n');
  for (var id = 1; id <= maxObjectId; id++) {
    final offset = offsets[id];
    if (offset == null) {
      addAscii('0000000000 65535 f \n');
    } else {
      addAscii('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }
  }
  addAscii(
    'trailer\n<< /Size ${maxObjectId + 1} /Root 1 0 R >>\n'
    'startxref\n$xrefOffset\n%%EOF\n',
  );
  return out.toBytes();
}

Uint8List singlePageContentPdf(String content) {
  final out = BytesBuilder();
  final offsets = <int, int>{};

  void addAscii(String value) => out.add(latin1.encode(value));

  void addObject(int id, List<int> body) {
    offsets[id] = out.length;
    addAscii('$id 0 obj\n');
    out.add(body);
    addAscii('\nendobj\n');
  }

  List<int> ascii(String value) => latin1.encode(value);

  List<int> streamObject(String dictionary, List<int> stream) {
    final body = BytesBuilder()
      ..add(ascii('$dictionary\nstream\n'))
      ..add(stream)
      ..add(ascii('\nendstream'));
    return body.toBytes();
  }

  final contentBytes = ascii(content);
  addAscii('%PDF-1.4\n');
  addObject(1, ascii('<< /Type /Catalog /Pages 2 0 R >>'));
  addObject(2, ascii('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'));
  addObject(
    3,
    ascii(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 16 16] '
      '/Resources << >> /Contents 4 0 R >>',
    ),
  );
  addObject(
    4,
    streamObject('<< /Length ${contentBytes.length} >>', contentBytes),
  );

  final xrefOffset = out.length;
  addAscii('xref\n0 5\n');
  addAscii('0000000000 65535 f \n');
  for (var id = 1; id <= 4; id++) {
    addAscii('${offsets[id].toString().padLeft(10, '0')} 00000 n \n');
  }
  addAscii(
    'trailer\n<< /Size 5 /Root 1 0 R >>\n'
    'startxref\n$xrefOffset\n%%EOF\n',
  );
  return out.toBytes();
}

class TestPdfStreamObject {
  const TestPdfStreamObject(this.id, this.dictionary, this.stream);

  final int id;
  final String dictionary;
  final List<int> stream;
}

class TestPdfDictionaryObject {
  const TestPdfDictionaryObject(this.id, this.dictionary);

  final int id;
  final String dictionary;
}

Uint8List constantCmykXyzIccProfile(List<int> xyzBytes) {
  final bytes = Uint8List(2032);
  final data = ByteData.sublistView(bytes);

  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes[offset + i] = value.codeUnitAt(i);
    }
  }

  data.setUint32(0, bytes.length);
  ascii(16, 'CMYK');
  ascii(20, 'XYZ ');
  data.setUint32(128, 1);
  ascii(132, 'A2B0');
  data.setUint32(136, 144);
  data.setUint32(140, 1888);

  const lutOffset = 144;
  ascii(lutOffset, 'mft1');
  bytes[lutOffset + 8] = 4; // input channels
  bytes[lutOffset + 9] = 3; // output channels
  bytes[lutOffset + 10] = 2; // grid points

  var p = lutOffset + 48;
  for (var channel = 0; channel < 4; channel++) {
    for (var i = 0; i < 256; i++) {
      bytes[p++] = i;
    }
  }
  for (var i = 0; i < 16; i++) {
    bytes[p++] = xyzBytes[0];
    bytes[p++] = xyzBytes[1];
    bytes[p++] = xyzBytes[2];
  }
  for (var channel = 0; channel < 3; channel++) {
    for (var i = 0; i < 256; i++) {
      bytes[p++] = i;
    }
  }
  return bytes;
}
