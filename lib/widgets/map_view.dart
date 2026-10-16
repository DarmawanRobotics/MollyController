import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../protocol/messages.dart';
import '../protocol/streams.dart';
import '../theme.dart';
import 'map_image.dart';

/// What the map shows.
enum MapMode {
  /// The map, its POIs, the loaded route or path, where the robot has been and the robot.
  fit,

  /// A fixed span around the robot, moving with it.
  follow,

  /// Where the operator dragged and zoomed it.
  free,
}

/// [angle] in (-pi, pi].
double wrapAngle(double angle) => math.atan2(math.sin(angle), math.cos(angle));

/// The map's view, shared by the big and the small map and the buttons under the small one.
class MapViewport extends ChangeNotifier {
  static const minSpan = 2.0;
  static const maxSpan = 5000.0;

  MapMode _mode = MapMode.fit;
  Offset _center = Offset.zero;
  double _span = 12;
  double _rotation = 0;
  bool _headingUp = false;

  MapMode get mode => _mode;

  /// Middle of the view in map metres (free mode).
  Offset get center => _center;

  /// Metres across the shorter side of the view (follow and free mode).
  double get span => _span;

  /// The map turned by hand, radians counter-clockwise; 0 is north up (map y up, x right).
  double get rotation => _rotation;

  /// The map turns with the robot, which then always drives up the screen.
  bool get headingUp => _headingUp;

  /// The turn of the map on screen while the robot heads [yaw] (map frame).
  double rotationFor(double? yaw) =>
      _headingUp && yaw != null ? wrapAngle(math.pi / 2 - yaw) : _rotation;

  static double clampSpan(double span) => math.min(maxSpan, math.max(minSpan, span));

  void fit() => _set(MapMode.fit, _center, _span, headingUp: false);

  void follow() => _set(MapMode.follow, _center, _span);

  /// Zoom (and turn) while following the robot.
  void zoom(double span, {double? rotation}) => _set(
    MapMode.follow,
    _center,
    span,
    rotation: rotation,
    headingUp: rotation == null ? null : false,
  );

  /// Show [center] with [span] metres across the shorter side, turned by [rotation].
  void moveTo(Offset center, double span, double rotation) =>
      _set(MapMode.free, center, span, rotation: rotation, headingUp: false);

  /// North up again.
  void northUp() => _set(_mode, _center, _span, rotation: 0, headingUp: false);

  /// Follow the robot with its heading up.
  void trackHeading() => _set(MapMode.follow, _center, _span, headingUp: true);

  void _set(MapMode mode, Offset center, double span, {double? rotation, bool? headingUp}) {
    _mode = mode;
    _center = center;
    _span = clampSpan(span);
    if (rotation != null) _rotation = wrapAngle(rotation);
    if (headingUp != null) _headingUp = headingUp;
    notifyListeners();
  }
}

/// Top-down map in the map frame: the site's occupancy map and POIs, the loaded route or the path
/// the robot found with its waypoints and stop points, where the robot has been, the lidar
/// returns and the robot itself.
///
/// The big map zooms with a pinch, moves with a drag and turns with a two-finger twist (nearly
/// north snaps north); a double tap follows the robot again, a long press picks a place. The
/// small one only shows. Without a pose (not localized) it shows the site map without the robot,
/// or, without a map, the lidar around the robot, which looks up the screen.
class MapView extends StatefulWidget {
  const MapView({
    super.key,
    required this.viewport,
    required this.points,
    required this.route,
    required this.trail,
    required this.pose,
    required this.modeColor,
    required this.lidar,
    required this.notLocalizedText,
    this.map,
    this.site,
    this.highlight,
    this.onLongPress,
    this.marks = const [],
    this.compact = false,
  });

  final MapViewport viewport;
  final ValueListenable<Float32List?> points;
  final ValueListenable<List<RoutePoint>> route;
  final List<Offset> trail;

  /// The site's occupancy map, drawn under everything else.
  final ValueListenable<MapLayer?>? map;

  /// The site's POIs, drawn with their names.
  final ValueListenable<SiteData?>? site;

  /// The POI the robot is walking to or talking about, ringed.
  final String? highlight;

  /// A long press on the big map: the place in map metres.
  final ValueChanged<Offset>? onLongPress;

  /// Stop points marked in the route being recorded (not in the route stream yet).
  final List<Offset> marks;
  final Pose? pose;
  final Color modeColor;
  final bool lidar;
  final String notLocalizedText;

  /// Small box: thinner lines, no labels, no gestures (a tap there swaps the views).
  final bool compact;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  late Listenable _changes = _merge();
  Size _size = Size.zero;

  /// The map image in the handheld's colours and where it lies; null until decoded.
  ui.Image? _mapImage;
  MapHeader? _mapHeader;

  /// The layer decoded last, and a counter that drops decodes of older layers.
  MapLayer? _decoded;
  int _decodes = 0;

  /// Twist of the fingers before the map starts turning, and the turn that snaps north.
  static const _twistThreshold = 0.2;
  static const _snapNorth = 0.12;

  // the gesture: where it started, the view then, and the map point held under the fingers
  Offset _startFocal = Offset.zero;
  double _baseScale = 1;
  double _baseRotation = 0;
  Offset _anchor = Offset.zero;

  /// Pinching and twisting around the followed robot, until the fingers move away.
  bool _aroundRobot = false;

  /// Finger twist when the map started turning in this gesture; null while it does not turn.
  double? _twistFrom;

  Listenable _merge() => Listenable.merge([
    widget.viewport,
    widget.points,
    widget.route,
    if (widget.site != null) widget.site!,
  ]);

  @override
  void initState() {
    super.initState();
    widget.map?.addListener(_onMap);
    _onMap();
  }

  @override
  void didUpdateWidget(MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewport != widget.viewport ||
        oldWidget.points != widget.points ||
        oldWidget.route != widget.route ||
        oldWidget.site != widget.site) {
      _changes = _merge();
    }
    if (oldWidget.map != widget.map) {
      oldWidget.map?.removeListener(_onMap);
      widget.map?.addListener(_onMap);
      _onMap();
    }
  }

  @override
  void dispose() {
    widget.map?.removeListener(_onMap);
    _decodes++;
    _mapImage?.dispose();
    super.dispose();
  }

  /// A new map from the robot: decode it off the frame, newest wins.
  void _onMap() {
    final layer = widget.map?.value;
    if (identical(layer, _decoded)) return;
    _decoded = layer;
    final decode = ++_decodes;
    if (layer == null) {
      _setMap(null, null);
      return;
    }
    unawaited(
      decodeMapImage(layer.png).then((image) {
        if (!mounted || decode != _decodes) {
          image?.dispose();
          return;
        }
        _setMap(image, image == null ? null : layer.header);
      }),
    );
  }

  void _setMap(ui.Image? image, MapHeader? header) {
    if (image == null && _mapImage == null && header == _mapHeader) return;
    setState(() {
      _mapImage?.dispose();
      _mapImage = image;
      _mapHeader = header;
    });
  }

  /// A map to draw the view around, also without a pose.
  bool get _hasMap => _mapImage != null && _mapHeader != null;

  List<Poi> get _pois => widget.site?.value?.pois ?? const <Poi>[];

  /// Middle of the view (map metres), pixels per metre and the turn of the map on screen.
  ({Offset center, double scale, double rotation}) _view() {
    final viewport = widget.viewport;
    final shorter = math.max(1.0, _size.shortestSide);
    final pose = widget.pose;
    if (pose == null && !_hasMap) {
      return (center: Offset.zero, scale: shorter / viewport.span, rotation: 0.0);
    }
    final rotation = viewport.rotationFor(pose?.yaw);
    switch (viewport.mode) {
      case MapMode.follow:
        if (pose == null) return _fit(pose, rotation); // nobody to follow: the whole map
        return (center: Offset(pose.x, pose.y), scale: shorter / viewport.span, rotation: rotation);
      case MapMode.free:
        return (center: viewport.center, scale: shorter / viewport.span, rotation: rotation);
      case MapMode.fit:
        return _fit(pose, rotation);
    }
  }

  /// Everything there is to see, as the map is turned on screen: the robot, the route or path,
  /// the trail, the map and its POIs.
  ({Offset center, double scale, double rotation}) _fit(Pose? pose, double rotation) {
    final c = math.cos(rotation), s = math.sin(rotation);
    var minX = double.infinity, maxX = -double.infinity;
    var minY = double.infinity, maxY = -double.infinity;
    void include(double x, double y) {
      final tx = x * c - y * s, ty = x * s + y * c;
      minX = math.min(minX, tx);
      maxX = math.max(maxX, tx);
      minY = math.min(minY, ty);
      maxY = math.max(maxY, ty);
    }

    if (pose != null) include(pose.x, pose.y);
    for (final p in widget.route.value) {
      include(p.x, p.y);
    }
    for (final p in widget.trail) {
      include(p.dx, p.dy);
    }
    for (final poi in _pois) {
      include(poi.x, poi.y);
    }
    final header = _mapHeader;
    if (header != null && _mapImage != null) {
      final x0 = header.originX, y0 = header.originY;
      final x1 = x0 + header.widthMetres, y1 = y0 + header.heightMetres;
      include(x0, y0);
      include(x1, y0);
      include(x0, y1);
      include(x1, y1);
    }
    if (minX > maxX) {
      minX = maxX = minY = maxY = 0; // nothing at all: the origin
    }
    const margin = 1.5;
    final least = widget.compact ? 6.0 : 8.0;
    final width = math.max(maxX - minX + 2 * margin, least);
    final height = math.max(maxY - minY + 2 * margin, least);
    final mx = (minX + maxX) / 2, my = (minY + maxY) / 2;
    return (
      center: Offset(mx * c + my * s, -mx * s + my * c),
      scale: math.min(math.max(1.0, _size.width) / width, math.max(1.0, _size.height) / height),
      rotation: rotation,
    );
  }

  /// Map metres of a screen offset from the middle of the view.
  static Offset _toMap(Offset screen, double scale, double rotation) {
    final x = screen.dx / scale, y = -screen.dy / scale;
    final c = math.cos(rotation), s = math.sin(rotation);
    return Offset(x * c + y * s, -x * s + y * c);
  }

  /// The map point under [focal] in the view as it is now.
  Offset _mapPointAt(Offset focal) {
    final view = _view();
    return view.center + _toMap(focal - _size.center(Offset.zero), view.scale, view.rotation);
  }

  void _onScaleStart(ScaleStartDetails details) {
    final view = _view();
    _startFocal = details.localFocalPoint;
    _baseScale = view.scale;
    _baseRotation = view.rotation;
    _anchor = _mapPointAt(details.localFocalPoint);
    _aroundRobot = widget.viewport.mode == MapMode.follow && widget.pose != null;
    _twistFrom = null;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final viewport = widget.viewport;
    final shorter = math.max(1.0, _size.shortestSide);
    final span = MapViewport.clampSpan(shorter / (_baseScale * details.scale));
    if (widget.pose == null && !_hasMap) {
      viewport.zoom(span); // around the robot, which looks up the screen
      return;
    }
    // two fingers turning (clockwise is positive on screen) turn the map with them
    final twist = wrapAngle(details.rotation);
    if (_twistFrom == null && details.pointerCount >= 2 && twist.abs() > _twistThreshold) {
      _twistFrom = twist;
    }
    final twistFrom = _twistFrom;
    final turned = twistFrom == null ? null : _baseRotation - (twist - twistFrom);
    if (_aroundRobot) {
      if ((details.localFocalPoint - _startFocal).distance < 24) {
        viewport.zoom(span, rotation: turned);
        return;
      }
      // the fingers moved away: from here on the map point under them stays under them
      _aroundRobot = false;
      _anchor = _mapPointAt(details.localFocalPoint);
    }
    final rotation = turned ?? _baseRotation;
    final focal = details.localFocalPoint - _size.center(Offset.zero);
    viewport.moveTo(_anchor - _toMap(focal, shorter / span, rotation), span, rotation);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final viewport = widget.viewport;
    if (_twistFrom != null && !viewport.headingUp && viewport.rotation.abs() < _snapNorth) {
      viewport.northUp();
    }
    _twistFrom = null;
  }

  void _onLongPress(LongPressStartDetails details) {
    final pick = widget.onLongPress;
    if (pick == null || (widget.pose == null && !_hasMap)) return;
    pick(_mapPointAt(details.localPosition));
  }

  @override
  Widget build(BuildContext context) {
    final interactive = !widget.compact;
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return GestureDetector(
          onScaleStart: interactive ? _onScaleStart : null,
          onScaleUpdate: interactive ? _onScaleUpdate : null,
          onScaleEnd: interactive ? _onScaleEnd : null,
          onDoubleTap: interactive ? widget.viewport.follow : null,
          onLongPressStart: interactive && widget.onLongPress != null ? _onLongPress : null,
          child: ListenableBuilder(
            listenable: _changes,
            builder: (context, _) {
              final view = _view();
              final pose = widget.pose;
              return Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _MapPainter(
                      mapImage: _mapImage,
                      mapHeader: _mapHeader,
                      pois: _pois,
                      highlight: widget.highlight,
                      cloud: widget.lidar ? widget.points.value : null,
                      route: widget.route.value,
                      trail: widget.trail,
                      trailLength: widget.trail.length,
                      marks: widget.marks,
                      markCount: widget.marks.length,
                      pose: pose,
                      center: view.center,
                      scale: view.scale,
                      rotation: view.rotation,
                      modeColor: widget.modeColor,
                      compact: widget.compact,
                    ),
                  ),
                  if (pose == null && !widget.compact)
                    Align(
                      alignment: const Alignment(0, 0.55),
                      child: Text(
                        widget.notLocalizedText,
                        style: Txt.small.copyWith(color: Palette.caution),
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.mapImage,
    required this.mapHeader,
    required this.pois,
    required this.highlight,
    required this.cloud,
    required this.route,
    required this.trail,
    required this.trailLength,
    required this.marks,
    required this.markCount,
    required this.pose,
    required this.center,
    required this.scale,
    required this.rotation,
    required this.modeColor,
    required this.compact,
  });

  final ui.Image? mapImage;
  final MapHeader? mapHeader;
  final List<Poi> pois;
  final String? highlight;
  final Float32List? cloud;
  final List<RoutePoint> route;
  final List<Offset> trail;
  final List<Offset> marks;

  /// The trail and mark lists grow in place; their lengths tell shouldRepaint that they changed.
  final int trailLength;
  final int markCount;
  final Pose? pose;

  /// Middle of the view in map metres, pixels per metre, and the turn of the map on screen
  /// (radians counter-clockwise).
  final Offset center;
  final double scale;
  final double rotation;
  final Color modeColor;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = Palette.night);
    final pose = this.pose;
    final image = mapImage;
    final header = mapHeader;
    if (pose == null && (image == null || header == null)) {
      _robotCentric(canvas, size);
      return;
    }
    final cx = center.dx, cy = center.dy;
    final rc = math.cos(rotation), rs = math.sin(rotation);
    Offset toScreen(double x, double y) {
      final dx = x - cx, dy = y - cy;
      return Offset(
        size.width / 2 + (dx * rc - dy * rs) * scale,
        size.height / 2 - (dx * rs + dy * rc) * scale,
      );
    }

    if (image != null && header != null) _map(canvas, image, header, toScreen);
    _grid(canvas, size, toScreen);

    final cloud = this.cloud;
    if (pose != null && cloud != null) {
      final c = math.cos(pose.yaw), s = math.sin(pose.yaw);
      final xy = <double>[];
      for (var i = 0; i + 2 < cloud.length; i += 3) {
        final z = cloud[i + 2];
        if (z < -0.25 || z > 1.6) continue; // floor and ceiling
        final x = cloud[i], y = cloud[i + 1];
        final o = toScreen(pose.x + c * x - s * y, pose.y + s * x + c * y);
        if (o.dx < 0 || o.dy < 0 || o.dx > size.width || o.dy > size.height) continue;
        xy
          ..add(o.dx)
          ..add(o.dy);
      }
      _points(canvas, xy, 0.55);
    }

    if (trail.length > 1) {
      final first = toScreen(trail.first.dx, trail.first.dy);
      final path = Path()..moveTo(first.dx, first.dy);
      for (final p in trail.skip(1)) {
        final o = toScreen(p.dx, p.dy);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = compact ? 1.2 : 1.6
          ..color = Palette.remote.withValues(alpha: 0.55),
      );
    }

    if (route.length > 1) _route(canvas, toScreen);
    for (final m in marks) {
      _stopPoint(canvas, toScreen(m.dx, m.dy));
    }
    _pois(canvas, toScreen);
    if (pose != null) _robot(canvas, toScreen(pose.x, pose.y), pose.yaw + rotation);
    if (!compact) _scaleBar(canvas, size);
  }

  /// The occupancy map: its top-left corner at the map's largest y, one image pixel per cell.
  void _map(
    Canvas canvas,
    ui.Image image,
    MapHeader header,
    Offset Function(double, double) toScreen,
  ) {
    final corner = toScreen(header.originX, header.originY + header.heightMetres);
    canvas
      ..save()
      ..translate(corner.dx, corner.dy)
      ..rotate(-rotation)
      ..scale(
        header.widthMetres * scale / image.width,
        header.heightMetres * scale / image.height,
      )
      ..drawImage(image, Offset.zero, Paint()..filterQuality = FilterQuality.low)
      ..restore();
  }

  /// POIs: an amber dot with a tick towards the heading the robot takes there, and the name.
  void _pois(Canvas canvas, Offset Function(double, double) toScreen) {
    final radius = compact ? 4.0 : 7.0;
    final tick = Paint()
      ..color = Palette.caution
      ..strokeWidth = compact ? 1.5 : 2.5
      ..strokeCap = StrokeCap.round;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Palette.auto;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white;
    for (final poi in pois) {
      final at = toScreen(poi.x, poi.y);
      // screen y points down, map yaw turns counter-clockwise
      final angle = poi.yaw + rotation;
      final reach = radius + (compact ? 4 : 8);
      canvas.drawLine(at, at + Offset(math.cos(angle), -math.sin(angle)) * reach, tick);
      if (poi.id == highlight) canvas.drawCircle(at, radius + 5, ring);
      canvas.drawCircle(at, radius, Paint()..color = Palette.caution);
      canvas.drawCircle(at, radius, edge);
      if (!compact) _label(canvas, poi.name, at + Offset(radius + 4, -radius - 12));
    }
  }

  void _points(Canvas canvas, List<double> xy, double alpha) {
    if (xy.isEmpty) return;
    canvas.drawRawPoints(
      ui.PointMode.points,
      Float32List.fromList(xy),
      Paint()
        ..color = Palette.text.withValues(alpha: alpha)
        ..strokeWidth = compact ? 1.6 : 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  /// Grid lines at least ~28 px apart, in round metres.
  double get _step {
    for (final step in const [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0]) {
      if (step * scale >= 28) return step;
    }
    return 1000;
  }

  /// Map grid lines over the whole view, however the map is turned.
  void _grid(Canvas canvas, Size size, Offset Function(double, double) toScreen) {
    final step = _step;
    final paint = Paint()
      ..color = const Color(0x14FFFFFF)
      ..strokeWidth = 1;
    final reach = size.longestSide / scale; // more than half the diagonal, in metres
    final cx = center.dx, cy = center.dy;
    for (var x = ((cx - reach) / step).floor() * step; x <= cx + reach; x += step) {
      canvas.drawLine(toScreen(x, cy - reach), toScreen(x, cy + reach), paint);
    }
    for (var y = ((cy - reach) / step).floor() * step; y <= cy + reach; y += step) {
      canvas.drawLine(toScreen(cx - reach, y), toScreen(cx + reach, y), paint);
    }
  }

  void _route(Canvas canvas, Offset Function(double, double) toScreen) {
    final points = [for (final p in route) toScreen(p.x, p.y)];
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final o in points.skip(1)) {
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = compact ? 2 : 3
        ..strokeJoin = StrokeJoin.round
        ..color = Palette.auto.withValues(alpha: 0.85),
    );

    final waypoint = Paint()..color = Palette.auto;
    if (!compact && points.length <= 400) {
      for (final o in points) {
        canvas.drawCircle(o, 2.2, waypoint);
      }
    }

    // start ring, then the stop points with their inspection time
    canvas.drawCircle(
      points.first,
      compact ? 4 : 6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Palette.ok,
    );
    for (var i = 0; i < route.length; i++) {
      if (!route[i].isStop) continue;
      _stopPoint(canvas, points[i]);
      if (!compact) _label(canvas, '${route[i].dwell.round()} s', points[i] + const Offset(9, -18));
    }
  }

  void _stopPoint(Canvas canvas, Offset at) {
    final radius = compact ? 3.5 : 6.0;
    canvas.drawCircle(at, radius, Paint()..color = Palette.caution);
    canvas.drawCircle(
      at,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
  }

  void _robot(Canvas canvas, Offset at, double yaw) {
    final r = compact ? 7.0 : 10.0;
    // screen y points down, map yaw turns counter-clockwise
    Offset dir(double a, double len) => at + Offset(math.cos(a) * len, -math.sin(a) * len);
    final body = Path()
      ..moveTo(dir(yaw, r * 1.4).dx, dir(yaw, r * 1.4).dy)
      ..lineTo(dir(yaw + 2.5, r).dx, dir(yaw + 2.5, r).dy)
      ..lineTo(dir(yaw + math.pi, r * 0.35).dx, dir(yaw + math.pi, r * 0.35).dy)
      ..lineTo(dir(yaw - 2.5, r).dx, dir(yaw - 2.5, r).dy)
      ..close();
    canvas.drawCircle(at, r * 2.2, Paint()..color = modeColor.withValues(alpha: 0.16));
    canvas.drawPath(body, Paint()..color = modeColor);
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
  }

  void _scaleBar(Canvas canvas, Size size) {
    var metres = 1.0;
    for (final m in const [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0]) {
      metres = m;
      if (m * scale >= 60) break;
    }
    final length = metres * scale;
    final left = Offset(14, size.height - 86); // above the icons at the bottom
    final paint = Paint()
      ..color = Palette.text.withValues(alpha: 0.8)
      ..strokeWidth = 2;
    canvas.drawLine(left, left.translate(length, 0), paint);
    canvas.drawLine(left.translate(0, -4), left.translate(0, 4), paint);
    canvas.drawLine(left.translate(length, -4), left.translate(length, 4), paint);
    _label(canvas, '${metres.round()} m', left.translate(length + 6, -8));
  }

  void _label(Canvas canvas, String text, Offset at) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: Txt.small.copyWith(color: Palette.text)),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
    painter.dispose();
  }

  /// Not localized: lidar around the robot, robot low in the middle looking up.
  void _robotCentric(Canvas canvas, Size size) {
    final at = Offset(size.width / 2, size.height * 0.62);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..color = Palette.line;
    final step = _step * 2;
    final reach = size.longestSide / scale;
    for (var r = step; r <= reach; r += step) {
      canvas.drawCircle(at, r * scale, ring);
    }
    final cloud = this.cloud;
    if (cloud != null) {
      final xy = <double>[];
      for (var i = 0; i + 2 < cloud.length; i += 3) {
        final z = cloud[i + 2];
        if (z < -0.25 || z > 1.6) continue;
        xy
          ..add(at.dx - cloud[i + 1] * scale)
          ..add(at.dy - cloud[i] * scale);
      }
      _points(canvas, xy, 0.6);
    }
    _robot(canvas, at, math.pi / 2);
    if (!compact) _scaleBar(canvas, size);
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.mapImage != mapImage ||
      old.mapHeader != mapHeader ||
      old.pois != pois ||
      old.highlight != highlight ||
      old.cloud != cloud ||
      old.route != route ||
      old.trailLength != trailLength ||
      old.markCount != markCount ||
      old.pose?.x != pose?.x ||
      old.pose?.y != pose?.y ||
      old.pose?.yaw != pose?.yaw ||
      old.center != center ||
      old.scale != scale ||
      old.rotation != rotation ||
      old.modeColor != modeColor ||
      old.compact != compact;
}
