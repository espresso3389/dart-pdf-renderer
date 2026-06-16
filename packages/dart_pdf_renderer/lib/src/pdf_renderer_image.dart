part of 'pdf_renderer.dart';

const _defaultMaxDecodedImageCacheBytes = 64 * 1024 * 1024;
const _defaultMaxDecodedImageCacheEntries = 64;

class _ImageColorContext {
  _ImageColorContext._({
    required this.defaultGray,
    required this.defaultRgb,
    required this.defaultCmyk,
    required this.namedColorSpaces,
  }) : cacheKey = _nextCacheKey++;

  factory _ImageColorContext.fromDocument(cos.CosDocument cosDocument) {
    return _ImageColorContext._(
      defaultGray: null,
      defaultRgb: null,
      defaultCmyk: _outputIntentCmyk(cosDocument),
      namedColorSpaces: const {},
    );
  }

  factory _ImageColorContext.fromResources(
    cos.CosDocument cosDocument,
    cos.CosDictionary resources, {
    required _ImageColorContext parent,
  }) {
    final spaces = cosDocument.resolve(resources['ColorSpace']);
    if (spaces is! cos.CosDictionary) return parent;

    final namedColorSpaces = <String, cos.CosObject>{};
    for (final entry in spaces.entries.entries) {
      if (!_defaultColorSpaceNames.contains(entry.key)) {
        namedColorSpaces[entry.key] = entry.value;
      }
    }
    final namedContext = namedColorSpaces.isEmpty
        ? parent
        : _ImageColorContext._(
            defaultGray: parent.defaultGray,
            defaultRgb: parent.defaultRgb,
            defaultCmyk: parent.defaultCmyk,
            namedColorSpaces: namedColorSpaces,
          );

    _ImageColorSpace? defaultSpace(String name) {
      final object = spaces[name];
      if (object == null) return null;
      return _ImageColorSpace.parse(
        cosDocument,
        object,
        context: namedContext,
        useDeviceDefaults: false,
      );
    }

    if (namedColorSpaces.isEmpty &&
        spaces['DefaultGray'] == null &&
        spaces['DefaultRGB'] == null &&
        spaces['DefaultCMYK'] == null) {
      return parent;
    }

    return _ImageColorContext._(
      defaultGray: defaultSpace('DefaultGray') ?? parent.defaultGray,
      defaultRgb: defaultSpace('DefaultRGB') ?? parent.defaultRgb,
      defaultCmyk: defaultSpace('DefaultCMYK') ?? parent.defaultCmyk,
      namedColorSpaces: namedColorSpaces,
    );
  }

  static final device = _ImageColorContext._(
    defaultGray: null,
    defaultRgb: null,
    defaultCmyk: null,
    namedColorSpaces: const {},
  );

  static var _nextCacheKey = 1;

  final _ImageColorSpace? defaultGray;
  final _ImageColorSpace? defaultRgb;
  final _ImageColorSpace? defaultCmyk;
  final Map<String, cos.CosObject> namedColorSpaces;
  final int cacheKey;

  _ImageColorSpace? resolveNamed(
    cos.CosDocument cosDocument,
    String name, {
    bool useDeviceDefaults = true,
    Set<String>? resolvingNames,
  }) {
    final object = namedColorSpaces[name];
    if (object == null) return null;
    final resolving = resolvingNames ?? <String>{};
    if (!resolving.add(name)) return null;
    try {
      return _ImageColorSpace.parse(
        cosDocument,
        object,
        context: this,
        useDeviceDefaults: useDeviceDefaults,
        resolvingNames: resolving,
      );
    } finally {
      resolving.remove(name);
    }
  }
}

const _defaultColorSpaceNames = {'DefaultGray', 'DefaultRGB', 'DefaultCMYK'};

_ImageColorSpace? _outputIntentCmyk(cos.CosDocument cosDocument) {
  final root = cosDocument.resolve(cosDocument.trailer['Root']);
  if (root is! cos.CosDictionary) return null;
  final intents = cosDocument.resolve(root['OutputIntents']);
  final entries = switch (intents) {
    cos.CosArray(:final items) => items,
    cos.CosDictionary() => <cos.CosObject>[intents],
    _ => const <cos.CosObject>[],
  };
  for (final object in entries) {
    final intent = cosDocument.resolve(object);
    if (intent is! cos.CosDictionary) continue;
    final profile = cosDocument.resolve(intent['DestOutputProfile']);
    if (profile is! cos.CosStream) continue;
    final n = _intValue(cosDocument.resolve(profile.dictionary['N']));
    if (n != 4) continue;
    final iccProfile = _parseIccProfile(cosDocument, profile);
    if (iccProfile != null && iccProfile.channels == 4) {
      return _ImageColorSpace.cmyk(iccProfile: iccProfile);
    }
  }
  return null;
}

/// Cache for decoded image XObjects.
class PdfImageDecodeCache {
  /// Creates an image decode cache.
  PdfImageDecodeCache({
    this.maxEntries = _defaultMaxDecodedImageCacheEntries,
    this.maxBytes = _defaultMaxDecodedImageCacheBytes,
    this.maxDownscaledImagePixels,
  }) : assert(maxDownscaledImagePixels == null || maxDownscaledImagePixels > 0);

  /// The maximum number of decoded images retained.
  final int maxEntries;

  /// The maximum total bytes retained by decoded images.
  final int maxBytes;

  /// Optional decoded-image area cap for cached images.
  ///
  /// When set, decoded images whose pixel area exceeds this value are
  /// downscaled, preserving aspect ratio, before they are cached and returned.
  /// Leave this null for full-resolution rendering.
  final int? maxDownscaledImagePixels;

  final _entries = <_ImageDecodeKey, _DecodedImage>{};
  var _bytes = 0;

  /// The current number of decoded images in the cache.
  int get entryCount => _entries.length;

  /// The current total byte size of decoded image data.
  int get byteCount => _bytes;

  /// Removes all decoded images from the cache.
  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  _DecodedImage? _decode(
    _ImageDrawRequest request,
    cos.CosDocument cosDocument,
  ) {
    final key = _ImageDecodeKey.from(request);
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return cached;
    }

    final decoded = _decodePdfImage(request, cosDocument);
    if (decoded == null) return null;
    final cachedDecoded = _downscaleForCache(decoded, maxDownscaledImagePixels);
    _entries[key] = cachedDecoded;
    _bytes += cachedDecoded.byteLength;
    _trim();
    return cachedDecoded;
  }

  void _trim() {
    while (_entries.length > maxEntries || _bytes > maxBytes) {
      final key = _entries.keys.first;
      final removed = _entries.remove(key);
      if (removed == null) break;
      _bytes -= removed.byteLength;
    }
  }
}

_DecodedImage _downscaleForCache(_DecodedImage decoded, int? maxPixels) {
  if (maxPixels == null) return decoded;
  final pixelCount = decoded.width * decoded.height;
  if (pixelCount <= maxPixels) return decoded;

  final scale = math.sqrt(maxPixels / pixelCount);
  var width = math.max(1, (decoded.width * scale).floor());
  var height = math.max(1, (decoded.height * scale).floor());
  while (width * height > maxPixels) {
    if (width >= height && width > 1) {
      width--;
    } else if (height > 1) {
      height--;
    } else {
      break;
    }
  }

  final rgba = Uint8List(width * height * 4);
  final footprintX = decoded.width / width;
  final footprintY = decoded.height / height;
  var dstOffset = 0;
  var opaque = true;
  for (var y = 0; y < height; y++) {
    final uy = 1 - (y + 0.5) / height;
    for (var x = 0; x < width; x++) {
      final ux = (x + 0.5) / width;
      final sample = _sampleImageBox(
        decoded.rgba,
        decoded.width,
        decoded.height,
        ux,
        uy,
        footprintX,
        footprintY,
      );
      rgba[dstOffset] = sample & 0xff;
      rgba[dstOffset + 1] = (sample >>> 8) & 0xff;
      rgba[dstOffset + 2] = (sample >>> 16) & 0xff;
      final alpha = (sample >>> 24) & 0xff;
      rgba[dstOffset + 3] = alpha;
      if (alpha < 255) opaque = false;
      dstOffset += 4;
    }
  }
  return _DecodedImage(width, height, rgba, opaque: opaque);
}

class _ImageDecodeKey {
  const _ImageDecodeKey(
    this.streamId,
    this.colorContextKey,
    this.isStencil,
    this.stencilR,
    this.stencilG,
    this.stencilB,
  );

  factory _ImageDecodeKey.from(_ImageDrawRequest request) => _ImageDecodeKey(
    identityHashCode(request.request.stream),
    request.colorContext.cacheKey,
    request.request.isStencil,
    (request.request.stencilColor.red.clamp(0, 1) * 255).round(),
    (request.request.stencilColor.green.clamp(0, 1) * 255).round(),
    (request.request.stencilColor.blue.clamp(0, 1) * 255).round(),
  );

  final int streamId;
  final int colorContextKey;
  final bool isStencil;
  final int stencilR;
  final int stencilG;
  final int stencilB;

  @override
  bool operator ==(Object other) =>
      other is _ImageDecodeKey &&
      streamId == other.streamId &&
      colorContextKey == other.colorContextKey &&
      isStencil == other.isStencil &&
      stencilR == other.stencilR &&
      stencilG == other.stencilG &&
      stencilB == other.stencilB;

  @override
  int get hashCode => Object.hash(
    streamId,
    colorContextKey,
    isStencil,
    stencilR,
    stencilG,
    stencilB,
  );
}

_DecodedImage? _decodePdfImage(
  _ImageDrawRequest drawRequest,
  cos.CosDocument cosDocument,
) => _decodePdfImageInternal(drawRequest, cosDocument, applySoftMask: true);

_DecodedImage? _decodePdfImageInternal(
  _ImageDrawRequest drawRequest,
  cos.CosDocument cosDocument, {
  required bool applySoftMask,
}) {
  final request = drawRequest.request;
  final dict = request.stream.dictionary;
  final width = _intValue(cosDocument.resolve(dict['Width']));
  final height = _intValue(cosDocument.resolve(dict['Height']));
  if (width <= 0 || height <= 0) return null;
  if (request.isStencil) {
    return _decodeStencilImage(request, cosDocument, width, height);
  }

  final bits = _intValue(cosDocument.resolve(dict['BitsPerComponent']));
  final colorSpace = _ImageColorSpace.parse(
    cosDocument,
    dict['ColorSpace'],
    context: drawRequest.colorContext,
  );
  final filters = _filterNames(cosDocument, dict);
  if (filters.contains('JPXDecode')) {
    final bytes = cosDocument.decodeStreamData(
      request.stream,
      stopBeforeFilter: 'JPXDecode',
    );
    final decoded = cos.JpxDecoder.decode(bytes);
    if (decoded == null) return null;
    if (colorSpace != null &&
        colorSpace.inputComponents == decoded.components) {
      return _applyImageSoftMask(
        cosDocument,
        dict,
        _decodeSampledImage(
          cosDocument,
          dict,
          decoded.samples,
          decoded.width,
          decoded.height,
          8,
          colorSpace,
        ),
        drawRequest.colorContext,
        applySoftMask: applySoftMask,
      );
    }
    return _applyImageSoftMask(
      cosDocument,
      dict,
      _decodeJpxWithoutPdfColorSpace(decoded),
      drawRequest.colorContext,
      applySoftMask: applySoftMask,
    );
  }
  if (filters.contains('DCTDecode') || filters.contains('DCT')) {
    final bytes = cosDocument.decodeStreamData(
      request.stream,
      stopBeforeFilter: filters.contains('DCTDecode') ? 'DCTDecode' : 'DCT',
    );
    if (colorSpace?.kind == _ImageColorSpaceKind.cmyk) {
      final decoded = _decodeCmykJpeg(cosDocument, dict, bytes, colorSpace!);
      if (decoded != null) {
        return _applyImageSoftMask(
          cosDocument,
          dict,
          decoded,
          drawRequest.colorContext,
          applySoftMask: applySoftMask,
        );
      }
    }
    final decoded = image.decodeImage(bytes);
    if (decoded == null) return null;
    final rgba = decoded.getBytes(order: image.ChannelOrder.rgba, alpha: 255);
    if (colorSpace != null && bits > 0) {
      _applyDecodedRgbImageColorSpace(
        rgba,
        cosDocument,
        dict,
        colorSpace,
        bits,
      );
    }
    return _applyImageSoftMask(
      cosDocument,
      dict,
      _DecodedImage(decoded.width, decoded.height, rgba, opaque: true),
      drawRequest.colorContext,
      applySoftMask: applySoftMask,
    );
  }

  if (!_isSupportedImageBits(bits) || colorSpace == null) return null;
  final data = cosDocument.decodeStreamData(request.stream);
  return _applyImageSoftMask(
    cosDocument,
    dict,
    _decodeSampledImage(
      cosDocument,
      dict,
      data,
      width,
      height,
      bits,
      colorSpace,
    ),
    drawRequest.colorContext,
    applySoftMask: applySoftMask,
  );
}

_DecodedImage? _applyImageSoftMask(
  cos.CosDocument cosDocument,
  cos.CosDictionary imageDict,
  _DecodedImage? decoded,
  _ImageColorContext colorContext, {
  required bool applySoftMask,
}) {
  if (!applySoftMask || decoded == null) return decoded;
  final smask = cosDocument.resolve(imageDict['SMask']);
  if (smask is! cos.CosStream) return decoded;

  final mask = _decodePdfImageInternal(
    _ImageDrawRequest(
      PdfImageRequest(
        stream: smask,
        transform: PdfMatrix.identity,
        alpha: 1,
        isStencil: false,
        stencilColor: const PdfColor(0, 0, 0),
        isInline: false,
      ),
      colorContext,
    ),
    cosDocument,
    applySoftMask: false,
  );
  if (mask == null || mask.width <= 0 || mask.height <= 0) return decoded;

  final rgba = decoded.rgba;
  var opaque = true;
  for (var y = 0; y < decoded.height; y++) {
    final maskY = (y * mask.height ~/ decoded.height).clamp(0, mask.height - 1);
    for (var x = 0; x < decoded.width; x++) {
      final dstOffset = (y * decoded.width + x) * 4;
      final maskX = (x * mask.width ~/ decoded.width).clamp(0, mask.width - 1);
      final maskOffset = (maskY * mask.width + maskX) * 4;
      final maskAlpha = mask.rgba[maskOffset + 3];
      final maskLum = _luminance(
        mask.rgba[maskOffset],
        mask.rgba[maskOffset + 1],
        mask.rgba[maskOffset + 2],
      );
      final alpha = (maskLum * maskAlpha).round();
      rgba[dstOffset + 3] = rgba[dstOffset + 3] * alpha ~/ 255;
      if (rgba[dstOffset + 3] < 255) opaque = false;
    }
  }
  return _DecodedImage(decoded.width, decoded.height, rgba, opaque: opaque);
}

_DecodedImage? _decodeJpxWithoutPdfColorSpace(cos.JpxImage image) {
  final pixelCount = image.width * image.height;
  if (image.samples.length < pixelCount * image.components) return null;
  final rgba = Uint8List(pixelCount * 4);
  var srcOffset = 0;
  var dstOffset = 0;
  switch (image.components) {
    case 1:
      for (var i = 0; i < pixelCount; i++) {
        final gray = image.samples[srcOffset++];
        rgba[dstOffset] = gray;
        rgba[dstOffset + 1] = gray;
        rgba[dstOffset + 2] = gray;
        rgba[dstOffset + 3] = 255;
        dstOffset += 4;
      }
    case 3:
      for (var i = 0; i < pixelCount; i++) {
        rgba[dstOffset] = image.samples[srcOffset++];
        rgba[dstOffset + 1] = image.samples[srcOffset++];
        rgba[dstOffset + 2] = image.samples[srcOffset++];
        rgba[dstOffset + 3] = 255;
        dstOffset += 4;
      }
    default:
      return null;
  }
  return _DecodedImage(image.width, image.height, rgba, opaque: true);
}

_DecodedImage? _decodeSampledImage(
  cos.CosDocument cosDocument,
  cos.CosDictionary dict,
  Uint8List data,
  int width,
  int height,
  int bits,
  _ImageColorSpace colorSpace,
) {
  final pixelCount = width * height;
  final components = colorSpace.inputComponents;
  if (!_hasEnoughSamples(data, pixelCount * components, bits)) return null;

  final decode = _ImageDecodeRanges.parse(
    cosDocument,
    dict['Decode'],
    colorSpace,
    bits,
  );
  final rgba = Uint8List(pixelCount * 4);
  var sampleIndex = 0;
  var dstOffset = 0;
  final rgb = List<int>.filled(3, 0);
  final componentsBuffer = List<int>.filled(
    math.max(1, colorSpace.inputComponents),
    0,
  );
  final iccTransform = _iccTransformFor(colorSpace);
  for (var i = 0; i < pixelCount; i++) {
    switch (colorSpace.kind) {
      case _ImageColorSpaceKind.gray:
        componentsBuffer[0] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          0,
        );
        colorSpace.toRgbBytes(componentsBuffer, rgb, iccTransform);
        rgba[dstOffset] = rgb[0];
        rgba[dstOffset + 1] = rgb[1];
        rgba[dstOffset + 2] = rgb[2];
      case _ImageColorSpaceKind.rgb:
        componentsBuffer[0] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          0,
        );
        componentsBuffer[1] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          1,
        );
        componentsBuffer[2] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          2,
        );
        colorSpace.toRgbBytes(componentsBuffer, rgb, iccTransform);
        rgba[dstOffset] = rgb[0];
        rgba[dstOffset + 1] = rgb[1];
        rgba[dstOffset + 2] = rgb[2];
      case _ImageColorSpaceKind.cmyk:
        componentsBuffer[0] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          0,
        );
        componentsBuffer[1] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          1,
        );
        componentsBuffer[2] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          2,
        );
        componentsBuffer[3] = decode.toByte(
          _readSample(data, sampleIndex++, bits),
          bits,
          3,
        );
        colorSpace.toRgbBytes(componentsBuffer, rgb, iccTransform);
        rgba[dstOffset] = rgb[0];
        rgba[dstOffset + 1] = rgb[1];
        rgba[dstOffset + 2] = rgb[2];
      case _ImageColorSpaceKind.indexed:
        final index = decode.toIndex(
          _readSample(data, sampleIndex++, bits),
          bits,
          colorSpace.highValue,
        );
        _setIndexedColor(rgba, dstOffset, colorSpace, index, rgb);
    }
    rgba[dstOffset + 3] = 255;
    dstOffset += 4;
  }
  return _DecodedImage(width, height, rgba, opaque: true);
}

_DecodedImage? _decodeCmykJpeg(
  cos.CosDocument cosDocument,
  cos.CosDictionary dict,
  Uint8List bytes,
  _ImageColorSpace colorSpace,
) {
  try {
    final jpeg = image_internal.JpegData()..read(bytes);
    if (jpeg.components.length != 4) return null;
    final width = jpeg.width ?? 0;
    final height = jpeg.height ?? 0;
    if (width <= 0 || height <= 0) return null;

    final decode = _ImageDecodeRanges.parse(
      cosDocument,
      dict['Decode'],
      colorSpace,
      8,
    );
    final rgba = Uint8List(width * height * 4);
    final rgb = List<int>.filled(3, 0);

    final c1 = jpeg.components[0];
    final c2 = jpeg.components[1];
    final c3 = jpeg.components[2];
    final c4 = jpeg.components[3];
    final colorTransform = (jpeg.adobe?.transformCode ?? 0) != 0;
    final componentsBuffer = List<int>.filled(4, 0);
    final iccTransform = _iccTransformFor(colorSpace);
    var dstOffset = 0;

    for (var y = 0; y < height; y++) {
      final line1 = c1.lines[y >> c1.vScaleShift]!;
      final line2 = c2.lines[y >> c2.vScaleShift]!;
      final line3 = c3.lines[y >> c3.vScaleShift]!;
      final line4 = c4.lines[y >> c4.vScaleShift]!;
      for (var x = 0; x < width; x++) {
        final x1 = x >> c1.hScaleShift;
        final x2 = x >> c2.hScaleShift;
        final x3 = x >> c3.hScaleShift;
        final x4 = x >> c4.hScaleShift;
        int cyan;
        int magenta;
        int yellow;
        final black = line4[x4];
        if (colorTransform) {
          final luma = line1[x1];
          final cb = line2[x2] - 128;
          final cr = line3[x3] - 128;
          final scaled = luma << 8;
          cyan = 255 - ((scaled + 359 * cr) >> 8).clamp(0, 255).toInt();
          magenta =
              255 - ((scaled - 88 * cb - 183 * cr) >> 8).clamp(0, 255).toInt();
          yellow = 255 - ((scaled + 454 * cb) >> 8).clamp(0, 255).toInt();
        } else {
          cyan = line1[x1];
          magenta = line2[x2];
          yellow = line3[x3];
        }

        componentsBuffer[0] = decode.toByte(cyan, 8, 0);
        componentsBuffer[1] = decode.toByte(magenta, 8, 1);
        componentsBuffer[2] = decode.toByte(yellow, 8, 2);
        componentsBuffer[3] = decode.toByte(black, 8, 3);
        colorSpace.toRgbBytes(componentsBuffer, rgb, iccTransform);
        rgba[dstOffset] = rgb[0];
        rgba[dstOffset + 1] = rgb[1];
        rgba[dstOffset + 2] = rgb[2];
        rgba[dstOffset + 3] = 255;
        dstOffset += 4;
      }
    }
    return _DecodedImage(width, height, rgba, opaque: true);
  } on Exception {
    return null;
  }
}

int _sampleImageBilinear(
  Uint8List rgba,
  int width,
  int height,
  double ux,
  double uy,
) {
  var sx = ux * width - 0.5;
  var sy = (1 - uy) * height - 0.5;
  if (sx < 0) {
    sx = 0;
  } else {
    final maxX = width - 1.0;
    if (sx > maxX) sx = maxX;
  }
  if (sy < 0) {
    sy = 0;
  } else {
    final maxY = height - 1.0;
    if (sy > maxY) sy = maxY;
  }

  final x0 = sx.floor();
  final y0 = sy.floor();
  final x1 = x0 + 1 < width ? x0 + 1 : x0;
  final y1 = y0 + 1 < height ? y0 + 1 : y0;
  final wx = ((sx - x0) * 256).round();
  final wy = ((sy - y0) * 256).round();
  final ix = 256 - wx;
  final iy = 256 - wy;
  final w00 = ix * iy;
  final w10 = wx * iy;
  final w01 = ix * wy;
  final w11 = wx * wy;
  final o00 = (y0 * width + x0) * 4;
  final o10 = (y0 * width + x1) * 4;
  final o01 = (y1 * width + x0) * 4;
  final o11 = (y1 * width + x1) * 4;

  final r =
      (rgba[o00] * w00 +
          rgba[o10] * w10 +
          rgba[o01] * w01 +
          rgba[o11] * w11 +
          32768) >>>
      16;
  final g =
      (rgba[o00 + 1] * w00 +
          rgba[o10 + 1] * w10 +
          rgba[o01 + 1] * w01 +
          rgba[o11 + 1] * w11 +
          32768) >>>
      16;
  final b =
      (rgba[o00 + 2] * w00 +
          rgba[o10 + 2] * w10 +
          rgba[o01 + 2] * w01 +
          rgba[o11 + 2] * w11 +
          32768) >>>
      16;
  final a =
      (rgba[o00 + 3] * w00 +
          rgba[o10 + 3] * w10 +
          rgba[o01 + 3] * w01 +
          rgba[o11 + 3] * w11 +
          32768) >>>
      16;
  return r | (g << 8) | (b << 16) | (a << 24);
}

int _sampleImageBox(
  Uint8List rgba,
  int width,
  int height,
  double ux,
  double uy,
  double footprintX,
  double footprintY,
) {
  final centerX = ux * width - 0.5;
  final centerY = (1 - uy) * height - 0.5;
  final left = (centerX - footprintX * 0.5).clamp(0.0, width - 1.0);
  final right = (centerX + footprintX * 0.5).clamp(0.0, width - 1.0);
  final top = (centerY - footprintY * 0.5).clamp(0.0, height - 1.0);
  final bottom = (centerY + footprintY * 0.5).clamp(0.0, height - 1.0);
  final xStart = left.floor();
  final xEnd = right.ceil().clamp(0, width - 1).toInt();
  final yStart = top.floor();
  final yEnd = bottom.ceil().clamp(0, height - 1).toInt();

  var total = 0.0;
  var r = 0.0;
  var g = 0.0;
  var b = 0.0;
  var a = 0.0;
  for (var y = yStart; y <= yEnd; y++) {
    final wy = math.min(y + 0.5, bottom) - math.max(y - 0.5, top);
    if (wy <= 0) continue;
    for (var x = xStart; x <= xEnd; x++) {
      final wx = math.min(x + 0.5, right) - math.max(x - 0.5, left);
      if (wx <= 0) continue;
      final weight = wx * wy;
      final offset = (y * width + x) * 4;
      r += rgba[offset] * weight;
      g += rgba[offset + 1] * weight;
      b += rgba[offset + 2] * weight;
      a += rgba[offset + 3] * weight;
      total += weight;
    }
  }
  if (total <= 0) return _sampleImageBilinear(rgba, width, height, ux, uy);
  final rr = (r / total).round().clamp(0, 255).toInt();
  final gg = (g / total).round().clamp(0, 255).toInt();
  final bb = (b / total).round().clamp(0, 255).toInt();
  final aa = (a / total).round().clamp(0, 255).toInt();
  return rr | (gg << 8) | (bb << 16) | (aa << 24);
}

_DecodedImage? _decodeStencilImage(
  PdfImageRequest request,
  cos.CosDocument cosDocument,
  int width,
  int height,
) {
  final data = cosDocument.decodeStreamData(request.stream);
  final rgba = Uint8List(width * height * 4);
  final r = (request.stencilColor.red.clamp(0, 1) * 255).round();
  final g = (request.stencilColor.green.clamp(0, 1) * 255).round();
  final b = (request.stencilColor.blue.clamp(0, 1) * 255).round();
  final rowStride = (width + 7) >> 3;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final bitIndex = y * width + x;
      final byteIndex = y * rowStride + x ~/ 8;
      if (byteIndex >= data.length) continue;
      final bit = 7 - (x % 8);
      final painted = ((data[byteIndex] >> bit) & 1) != 0;
      final offset = bitIndex * 4;
      rgba[offset] = r;
      rgba[offset + 1] = g;
      rgba[offset + 2] = b;
      rgba[offset + 3] = painted ? 255 : 0;
    }
  }
  return _DecodedImage(width, height, rgba, opaque: false);
}

bool _isSupportedImageBits(int bits) =>
    bits == 1 || bits == 2 || bits == 4 || bits == 8;

bool _hasEnoughSamples(Uint8List data, int sampleCount, int bits) =>
    data.length * 8 >= sampleCount * bits;

int _readSample(Uint8List data, int sampleIndex, int bits) {
  if (bits == 8) return data[sampleIndex];
  final bitOffset = sampleIndex * bits;
  final byte = data[bitOffset >> 3];
  final shift = 8 - bits - (bitOffset & 7);
  return (byte >> shift) & ((1 << bits) - 1);
}

void _cmykToRgb(int c, int m, int y, int k, List<int> rgb) {
  pdfiumCmykToRgb(c, m, y, k, rgb);
}

void _applyDecodedRgbImageColorSpace(
  Uint8List rgba,
  cos.CosDocument cosDocument,
  cos.CosDictionary dict,
  _ImageColorSpace colorSpace,
  int bits,
) {
  if (colorSpace.kind == _ImageColorSpaceKind.cmyk ||
      colorSpace.kind == _ImageColorSpaceKind.indexed) {
    return;
  }
  final decode = _ImageDecodeRanges.parse(
    cosDocument,
    dict['Decode'],
    colorSpace,
    bits,
  );
  if (decode.isDefault01 && colorSpace.iccProfile == null) return;

  final components = List<int>.filled(colorSpace.inputComponents, 0);
  final rgb = List<int>.filled(3, 0);
  final iccTransform = _iccTransformFor(colorSpace);
  for (var i = 0; i < rgba.length; i += 4) {
    if (colorSpace.kind == _ImageColorSpaceKind.gray) {
      components[0] = decode.toByte(rgba[i], 8, 0);
    } else {
      components[0] = decode.toByte(rgba[i], 8, 0);
      components[1] = decode.toByte(rgba[i + 1], 8, 1);
      components[2] = decode.toByte(rgba[i + 2], 8, 2);
    }
    colorSpace.toRgbBytes(components, rgb, iccTransform);
    rgba[i] = rgb[0];
    rgba[i + 1] = rgb[1];
    rgba[i + 2] = rgb[2];
  }
}

void _setIndexedColor(
  Uint8List rgba,
  int dstOffset,
  _ImageColorSpace indexed,
  int index,
  List<int> rgb,
) {
  final base = indexed.base;
  final lookup = indexed.lookup;
  if (base == null || lookup == null) return;

  final componentOffset = index * base.inputComponents;
  if (componentOffset + base.inputComponents > lookup.length) return;
  base.toRgbBytes(lookup.sublist(componentOffset), rgb);
  rgba[dstOffset] = rgb[0];
  rgba[dstOffset + 1] = rgb[1];
  rgba[dstOffset + 2] = rgb[2];
}

enum _ImageColorSpaceKind { gray, rgb, cmyk, indexed }

class _ImageColorSpace {
  const _ImageColorSpace._(
    this.kind, {
    this.base,
    this.lookup,
    this.highValue = 0,
    this.iccProfile,
  });

  factory _ImageColorSpace.gray({IccProfile? iccProfile}) =>
      _ImageColorSpace._(_ImageColorSpaceKind.gray, iccProfile: iccProfile);

  factory _ImageColorSpace.rgb({IccProfile? iccProfile}) =>
      _ImageColorSpace._(_ImageColorSpaceKind.rgb, iccProfile: iccProfile);

  factory _ImageColorSpace.cmyk({IccProfile? iccProfile}) =>
      _ImageColorSpace._(_ImageColorSpaceKind.cmyk, iccProfile: iccProfile);

  factory _ImageColorSpace.indexed({
    required _ImageColorSpace base,
    required Uint8List lookup,
    required int highValue,
  }) => _ImageColorSpace._(
    _ImageColorSpaceKind.indexed,
    base: base,
    lookup: lookup,
    highValue: highValue,
  );

  final _ImageColorSpaceKind kind;
  final _ImageColorSpace? base;
  final Uint8List? lookup;
  final int highValue;
  final IccProfile? iccProfile;

  int get inputComponents => switch (kind) {
    _ImageColorSpaceKind.gray => iccProfile?.channels ?? 1,
    _ImageColorSpaceKind.rgb => iccProfile?.channels ?? 3,
    _ImageColorSpaceKind.cmyk => iccProfile?.channels ?? 4,
    _ImageColorSpaceKind.indexed => 1,
  };

  void toRgbBytes(
    List<int> components,
    List<int> rgb, [
    _IccColorTransform? iccTransform,
  ]) {
    final profile = iccProfile;
    if (profile != null && components.length >= profile.channels) {
      (iccTransform ?? _IccColorTransform(profile)).toRgbBytes(components, rgb);
      return;
    }
    switch (kind) {
      case _ImageColorSpaceKind.gray:
        final gray = components.isEmpty ? 0 : components[0];
        rgb[0] = gray;
        rgb[1] = gray;
        rgb[2] = gray;
      case _ImageColorSpaceKind.rgb:
        rgb[0] = components.isEmpty ? 0 : components[0];
        rgb[1] = components.length < 2 ? 0 : components[1];
        rgb[2] = components.length < 3 ? 0 : components[2];
      case _ImageColorSpaceKind.cmyk:
        _cmykToRgb(
          components.isEmpty ? 0 : components[0],
          components.length < 2 ? 0 : components[1],
          components.length < 3 ? 0 : components[2],
          components.length < 4 ? 0 : components[3],
          rgb,
        );
      case _ImageColorSpaceKind.indexed:
        break;
    }
  }

  static _ImageColorSpace? parse(
    cos.CosDocument cosDocument,
    cos.CosObject? object, {
    _ImageColorContext? context,
    bool useDeviceDefaults = true,
    Set<String>? resolvingNames,
  }) {
    final resolved = cosDocument.resolve(object);
    if (resolved is cos.CosName) {
      return switch (resolved.value) {
        'DeviceGray' || 'G' =>
          useDeviceDefaults
              ? context?.defaultGray ?? _ImageColorSpace.gray()
              : _ImageColorSpace.gray(),
        'DeviceRGB' || 'RGB' =>
          useDeviceDefaults
              ? context?.defaultRgb ?? _ImageColorSpace.rgb()
              : _ImageColorSpace.rgb(),
        'DeviceCMYK' || 'CMYK' =>
          useDeviceDefaults
              ? context?.defaultCmyk ?? _ImageColorSpace.cmyk()
              : _ImageColorSpace.cmyk(),
        _ => context?.resolveNamed(
          cosDocument,
          resolved.value,
          useDeviceDefaults: useDeviceDefaults,
          resolvingNames: resolvingNames,
        ),
      };
    }
    if (resolved is! cos.CosArray || resolved.length == 0) return null;

    final family = _nameValue(cosDocument.resolve(resolved[0]));
    if ((family == 'Indexed' || family == 'I') && resolved.length >= 4) {
      final base = parse(
        cosDocument,
        resolved[1],
        context: context,
        useDeviceDefaults: useDeviceDefaults,
        resolvingNames: resolvingNames,
      );
      if (base == null || base.kind == _ImageColorSpaceKind.indexed) {
        return null;
      }
      final highValue = _intValue(cosDocument.resolve(resolved[2]));
      final lookup = _lookupBytes(cosDocument, resolved[3]);
      if (highValue < 0 || lookup == null) return null;
      return _ImageColorSpace.indexed(
        base: base,
        lookup: lookup,
        highValue: highValue,
      );
    }
    if (family == 'ICCBased' && resolved.length >= 2) {
      final profile = cosDocument.resolve(resolved[1]);
      if (profile is! cos.CosStream) return null;
      final n = _intValue(cosDocument.resolve(profile.dictionary['N']));
      final iccProfile = _parseIccProfile(cosDocument, profile);
      if (iccProfile != null && iccProfile.channels == n) {
        return _iccColorSpace(n, iccProfile);
      }
      final alternate = parse(
        cosDocument,
        profile.dictionary['Alternate'],
        context: context,
        useDeviceDefaults: false,
        resolvingNames: resolvingNames,
      );
      return alternate ?? _deviceColorSpaceForComponents(n);
    }
    return null;
  }
}

int _unitToByte(double value) => (value.clamp(0, 1) * 255).round();

_ImageColorSpace? _iccColorSpace(int components, IccProfile profile) =>
    switch (components) {
      1 => _ImageColorSpace.gray(iccProfile: profile),
      3 => _ImageColorSpace.rgb(iccProfile: profile),
      4 => _ImageColorSpace.cmyk(iccProfile: profile),
      _ => null,
    };

_ImageColorSpace? _deviceColorSpaceForComponents(int components) =>
    switch (components) {
      1 => _ImageColorSpace.gray(),
      3 => _ImageColorSpace.rgb(),
      4 => _ImageColorSpace.cmyk(),
      _ => null,
    };

IccProfile? _parseIccProfile(
  cos.CosDocument cosDocument,
  cos.CosStream profile,
) {
  final cached = _iccProfileCache[profile];
  if (cached != null) return cached.profile;
  try {
    final bytes = cosDocument.decodeStreamData(profile);
    if (_isLikelySrgbIccProfile(bytes)) {
      _iccProfileCache[profile] = const _CachedIccProfile(null);
      return null;
    }
    final parsed = IccProfile.parse(bytes);
    _iccProfileCache[profile] = _CachedIccProfile(parsed);
    return parsed;
  } on Exception {
    _iccProfileCache[profile] = const _CachedIccProfile(null);
    return null;
  }
}

bool _isLikelySrgbIccProfile(Uint8List bytes) {
  if (bytes.length < 128) return false;
  if (String.fromCharCodes(bytes, 16, 20) != 'RGB ') return false;
  return _containsAsciiIgnoreCase(bytes, 'sRGB') ||
      (_containsAsciiIgnoreCase(bytes, 'IEC') &&
          _containsAsciiIgnoreCase(bytes, '61966'));
}

bool _containsAsciiIgnoreCase(Uint8List bytes, String needle) {
  if (needle.isEmpty || bytes.length < needle.length) return false;
  final lowerNeedle = [
    for (var i = 0; i < needle.length; i++) _asciiLower(needle.codeUnitAt(i)),
  ];
  final lastStart = bytes.length - lowerNeedle.length;
  for (var start = 0; start <= lastStart; start++) {
    var matches = true;
    for (var i = 0; i < lowerNeedle.length; i++) {
      if (_asciiLower(bytes[start + i]) != lowerNeedle[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

int _asciiLower(int value) =>
    value >= 0x41 && value <= 0x5a ? value + 0x20 : value;

_IccColorTransform? _iccTransformFor(_ImageColorSpace colorSpace) {
  final profile = colorSpace.iccProfile;
  return profile == null ? null : _IccColorTransform(profile);
}

final _iccProfileCache = Expando<_CachedIccProfile>('dart_pdf_renderer.icc');

class _CachedIccProfile {
  const _CachedIccProfile(this.profile);

  final IccProfile? profile;
}

const _maxIccTransformCacheEntries = 1 << 20;

class _IccColorTransform {
  _IccColorTransform(this.profile)
    : values = List<double>.filled(profile.channels, 0, growable: false);

  final IccProfile profile;
  final List<double> values;
  final _cache = <int, int>{};

  void toRgbBytes(List<int> components, List<int> rgb) {
    final key = _componentKey(components, profile.channels);
    final cached = _cache[key];
    if (cached != null) {
      _unpackRgb(cached, rgb);
      return;
    }

    for (var i = 0; i < profile.channels; i++) {
      values[i] = components[i] / 255;
    }
    final color = profile.toSrgb(values);
    final packed = _packRgb(
      _unitToByte(color.red),
      _unitToByte(color.green),
      _unitToByte(color.blue),
    );
    if (_cache.length < _maxIccTransformCacheEntries) {
      _cache[key] = packed;
    }
    _unpackRgb(packed, rgb);
  }
}

int _componentKey(List<int> components, int channels) => switch (channels) {
  1 => components[0],
  3 => components[0] | (components[1] << 8) | (components[2] << 16),
  4 =>
    components[0] |
        (components[1] << 8) |
        (components[2] << 16) |
        (components[3] << 24),
  _ => Object.hashAll(components.take(channels)),
};

int _packRgb(int red, int green, int blue) => red | (green << 8) | (blue << 16);

void _unpackRgb(int packed, List<int> rgb) {
  rgb[0] = packed & 0xff;
  rgb[1] = (packed >> 8) & 0xff;
  rgb[2] = (packed >> 16) & 0xff;
}

Uint8List? _lookupBytes(cos.CosDocument cosDocument, cos.CosObject object) {
  final resolved = cosDocument.resolve(object);
  if (resolved is cos.CosString) return resolved.bytes;
  if (resolved is cos.CosStream) return cosDocument.decodeStreamData(resolved);
  return null;
}

class _ImageDecodeRanges {
  const _ImageDecodeRanges(this.pairs);

  factory _ImageDecodeRanges.parse(
    cos.CosDocument cosDocument,
    cos.CosObject? object,
    _ImageColorSpace colorSpace,
    int bits,
  ) {
    final components = colorSpace.inputComponents;
    final resolved = cosDocument.resolve(object);
    if (resolved is cos.CosArray && resolved.length >= components * 2) {
      return _ImageDecodeRanges([
        for (var i = 0; i < components; i++)
          _DecodePair(
            _numberValue(cosDocument.resolve(resolved[i * 2])),
            _numberValue(cosDocument.resolve(resolved[i * 2 + 1])),
          ),
      ]);
    }
    final max = colorSpace.kind == _ImageColorSpaceKind.indexed
        ? ((1 << bits) - 1).toDouble()
        : 1.0;
    return _ImageDecodeRanges([
      for (var i = 0; i < components; i++) _DecodePair(0, max),
    ]);
  }

  final List<_DecodePair> pairs;

  bool get isDefault01 {
    for (final pair in pairs) {
      if (pair.min != 0 || pair.max != 1) return false;
    }
    return true;
  }

  int toByte(int sample, int bits, int component) {
    final pair = pairs[component];
    final decoded = pair.decode(sample, bits).clamp(0.0, 1.0);
    return (decoded * 255).round().clamp(0, 255).toInt();
  }

  int toIndex(int sample, int bits, int highValue) {
    final decoded = pairs[0].decode(sample, bits);
    return decoded.round().clamp(0, highValue).toInt();
  }
}

class _DecodePair {
  const _DecodePair(this.min, this.max);

  final double min;
  final double max;

  double decode(int sample, int bits) {
    final maxSample = (1 << bits) - 1;
    if (maxSample <= 0) return min;
    return min + sample * (max - min) / maxSample;
  }
}
