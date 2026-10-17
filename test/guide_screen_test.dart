import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molly_controller/net/teleop_client.dart';
import 'package:molly_controller/protocol/messages.dart';
import 'package:molly_controller/screens/guide_screen.dart';
import 'package:molly_controller/theme.dart';

/// Every command the page sent, with its arguments; the robot accepts them all.
class FakeRobot {
  final sent = <String, Map<String, Object?>>{};

  Future<CommandResult> run(
    String name, {
    Map<String, Object?> args = const {},
    String? label,
    bool quiet = false,
  }) async {
    sent[name] = args;
    return const CommandResult(true, '');
  }
}

TeleopClient robotClient(Map<String, dynamic> state) {
  final client = TeleopClient()
    ..welcome = Welcome.fromJson({
      'commands': [
        'tour_start',
        'tour_pause',
        'tour_resume',
        'tour_skip',
        'tour_stop',
        'go_to_poi',
        'nav_speed',
        'people_set',
        'get_site',
      ],
    })
    ..state = RobotState.fromJson(state);
  client.site.value = SiteData.fromJson({
    'name': 'lobby',
    'pois': [
      {'id': 'entrance', 'name': 'Entrance', 'x': 0, 'y': 0},
      {'id': 'cafe', 'name': 'Cafe', 'x': 5, 'y': 2, 'narration': 'Coffee here'},
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
      home: GuideScreen(client: client, language: 'en', onRun: robot.run),
    ),
  );
  await tester.pumpAndSettle();
  return robot;
}

void main() {
  testWidgets('starts a tour and walks to a POI', (tester) async {
    final client = robotClient({
      'speed': {'target': 0.4, 'min': 0.1, 'max': 0.6},
    });
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    expect(find.text('Short tour'), findsOneWidget);
    expect(find.textContaining('Entrance → Cafe'), findsOneWidget);
    expect(find.text('0.40 m/s'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tour-start-short')));
    await tester.pumpAndSettle();
    expect(robot.sent['tour_start'], {'tour_id': 'short'});

    await tester.tap(find.byKey(const ValueKey('poi-go-cafe')));
    await tester.pumpAndSettle();
    expect(robot.sent['go_to_poi'], {'id': 'cafe'});
  });

  testWidgets('the tour under way is paused and ended from its card', (tester) async {
    final client = robotClient({
      'tour': {
        'state': 'running',
        'tour_id': 'short',
        'name': 'Short tour',
        'index': 0,
        'total': 2,
        'poi_id': 'entrance',
        'poi_name': 'Entrance',
        'activity': 'narrating',
      },
    });
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    expect(find.textContaining('Stop 1/2'), findsOneWidget);
    expect(find.textContaining('Talking'), findsOneWidget);
    // a tour is under way: no second one
    final start = tester.widget<FilledButton>(find.byKey(const ValueKey('tour-start-short')));
    expect(start.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('tour-pause')));
    await tester.pumpAndSettle();
    expect(robot.sent.containsKey('tour_pause'), isTrue);

    await tester.tap(find.byKey(const ValueKey('tour-stop')));
    await tester.pumpAndSettle();
    expect(robot.sent.containsKey('tour_stop'), isTrue);
  });
}
