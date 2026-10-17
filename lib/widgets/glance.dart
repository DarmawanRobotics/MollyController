import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../protocol/messages.dart';
import '../theme.dart';
import 'hud.dart';

/// What the robot says, who is around it and how hard it works, at a glance under the small view:
/// the speech under way, the visitors and the greeter, the people in view and the computer's load.
class GlancePanel extends StatelessWidget {
  const GlancePanel({
    super.key,
    required this.state,
    required this.language,
    required this.showLoad,
    this.onTap,
  });

  final RobotState state;
  final String language;
  final bool showLoad;
  final VoidCallback? onTap;

  String t(String key, [Map<String, Object> args = const {}]) => tr(language, key, args);

  @override
  Widget build(BuildContext context) {
    final speech = state.speech;
    final visitors = state.visitors;
    final greeter = state.greeter;
    final people = state.people;
    final load = state.load;
    final rows = <Widget>[
      if (speech != null && speech.speaking)
        _row(
          Icons.record_voice_over_rounded,
          Palette.auto,
          speech.text.isEmpty ? t('speech_speaking') : speech.text,
          strong: true,
        ),
      if (visitors != null) _visitorsRow(visitors),
      if (greeter != null && greeter.enabled)
        _row(Icons.waving_hand_rounded, Palette.ok, t('greeter_on')),
      if (people != null) _peopleRow(people),
      if (showLoad && load != null) ..._loadRows(load),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Glass(
        radius: 12,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    );
  }

  /// The visitors around the robot (lidar), and how many follow it.
  Widget _visitorsRow(Visitors visitors) {
    final count = visitors.count;
    if (count == 0) return _row(Icons.groups_rounded, Palette.muted, t('visitors_none_short'));
    return _row(
      Icons.groups_rounded,
      Palette.auto,
      [
        count == 1 ? t('visitor_one') : t('visitors_count', {'n': count}),
        if (visitors.behind > 0) t('visitors_following', {'n': visitors.behind}),
      ].join(' · '),
      strong: true,
    );
  }

  Widget _peopleRow(PeopleStatus people) {
    switch (people.state) {
      case 'running':
        final count = people.count;
        final text = count == null
            ? t('people_waiting')
            : (count == 1 ? t('person_one') : t('people_count', {'n': count}));
        return _row(Icons.person_rounded, Palette.auto, text, strong: count != null);
      case 'loading':
        return _row(Icons.person_rounded, Palette.caution, t('people_loading'));
      case 'off':
        return _row(Icons.person_off_rounded, Palette.muted, t('people_off'));
      default:
        return _row(Icons.person_off_rounded, Palette.stop, t('people_error'));
    }
  }

  List<Widget> _loadRows(SystemLoad load) {
    String percent(double? value) => value == null ? '–' : '${value.round()}%';
    // 0 fine, 1 busy, 2 nearly full
    int level(double? value, double busy, double full) =>
        value == null || value < busy ? 0 : (value < full ? 1 : 2);
    const tones = [Palette.muted, Palette.caution, Palette.stop];
    final compute = [load.cpu, load.gpu].whereType<double>().fold<double>(0, math.max);
    final used = load.ramUsed;
    final total = load.ramTotal;
    final ram = used != null && total != null
        ? '${used.toStringAsFixed(1)}/${total.toStringAsFixed(1)} GB'
        : percent(load.ram);
    final temp = load.temp;
    final memory = math.max(level(load.ram, 80, 90), level(temp, 75, 85));
    return [
      _row(
        Icons.memory_rounded,
        tones[level(compute, 75, 90)],
        'CPU ${percent(load.cpu)}  GPU ${percent(load.gpu)}',
      ),
      _row(
        Icons.developer_board_rounded,
        tones[memory],
        temp == null ? 'RAM $ram' : 'RAM $ram  ${temp.round()}°C',
        strong: memory == 2,
      ),
    ];
  }

  Widget _row(IconData icon, Color color, String text, {bool strong = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: strong ? Txt.label.copyWith(color: color) : Txt.small,
            ),
          ),
        ],
      ),
    );
  }
}
