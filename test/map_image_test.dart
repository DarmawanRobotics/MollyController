import 'package:flutter_test/flutter_test.dart';
import 'package:molly_controller/widgets/map_image.dart';

void main() {
  test('map cells: walls light, floor dark, unknown see-through', () {
    expect(cellRgba(0), occupiedRgba);
    expect(cellRgba(99), occupiedRgba);
    expect(cellRgba(205), unknownRgba);
    expect(cellRgba(254), freeRgba);
    expect(unknownRgba.last, 0);
    expect(occupiedRgba.last, 255);
  });
}
