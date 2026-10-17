import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:molly_controller/widgets/map_image.dart';

/// A 3 x 2 grayscale map as the robot sends it: occupied, unknown, free / free, unknown, occupied.
final grayMap = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, //
  0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00, 0x00, 0x00, 0x00, 0xB8, //
  0x1F, 0x39, 0xC6, 0x00, 0x00, 0x00, 0x10, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0x60, //
  0x38, 0xFB, 0x8F, 0xE1, 0xDF, 0x59, 0x06, 0x00, 0x0E, 0x60, 0x03, 0x97, 0x2F, 0xF9, 0xBA, //
  0x0F, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
]);

void main() {
  test('map cells: walls light, floor dark, unknown see-through', () {
    expect(cellRgba(0), occupiedRgba);
    expect(cellRgba(99), occupiedRgba);
    expect(cellRgba(205), unknownRgba);
    expect(cellRgba(254), freeRgba);
    expect(unknownRgba.last, 0);
    expect(occupiedRgba.last, 255);
  });

  testWidgets('the map PNG decodes into those colours', (tester) async {
    final decoded = await tester.runAsync(() async {
      final image = await decodeMapImage(grayMap);
      if (image == null) return null;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final size = [image.width, image.height];
      image.dispose();
      return (size: size, pixels: data!.buffer.asUint8List());
    });
    expect(decoded, isNotNull);
    final (:size, :pixels) = decoded!;
    expect(size, [3, 2]);
    List<int> pixel(int index) => pixels.sublist(index * 4, index * 4 + 4);
    expect(pixel(0), occupiedRgba);
    expect(pixel(1), unknownRgba);
    expect(pixel(2), freeRgba);
    expect(pixel(3), freeRgba);
    expect(pixel(5), occupiedRgba);
  });

  testWidgets('a broken PNG gives no map', (tester) async {
    final image = await tester.runAsync(
      () => decodeMapImage(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])),
    );
    expect(image, isNull);
  });
}
