import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx_dart_pdf/src/pdfrx_dart_pdf_entry_functions.dart';

void main() {
  test(
    'pdfrx adapter renders with an adapter-created cancellation token',
    () async {
      const entry = PdfrxDartPdfEntryFunctions();
      final document = await entry.openFile('example/viewer/assets/hello.pdf');
      try {
        final page = document.pages.first;
        final token = page.createCancellationToken();
        final image = await page.render(
          fullWidth: 256,
          fullHeight: 256 * page.height / page.width,
          backgroundColor: 0xffffffff,
          cancellationToken: token,
        );
        try {
          expect(token.isCanceled, isFalse);
          expect(image, isNotNull);
          expect(_nonWhitePixelsBgra(image!.pixels), greaterThan(0));
        } finally {
          image?.dispose();
        }

        await document.reloadPages(pageNumbersToReload: [page.pageNumber]);
        final rerendered = await page.render(
          fullWidth: 256,
          fullHeight: 256 * page.height / page.width,
          backgroundColor: 0xffffffff,
        );
        try {
          expect(rerendered, isNotNull);
          expect(_nonWhitePixelsBgra(rerendered!.pixels), greaterThan(0));
        } finally {
          rerendered?.dispose();
        }
      } finally {
        await document.dispose();
      }
    },
  );
}

int _nonWhitePixelsBgra(List<int> bgra) {
  var nonWhite = 0;
  for (var i = 0; i < bgra.length; i += 4) {
    final b = bgra[i];
    final g = bgra[i + 1];
    final r = bgra[i + 2];
    if (r != 255 || g != 255 || b != 255) nonWhite++;
  }
  return nonWhite;
}
