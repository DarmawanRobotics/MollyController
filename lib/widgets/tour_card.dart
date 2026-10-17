import 'package:flutter/material.dart';

import '../l10n.dart';
import '../protocol/messages.dart';
import '../theme.dart';
import 'hud.dart';

/// Colour and icon of a tour state.
({Color color, IconData icon}) tourLook(String state) => switch (state) {
  'running' => (color: Palette.auto, icon: Icons.tour_rounded),
  'paused' => (color: Palette.caution, icon: Icons.pause_circle_rounded),
  'error' => (color: Palette.stop, icon: Icons.error_rounded),
  _ => (color: Palette.muted, icon: Icons.hourglass_top_rounded),
};

/// One line about where the tour is: `Stop 2/5 · Cafe · Talking`, then the robot's message.
String tourProgress(TourStatus tour, String language) {
  String t(String key, [Map<String, Object> args = const {}]) => tr(language, key, args);
  final activity = tour.activity.isEmpty ? '' : t('activity_${tour.activity}');
  final parts = [
    if (tour.total > 0 && tour.index >= 0) t('stop_of', {'n': tour.index + 1, 'm': tour.total}),
    if (tour.poiName.isNotEmpty) tour.poiName else if (tour.poiId.isNotEmpty) tour.poiId,
    if (activity.isNotEmpty && !activity.startsWith('activity_')) activity,
  ];
  final line = parts.isEmpty ? t('tour_state_${tour.state}') : parts.join('  ·  ');
  return tour.message.isEmpty ? line : '$line\n${tour.message}';
}

/// The tour under way: its name and progress, with pause / resume, skip and end.
class TourCard extends StatelessWidget {
  const TourCard({
    super.key,
    required this.tour,
    required this.language,
    required this.onCommand,
    this.busy = const {},
  });

  final TourStatus tour;
  final String language;

  /// Runs tour_pause, tour_resume, tour_skip or tour_stop.
  final ValueChanged<String> onCommand;

  /// Commands still waiting for the robot's answer.
  final Set<String> busy;

  String t(String key, [Map<String, Object> args = const {}]) => tr(language, key, args);

  @override
  Widget build(BuildContext context) {
    final look = tourLook(tour.state);
    final name = tour.name.isNotEmpty ? tour.name : t('tour');
    final ending = tour.state == 'stopping';
    return Glass(
      key: const ValueKey('tour-card'),
      color: Palette.glassHigh,
      border: look.color.withValues(alpha: 0.6),
      radius: 16,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Icon(look.icon, size: 20, color: look.color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$name  ·  ${t('tour_state_${tour.state}')}',
                  style: Txt.label.copyWith(color: look.color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  tourProgress(tour, language),
                  style: Txt.small.copyWith(color: Palette.text),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          HudButton(
            key: const ValueKey('tour-pause'),
            icon: tour.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            size: 36,
            label: t(tour.paused ? 'act_resume' : 'act_pause'),
            tint: Palette.auto,
            busy: busy.contains('tour_pause') || busy.contains('tour_resume'),
            onPressed: ending ? null : () => onCommand(tour.paused ? 'tour_resume' : 'tour_pause'),
          ),
          const SizedBox(width: 6),
          HudButton(
            key: const ValueKey('tour-skip'),
            icon: Icons.skip_next_rounded,
            size: 36,
            label: t('tour_skip'),
            busy: busy.contains('tour_skip'),
            onPressed: ending || !tour.running ? null : () => onCommand('tour_skip'),
          ),
          const SizedBox(width: 6),
          HudButton(
            key: const ValueKey('tour-stop'),
            icon: Icons.stop_rounded,
            size: 36,
            label: t('tour_stop'),
            tint: Palette.stop,
            busy: busy.contains('tour_stop'),
            onPressed: ending ? null : () => onCommand('tour_stop'),
          ),
        ],
      ),
    );
  }
}
