import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molly_controller/net/teleop_client.dart';
import 'package:molly_controller/protocol/messages.dart';
import 'package:molly_controller/screens/site_screen.dart';
import 'package:molly_controller/theme.dart';

/// Every command the page sent, with its arguments; the robot accepts them all and has two sites.
class FakeRobot {
  final sent = <String, Map<String, Object?>>{};
  int siteLists = 0;

  Future<CommandResult> run(
    String name, {
    Map<String, Object?> args = const {},
    String? label,
    bool quiet = false,
  }) async {
    sent[name] = args;
    if (name == 'site_list') {
      siteLists++;
      return const CommandResult(true, '', {
        'sites': ['lobby', 'gallery'],
        'active': 'lobby',
      });
    }
    return const CommandResult(true, '');
  }
}

/// Lobby loaded, three AprilTags recorded, the robot localized at (1, 2).
const lobby = <String, dynamic>{
  'site': {'name': 'lobby', 'map': true, 'pois': 2, 'tours': 1, 'tags': 3},
  'pose': [1.0, 2.0, 0.0],
};

TeleopClient robotClient(Map<String, dynamic> state) {
  final client = TeleopClient()
    ..welcome = Welcome.fromJson({
      'commands': [
        'site_list',
        'site_load',
        'map_start',
        'map_stop',
        'map_save',
        'record_tags',
        'localize',
        'record_start',
        'record_stop',
        'poi_add',
        'poi_update',
        'poi_delete',
        'tour_save',
        'tour_delete',
      ],
      'gestures': ['hello', 'nod'],
    })
    ..state = RobotState.fromJson(state);
  client.site.value = SiteData.fromJson({
    'name': 'lobby',
    'pois': [
      {'id': 'entrance', 'name': 'Entrance', 'x': 0, 'y': 0},
      {'id': 'cafe', 'name': 'Cafe', 'x': 5, 'y': 2, 'narration': 'Coffee here', 'dwell': 10},
    ],
    'tours': [
      {
        'id': 'short',
        'name': 'Short tour',
        'poi_ids': ['entrance', 'cafe'],
      },
    ],
  });
  return client;
}

Future<FakeRobot> openPage(WidgetTester tester, TeleopClient client) async {
  // a Retroid Pocket in landscape
  tester.view.physicalSize = const Size(1334, 750);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final robot = FakeRobot();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: SiteScreen(client: client, language: 'en', onRun: robot.run),
    ),
  );
  await tester.pumpAndSettle();
  return robot;
}

/// Scrolls the control with [key] into view and taps it.
Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists the sites and loads another one', (tester) async {
    final client = robotClient(lobby);
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    expect(robot.siteLists, 1);
    expect(find.text('gallery'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('3 AprilTags recorded'), findsOneWidget);

    await tapKey(tester, 'site-load-gallery');
    expect(robot.sent['site_load'], {'site': 'gallery'});
    expect(robot.siteLists, 2);
    expect(find.text('Site gallery loaded'), findsOneWidget);
  });

  testWidgets('a new map takes a free site name, cleaned up', (tester) async {
    final client = robotClient(lobby);
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    await tapKey(tester, 'map-new');
    await tester.enterText(find.byKey(const ValueKey('map-name')), 'Gallery');
    await tapKey(tester, 'map-name-start');
    expect(find.text('This site exists: Extend continues its map'), findsOneWidget);
    expect(robot.sent.containsKey('map_start'), isFalse);

    await tester.enterText(find.byKey(const ValueKey('map-name')), 'East Wing');
    await tapKey(tester, 'map-name-start');
    expect(robot.sent['map_start'], {'site': 'east_wing', 'reset': true});
  });

  testWidgets('saves the map being made', (tester) async {
    final client = robotClient({
      ...lobby,
      'mapping': {'active': true, 'site': 'lobby', 'scans': 12, 'area': 84.4},
    });
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    expect(find.text('Mapping lobby'), findsOneWidget);
    expect(find.text('12 scans · 84 m² known'), findsOneWidget);
    // no second map while this one is made
    expect(find.byKey(const ValueKey('map-new')), findsNothing);

    await tapKey(tester, 'map-save');
    expect(robot.sent.containsKey('map_save'), isTrue);
    expect(find.text('Map saved'), findsOneWidget);
  });

  testWidgets('edits, moves and deletes a POI', (tester) async {
    final client = robotClient(lobby);
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    await tapKey(tester, 'site-poi-cafe');
    expect(find.text('Edit POI'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('poi-narration')), 'Coffee and cake');
    await tapKey(tester, 'poi-here');
    await tapKey(tester, 'poi-save');
    expect(robot.sent['poi_update'], {
      'poi': {
        'id': 'cafe',
        'name': 'Cafe',
        'description': '',
        'narration': 'Coffee and cake',
        'language': '',
        'gesture': '',
        'dwell': 10.0,
        'here': true,
      },
    });

    await tapKey(tester, 'site-poi-entrance');
    await tapKey(tester, 'poi-delete');
    expect(robot.sent['poi_delete'], {'id': 'entrance'});
  });

  testWidgets('builds a tour from the POIs', (tester) async {
    final client = robotClient(lobby);
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    await tapKey(tester, 'tour-new');
    await tester.enterText(find.byKey(const ValueKey('tour-name')), 'Cafe first');
    await tapKey(tester, 'tour-save');
    expect(find.text('Pick at least one stop'), findsOneWidget);
    expect(robot.sent.containsKey('tour_save'), isFalse);

    await tapKey(tester, 'tour-add-cafe');
    await tapKey(tester, 'tour-add-entrance');
    await tapKey(tester, 'tour-save');
    expect(robot.sent['tour_save'], {
      'tour': {
        'id': '',
        'name': 'Cafe first',
        'description': '',
        'poi_ids': ['cafe', 'entrance'],
        'return_poi_id': '',
      },
    });
  });

  testWidgets('a POI is only added where the robot knows it stands', (tester) async {
    final client = robotClient({
      'site': {'name': 'lobby'},
    });
    addTearDown(client.dispose);
    await openPage(tester, client);

    expect(find.text('Localize the robot to add a POI'), findsOneWidget);
    final add = tester.widget<TextButton>(find.byKey(const ValueKey('poi-add')));
    expect(add.onPressed, isNull);
  });
}
