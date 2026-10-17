import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molly_controller/input/gamepad_input.dart';
import 'package:molly_controller/l10n.dart';
import 'package:molly_controller/protocol/messages.dart';
import 'package:molly_controller/protocol/streams.dart';
import 'package:molly_controller/robot_actions.dart';

/// One datagram as molly_bridge/protocol.py chunk() packs it.
Uint8List datagram(int stream, int frame, int index, int count, List<int> payload) {
  final header = ByteData(9)
    ..setUint8(0, stream)
    ..setUint32(1, frame, Endian.little)
    ..setUint16(5, index, Endian.little)
    ..setUint16(7, count, Endian.little);
  return Uint8List.fromList([
    ...ascii.encode('MLY1'),
    ...header.buffer.asUint8List(),
    ...payload,
  ]);
}

void main() {
  group('Reassembler', () {
    test('joins chunks that arrive out of order', () {
      final r = Reassembler();
      expect(r.push(datagram(1, 7, 1, 3, [4, 5])), isNull);
      expect(r.push(datagram(1, 7, 0, 3, [1, 2, 3])), isNull);
      final frame = r.push(datagram(1, 7, 2, 3, [6]));
      expect(frame, isNotNull);
      expect(frame!.stream, 1);
      expect(frame.payload, [1, 2, 3, 4, 5, 6]);
    });

    test('drops a late chunk of an older frame', () {
      final r = Reassembler();
      expect(r.push(datagram(2, 10, 0, 2, [1])), isNull);
      expect(r.push(datagram(2, 11, 0, 2, [9])), isNull);
      expect(r.push(datagram(2, 10, 1, 2, [2])), isNull);
      expect(r.push(datagram(2, 11, 1, 2, [8]))!.payload, [9, 8]);
    });

    test('handles the frame counter wrapping around', () {
      final r = Reassembler();
      expect(r.push(datagram(3, 0xFFFFFFFF, 0, 2, [1])), isNull);
      expect(r.push(datagram(3, 0, 0, 1, [5]))!.payload, [5]);
    });

    test('ignores junk', () {
      final r = Reassembler();
      expect(r.push(Uint8List.fromList(utf8.encode('{"t":"state"}'))), isNull);
      expect(r.push(datagram(1, 1, 3, 2, [1])), isNull);
    });
  });

  test('lidar points are int16 centimetres', () {
    final bytes = ByteData(12)
      ..setInt16(0, 150, Endian.little)
      ..setInt16(2, -20, Endian.little)
      ..setInt16(4, 5, Endian.little)
      ..setInt16(6, -300, Endian.little)
      ..setInt16(8, 0, Endian.little)
      ..setInt16(10, 100, Endian.little);
    final points = decodePoints(bytes.buffer.asUint8List());
    expect(points.length, 6);
    expect(points[0], closeTo(1.5, 1e-6));
    expect(points[1], closeTo(-0.2, 1e-6));
    expect(points[3], closeTo(-3.0, 1e-6));
  });

  test('route payload', () {
    final route = decodeRoute(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            't': 'route',
            'points': [
              [0, 0, 0],
              [2.5, 1, 10],
              ['bad'],
            ],
          }),
        ),
      ),
    );
    expect(route.length, 2);
    expect(route[1].isStop, isTrue);
    expect(decodeRoute(Uint8List.fromList([1, 2, 3])), isEmpty);
  });

  test('map payload: JSON header, then the PNG', () {
    Uint8List payload(Object header, List<int> png) {
      final json = utf8.encode(jsonEncode(header));
      final length = ByteData(4)..setUint32(0, json.length, Endian.little);
      return Uint8List.fromList([...length.buffer.asUint8List(), ...json, ...png]);
    }

    const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];
    final layer = decodeMap(
      payload({
        't': 'map',
        'rev': 7,
        'res': 0.1,
        'ox': -2.5,
        'oy': -1.0,
        'w': 40,
        'h': 30,
        'site': 'lobby',
      }, png),
    );
    expect(layer, isNotNull);
    expect(layer!.header.rev, '7');
    expect(layer.header.resolution, 0.1);
    expect(layer.header.originX, -2.5);
    expect(layer.header.widthMetres, closeTo(4.0, 1e-9));
    expect(layer.header.heightMetres, closeTo(3.0, 1e-9));
    expect(layer.header.site, 'lobby');
    expect(layer.png.length, png.length);
    expect(decodeMap(payload({'res': 0, 'ox': 0, 'oy': 0, 'w': 4, 'h': 4}, png)), isNull);
    expect(decodeMap(payload({'res': 0.05, 'ox': 0, 'oy': 0, 'w': 4}, png)), isNull);
    final notPng = [1, 2, 3, 4, 5, 6, 7, 8];
    expect(decodeMap(payload({'res': 0.05, 'ox': 0, 'oy': 0, 'w': 4, 'h': 4}, notPng)), isNull);
    expect(decodeMap(Uint8List.fromList([255, 0, 0, 0, 1])), isNull);
    expect(decodeMap(Uint8List.fromList([1, 2])), isNull);
  });

  test('site payload: POIs and tours, broken entries skipped', () {
    final site = decodeSite(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            't': 'site',
            'rev': 3,
            'name': 'lobby',
            'pois': [
              {
                'id': 'entrance',
                'name': 'Entrance',
                'x': 1.0,
                'y': 2,
                'yaw': 1.57,
                'narration': 'Welcome',
                'language': 'en',
                'gesture': 'hello',
                'dwell': 5,
              },
              {'id': 'no_position', 'name': 'x'},
              'junk',
            ],
            'tours': [
              {
                'id': 'short',
                'name': 'Short tour',
                'poi_ids': ['entrance', 7],
                'return_poi_id': 'entrance',
              },
              {'name': 'no id'},
            ],
          }),
        ),
      ),
    )!;
    expect(site.rev, '3');
    expect(site.name, 'lobby');
    expect(site.pois.single.yaw, 1.57);
    expect(site.poi('entrance')!.gesture, 'hello');
    expect(site.poi('missing'), isNull);
    expect(site.tours.single.poiIds, ['entrance']);
    expect(site.tour('short')!.returnPoiId, 'entrance');
    expect(site.pois.first.toJson()['dwell'], 5.0);
    expect(site.tours.first.toJson()['poi_ids'], ['entrance']);
    expect(decodeSite(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('Molly state: site, mapping, walking, tour, speech, visitors, greeter', () {
    final state = RobotState.fromJson({
      'site': {'name': 'lobby', 'map': true, 'pois': 4, 'tours': 1, 'tags': 3, 'rev': 9},
      'mapping': {'active': true, 'site': 'lobby', 'scans': 120, 'area': 85.5},
      'planner': {'state': 'following', 'goal': 'entrance', 'remaining': 3.2, 'msg': ''},
      'tour': {
        'state': 'running',
        'tour_id': 'short',
        'name': 'Short tour',
        'index': 1,
        'total': 3,
        'poi_id': 'cafe',
        'poi_name': 'Cafe',
        'activity': 'narrating',
        'msg': '',
      },
      'speech': {'state': 'speaking', 'text': 'Welcome', 'queued': 2},
      'visitors': {'count': 3, 'front': 1, 'behind': 2, 'nearest': 1.4},
      'greeter': {'enabled': true, 'state': 'idle'},
      'map_rev': 12,
    });
    expect(state.site!.loaded, isTrue);
    expect(state.site!.rev, '9');
    expect(state.site!.tags, 3);
    expect(state.mapping!.active, isTrue);
    expect(state.mapping!.area, 85.5);
    expect(state.planner!.walking, isTrue);
    expect(state.planner!.remaining, 3.2);
    expect(state.tour!.running, isTrue);
    expect(state.tour!.index, 1);
    expect(state.tour!.poiName, 'Cafe');
    expect(state.speech!.speaking, isTrue);
    expect(state.speech!.queued, 2);
    expect(state.visitors!.behind, 2);
    expect(state.greeter!.enabled, isTrue);
    expect(state.mapRev, '12');
    final broken = RobotState.fromJson({'tour': 'x', 'planner': null, 'map_rev': 'abc'});
    expect(broken.tour, isNull);
    expect(broken.planner, isNull);
    expect(broken.site, isNull);
    expect(broken.mapRev, 'abc');
    expect(const TourStatus().active, isFalse);
    expect(const PlannerStatus(state: 'arrived').walking, isFalse);
    expect(RobotState.fromJson({'visitors': {}}).visitors!.nearest, isNull);
    expect(revision(3.0), '3');
    expect(revision(null), isNull);
  });

  test('site names for a new map', () {
    expect(siteName(' Lobby East '), 'lobby_east');
    expect(siteName('Lt.2-Hall'), 'lt2-hall');
    expect(siteName('!!!'), isNull);
    expect(siteName('_x'), isNull);
  });

  test('state tolerates missing and broken fields', () {
    final state = RobotState.fromJson({
      't': 'state',
      'seq': 4,
      'mode': 'remote',
      'pose': [1.0, 2.0, 0.5],
      'battery': {'pct': 77.0, 'v': 25.1},
      'health': {'ok': false, 'issues': ['odometry lost']},
      'cmd': [0.2, 'x', 0.1],
      'estop': true,
      'field': 'limited',
    });
    expect(state.remote, isTrue);
    expect(state.pose!.yaw, 0.5);
    expect(state.battery!.percent, 77.0);
    expect(state.cmd, [0.2, 0.0, 0.1]);
    expect(state.healthIssues, ['odometry lost']);
    expect(RobotState.fromJson({'pose': null}).pose, isNull);
    final tags = RobotState.fromJson({
      'tags': [
        [3, 0.1, 0.2, 0.3, 0.2, 0.3, 0.4, 0.1, 0.4],
        [4, 'x'],
      ],
    }).tags;
    expect(tags.length, 1);
    expect(tags.first.id, 3);
    expect(tags.first.corners[2], closeTo(0.3, 1e-9));
  });

  test('walking speed in the state', () {
    final state = RobotState.fromJson({
      'speed': {'target': 0.4, 'min': 0.1, 'max': 0.6},
    });
    expect(state.speed!.max, 0.6);
    expect(RobotState.fromJson({'speed': {'target': 'x', 'min': 0.1, 'max': 0.6}}).speed, isNull);
    expect(RobotState.fromJson({'speed': {'target': 0.4, 'min': 0.7, 'max': 0.6}}).speed, isNull);
  });

  test('people and the robot load in the state', () {
    final state = RobotState.fromJson({
      'people': {'on': true, 'state': 'running', 'count': 2, 'ms': 90, 'age': 1, 'backend': 'cpu',
        'boxes': [[0.1, 0.2, 0.3, 0.9, 0.87], [1, 2], 'x']},
      'health': {'ok': true, 'issues': [], 'cpu': 12.0, 'gpu': null, 'ram_used': 4.2},
    });
    expect(state.people!.count, 2);
    expect(state.people!.boxes.single.y2, 0.9);
    expect(state.people!.boxes.single.score, 0.87);
    expect(state.people!.latencyMs, 90);
    expect(state.load!.cpu, 12.0);
    expect(state.load!.gpu, isNull);
    expect(state.load!.ramUsed, 4.2);
    expect(state.healthOk, isTrue);
    expect(RobotState.fromJson({'health': {'ok': true, 'issues': []}}).load, isNull);
    expect(PeopleStatus.fromJson({})!.state, 'offline');
    expect(PeopleStatus.fromJson({'state': 'loading'})!.count, isNull);
  });

  test('localization source kinds', () {
    RobotState loc(String v) => RobotState.fromJson({'localization': v});
    expect(loc('none').localizationKind, 'none');
    expect(loc('start position').localizationKind, 'start');
    expect(loc('RViz 2D Pose Estimate').localizationKind, 'pose');
    final tag = loc('apriltag "base_map" (auto start)');
    expect(tag.localizationKind, 'tag');
    expect(tag.localizationTag, 'base_map');
    expect(loc('start position').localizationTag, isNull);
    expect(loc('tag:lobby_1').localizationKind, 'tag');
    expect(loc('tag:lobby_1').localizationTag, 'lobby_1');
    expect(loc('origin').localizationKind, 'start');
    expect(loc('pose_estimate').localizationKind, 'pose');
  });

  test('welcome without robot_commands derives them from commands', () {
    final welcome = Welcome.fromJson({
      'commands': ['estop', 'nav_start', 'stand_up', 'sit_down', 'list_routes'],
      'limits': [1.0, 0.5, 1.5],
    });
    expect(welcome.robotCommands, ['stand_up', 'sit_down']);
    expect(welcome.limits, [1.0, 0.5, 1.5]);
    final explicit = Welcome.fromJson({
      'commands': ['stand_up', 'sdk_control_right'],
      'robot_commands': ['sdk_control_right', 'stand_up'],
    });
    expect(explicit.robotCommands.first, 'sdk_control_right');
    expect(explicit.video, isNull); // an older robot: JPEG frames only
  });

  test('welcome names the protocol, the gestures and the features', () {
    final welcome = Welcome.fromJson({
      'protocol': 'molly-1',
      'commands': ['estop', 'tour_start', 'stand_up', 'hello'],
      'gestures': ['hello', 'nod'],
      'features': ['guide', 'speech'],
    });
    expect(welcome.protocol, 'molly-1');
    expect(welcome.gestures, ['hello', 'nod']);
    expect(welcome.hasFeature('guide'), isTrue);
    expect(welcome.hasFeature('mapping'), isFalse);
    expect(welcome.robotCommands, ['stand_up', 'hello']);
    expect(Beacon.fromJson({'name': 'molly', 'site': 'lobby'}, '10.0.0.2').site, 'lobby');
    expect(Beacon.fromJson({}, '10.0.0.2').name, '10.0.0.2');
  });

  test('welcome offers the WebRTC video of the robot', () {
    final welcome = Welcome.fromJson({
      'commands': ['estop'],
      'video': {'port': 8890, 'path': 'camera'},
    });
    expect(
      welcome.video!.whep('192.168.234.234').toString(),
      'http://192.168.234.234:8890/camera/whep',
    );
    expect(welcome.video!.whep('robot.local').path, '/camera/whep');
    for (final bad in [
      {'port': 0, 'path': 'camera'},
      {'port': '8890', 'path': 'camera'},
      {'port': 8890, 'path': ''},
      {'port': 8890, 'path': '../admin'},
      {'port': 8890, 'path': 'cam?x=1'},
      'camera',
    ]) {
      expect(Welcome.fromJson({'video': bad}).video, isNull, reason: '$bad');
    }
  });

  test('stick dead zone and rescale', () {
    expect(GamepadInput.shaped(0.05), 0);
    expect(GamepadInput.shaped(1.0), 1.0);
    expect(GamepadInput.shaped(-1.0), -1.0);
    expect(GamepadInput.shaped(0.56), closeTo(0.5, 1e-9));
  });

  test('labels: both languages, unknown commands get a readable name', () {
    expect(tr('id', 'retry'), 'Coba lagi');
    expect(tr('en', 'in_use_by', {'who': 'Retroid'}), 'In use by Retroid');
    expect(tr('id', 'port'), 'Port');
    expect(robotAction('stand_up').label('id'), 'Berdiri');
    expect(robotAction('front_flip').label('en'), 'Front flip');
    expect(robotAction('emergency_stop').confirm, isTrue);
    expect(tr('id', 'nav_FOLLOWING'), 'Berjalan');
  });
}
