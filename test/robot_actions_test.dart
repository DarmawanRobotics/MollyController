import 'package:flutter_test/flutter_test.dart';
import 'package:molly_controller/robot_actions.dart';

void main() {
  test('the Lite3 commands and gestures read in both languages', () {
    expect(robotAction('gait_slow').label('id'), 'Gait pelan');
    expect(robotAction('gait_slow').label('en'), 'Slow gait');
    expect(robotAction('keep_stepping_on').label('en'), 'Step in place');
    expect(robotAction('look_left').label('id'), 'Tengok kiri');
    expect(robotAction('bow').label('en'), 'Bow');
  });

  test('what drops the robot or hands its control away is asked first', () {
    for (final name in ['emergency_stop', 'reset_zero', 'manual_mode']) {
      expect(robotAction(name).confirm, isTrue, reason: name);
    }
    for (final name in ['stand_up', 'sit_down', 'hello', 'nod', 'gait_fast', 'navigation_mode']) {
      expect(robotAction(name).confirm, isFalse, reason: name);
    }
  });

  test('an unknown command gets a label from its name', () {
    final action = robotAction('wag_tail');
    expect(action.label('en'), 'Wag tail');
    expect(action.label('id'), 'Wag tail');
    expect(action.confirm, isFalse);
  });
}
