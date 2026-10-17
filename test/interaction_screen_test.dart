import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molly_controller/net/teleop_client.dart';
import 'package:molly_controller/protocol/messages.dart';
import 'package:molly_controller/screens/interaction_screen.dart';
import 'package:molly_controller/theme.dart';

/// Every command the page sent, with its arguments; the robot accepts them all and knows when the
/// cafe opens.
class FakeRobot {
  final sent = <String, Map<String, Object?>>{};

  Future<CommandResult> run(
    String name, {
    Map<String, Object?> args = const {},
    String? label,
    bool quiet = false,
  }) async {
    sent[name] = args;
    if (name == 'ask') return const CommandResult(true, '', {'answer': 'The cafe opens at nine.'});
    return const CommandResult(true, '');
  }
}

TeleopClient robotClient(Map<String, dynamic> state) {
  return TeleopClient()
    ..welcome = Welcome.fromJson({
      'commands': ['say', 'stop_speech', 'greet', 'greeter_set', 'gesture', 'ask'],
      'gestures': ['hello', 'nod', 'dance'],
    })
    ..state = RobotState.fromJson(state);
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
      home: InteractionScreen(client: client, language: 'en', onRun: robot.run),
    ),
  );
  await tester.pumpAndSettle();
  return robot;
}

/// Scrolls [finder] into view and taps it.
Future<void> tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, String key) => tapOn(tester, find.byKey(ValueKey(key)));

void main() {
  testWidgets('says typed text and quick phrases in the chosen language', (tester) async {
    final client = robotClient({});
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    await tester.enterText(find.byKey(const ValueKey('say-text')), 'Hello everyone');
    await tapKey(tester, 'say-send');
    expect(robot.sent['say'], {'text': 'Hello everyone', 'lang': 'en', 'interrupt': false});
    expect(find.text('Sent to the speaker'), findsOneWidget);

    await tapOn(tester, find.text('Indonesia'));
    await tapKey(tester, 'say-interrupt');
    await tapKey(tester, 'phrase-welcome');
    expect(robot.sent['say'], {
      'text': 'Selamat datang! Saya Molly, pemandu Anda hari ini.',
      'lang': 'id',
      'interrupt': true,
    });
  });

  testWidgets('shows what the robot says and stops it', (tester) async {
    final client = robotClient({
      'speech': {'state': 'speaking', 'text': 'Welcome to the museum', 'queued': 2},
    });
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    expect(find.text('Speaking'), findsOneWidget);
    expect(find.text('“Welcome to the museum”'), findsOneWidget);
    expect(find.text('2 more waiting'), findsOneWidget);

    await tapKey(tester, 'speech-stop');
    expect(robot.sent.containsKey('stop_speech'), isTrue);
  });

  testWidgets('asks the robot a question and shows its answer', (tester) async {
    final client = robotClient({});
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    await tester.ensureVisible(find.byKey(const ValueKey('ask-text')));
    await tester.enterText(find.byKey(const ValueKey('ask-text')), 'When does the cafe open?');
    await tapKey(tester, 'ask-send');
    expect(robot.sent['ask'], {
      'question': 'When does the cafe open?',
      'lang': 'en',
      'speak': true,
    });
    expect(find.text('When does the cafe open?'), findsOneWidget);
    expect(find.text('The cafe opens at nine.'), findsOneWidget);
  });

  testWidgets('visitors, the greeter and the gestures', (tester) async {
    final client = robotClient({
      'visitors': {'count': 3, 'front': 1, 'behind': 2, 'nearest': 1.24},
      'greeter': {'enabled': false, 'state': 'idle'},
    });
    addTearDown(client.dispose);
    final robot = await openPage(tester, client);

    expect(find.text('3 around · 1 in front · 2 behind'), findsOneWidget);
    expect(find.text('Nearest 1.2 m away'), findsOneWidget);

    await tapKey(tester, 'greeter-switch');
    expect(robot.sent['greeter_set'], {'enabled': true});
    await tapKey(tester, 'greet');
    expect(robot.sent.containsKey('greet'), isTrue);

    await tapKey(tester, 'gesture-hello');
    expect(robot.sent['gesture'], {'name': 'hello'});

    // dancing moves the whole robot: asked first
    await tapKey(tester, 'gesture-dance');
    expect(robot.sent['gesture'], {'name': 'hello'});
    await tapOn(tester, find.text('Run'));
    expect(robot.sent['gesture'], {'name': 'dance'});
  });
}
