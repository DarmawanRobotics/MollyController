import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// RGBA of an occupied cell (walls, light), a free cell (floor, dark) and an unknown one (clear).
const occupiedRgba = [214, 222, 226, 255];
const freeRgba = [27, 40, 46, 255];
const unknownRgba = [0, 0, 0, 0];

/// RGBA of a map cell by its gray value: below 100 occupied, above 230 free, else unknown.
List<int> cellRgba(int gray) => gray < 100 ? occupiedRgba : (gray > 230 ? freeRgba : unknownRgba);

/// Four bytes per gray value 0..255: the lookup the map image is coloured with.
final Uint8List _palette = Uint8List.fromList([
  for (var gray = 0; gray < 256; gray++) ...cellRgba(gray),
]);

/// The robot's grayscale map PNG in the handheld's colours: light walls, dark floor, unknown
/// cells see-through. Null when the PNG cannot be decoded.
Future<ui.Image?> decodeMapImage(Uint8List png) async {
  ui.Codec? codec;
  ui.Image? source;
  try {
    codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    source = frame.image;
    final data = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final pixels = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final out = Uint8List(pixels.length);
    for (var i = 0; i + 3 < pixels.length; i += 4) {
      final at = pixels[i] * 4; // gray: red, green and blue are equal
      out[i] = _palette[at];
      out[i + 1] = _palette[at + 1];
      out[i + 2] = _palette[at + 2];
      out[i + 3] = _palette[at + 3];
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      out,
      source.width,
      source.height,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return await done.future;
  } on Exception {
    return null;
  } finally {
    source?.dispose();
    codec?.dispose();
  }
}
