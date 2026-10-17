import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molly_controller/protocol/messages.dart';
import 'package:molly_controller/theme.dart';
import 'package:molly_controller/widgets/glance.dart';

Future<void> show(WidgetTester tester, Map<String, dynamic> state, {bool showLoad = true}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          // as wide as the small view on a Retroid Pocket
          child: SizedBox(
            width: 180,
            child: GlancePanel(
              state: RobotState.fromJson(state),
              language: 'id',
              showLoad: showLoad,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('the people and the load at a glance', (tester) async {
    await show(tester, {
      'people': {'on': true, 'state': 'running', 'count': 4},
      'health': {
        'ok': true,
        'cpu': 23.0,
        'gpu': 41.0,
        'ram': 33.0,
        'ram_used': 5.1,
        'ram_total': 15.3,
        'temp': 53.0,
      },
    });
    expect(find.text('4 orang'), findsOneWidget);
    expect(find.text('CPU 23%  GPU 41%'), findsOneWidget);
    expect(find.text('RAM 5.1/15.3 GB  53°C'), findsOneWidget);
  });

  testWidgets('off and no-GPU states read plainly', (tester) async {
    await show(tester, {
      'people': {'on': false, 'state': 'off'},
      'health': {'ok': true, 'cpu': 95.0, 'ram': 40.0},
    });
    expect(find.text('Orang: mati'), findsOneWidget);
    expect(find.text('CPU 95%  GPU –'), findsOneWidget);
    expect(find.text('RAM 40%'), findsOneWidget);

    await show(tester, {'health': {'ok': true, 'cpu': 10.0}}, showLoad: false);
    expect(find.byType(GlancePanel), findsOneWidget);
    expect(find.textContaining('CPU'), findsNothing);
  });

  testWidgets('nearly full memory stands out in red', (tester) async {
    await show(tester, {
      'health': {'ok': false, 'cpu': 20.0, 'ram': 98.7, 'ram_used': 15.1, 'ram_total': 15.3},
    });
    final text = tester.widget<Text>(find.text('RAM 15.1/15.3 GB'));
    expect(text.style?.color, Palette.stop);
  });

  testWidgets('what the robot says, its visitors and the greeter', (tester) async {
    await show(tester, {
      'speech': {'state': 'speaking', 'text': 'Selamat datang di museum', 'queued': 0},
      'visitors': {'count': 3, 'front': 1, 'behind': 2, 'nearest': 1.2},
      'greeter': {'enabled': true, 'state': 'idle'},
    });
    expect(find.text('Selamat datang di museum'), findsOneWidget);
    expect(find.text('3 pengunjung · 2 mengikuti'), findsOneWidget);
    expect(find.text('Penyapa nyala'), findsOneWidget);

    // quiet, nobody around, greeter off
    await show(tester, {
      'speech': {'state': 'done', 'text': 'Selamat datang di museum'},
      'visitors': {'count': 0},
      'greeter': {'enabled': false},
    });
    expect(find.text('Selamat datang di museum'), findsNothing);
    expect(find.text('Tak ada pengunjung'), findsOneWidget);
    expect(find.text('Penyapa nyala'), findsNothing);
  });

  testWidgets('without people or load figures nothing shows', (tester) async {
    await show(tester, {
      'health': {'ok': true, 'issues': []},
    });
    expect(find.byType(Text), findsNothing);
  });
}
