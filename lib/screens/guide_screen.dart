import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../net/teleop_client.dart';
import '../protocol/messages.dart';
import '../theme.dart';
import '../widgets/hud.dart';
import '../widgets/tour_card.dart';

/// The guide, live on the robot: start a tour, walk to a POI, follow the tour under way, and set
/// the walking speed and the person detection.
class GuideScreen extends StatefulWidget {
  const GuideScreen({
    super.key,
    required this.client,
    required this.language,
    required this.onRun,
  });

  final TeleopClient client;
  final String language;
  final RunCommand onRun;

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  final Set<String> _busy = {};
  double? _speedDraft;

  TeleopClient get client => widget.client;

  String t(String key, [Map<String, Object> args = const {}]) => tr(widget.language, key, args);

  bool _has(String command) => client.welcome?.has(command) ?? false;

  /// Runs a command; [key] marks its control busy meanwhile. A failure shows why.
  Future<bool> _send(String key, String name, Map<String, Object?> args, String label) async {
    setState(() => _busy.add(key));
    final result = await widget.onRun(name, args: args, label: label, quiet: true);
    if (!mounted) return result.ok;
    setState(() => _busy.remove(key));
    if (!result.ok) {
      final why = result.message.isEmpty ? t('failed') : result.message;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label: $why')));
    }
    return result.ok;
  }

  Future<void> _startTour(Tour tour) async {
    final ok = await _send(
      'tour-${tour.id}',
      'tour_start',
      {'tour_id': tour.id},
      t('tour_started', {'name': tour.name}),
    );
    if (ok && mounted && client.state.remote) _hint(t('remote_nav_hint'));
  }

  Future<void> _tourAll(List<Poi> pois) async {
    final ok = await _send('tour-all', 'tour_start', {
      'poi_ids': [for (final poi in pois) poi.id],
    }, t('tour_all_started'));
    if (ok && mounted && client.state.remote) _hint(t('remote_nav_hint'));
  }

  Future<void> _goTo(Poi poi) async {
    final ok = await _send(
      'poi-${poi.id}',
      'go_to_poi',
      {'id': poi.id},
      t('walking_to', {'name': poi.name}),
    );
    if (ok && mounted && client.state.remote) _hint(t('remote_nav_hint'));
  }

  void _tourCommand(String name) {
    _send(name, name, const {}, t('${name}_done'));
  }

  void _setPeople(bool on) {
    _send('people', 'people_set', {'enabled': on}, t(on ? 'people_on' : 'people_off_done'));
  }

  Future<void> _setSpeed(double speed) async {
    final value = double.parse(speed.toStringAsFixed(2));
    await _send('speed', 'nav_speed', {'speed': value}, t('patrol_speed'));
    if (mounted) setState(() => _speedDraft = null);
  }

  void _hint(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.night,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([client, client.site]),
          builder: (context, _) {
            final state = client.state;
            final site = client.site.value;
            final tour = state.tour;
            return Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      Expanded(
                        child: Text(
                          site == null || site.name.isEmpty
                              ? t('guide_page')
                              : '${t('guide_page')}  ·  ${site.name}',
                          style: Txt.title,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        onPressed: _has('get_site') ? () => client.command('get_site') : null,
                        tooltip: t('refresh'),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                  if (tour != null && tour.active)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 0, 8),
                      child: TourCard(
                        tour: tour,
                        language: widget.language,
                        busy: _busy,
                        onCommand: _tourCommand,
                      ),
                    ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 6, child: _tours(site, tour)),
                        const SizedBox(width: 16),
                        Expanded(flex: 5, child: _right(site, state)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _tours(SiteData? site, TourStatus? running) {
    final tours = site?.tours ?? const <Tour>[];
    final pois = site?.pois ?? const <Poi>[];
    final canStart = _has('tour_start') && !(running?.active ?? false);
    return ListView(
      padding: const EdgeInsets.only(left: 8, right: 4, bottom: 16),
      children: [
        _section(t('section_tours')),
        if (site == null)
          Text(t('no_site'), style: Txt.small)
        else if (tours.isEmpty)
          Text(t('no_tours'), style: Txt.small),
        for (final tour in tours)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _TourTile(
              key: ValueKey('tour-${tour.id}'),
              startKey: ValueKey('tour-start-${tour.id}'),
              title: tour.name,
              subtitle: _tourStops(tour, site),
              active: running?.tourId == tour.id && (running?.active ?? false),
              busy: _busy.contains('tour-${tour.id}'),
              startLabel: t('act_start'),
              onStart: canStart && tour.poiIds.isNotEmpty ? () => _startTour(tour) : null,
            ),
          ),
        if (pois.length > 1)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('tour-all'),
              onPressed: canStart && !_busy.contains('tour-all') ? () => _tourAll(pois) : null,
              icon: const Icon(Icons.playlist_play_rounded),
              label: Text(t('tour_all', {'n': pois.length})),
            ),
          ),
      ],
    );
  }

  String _tourStops(Tour tour, SiteData? site) {
    final names = [for (final id in tour.poiIds) site?.poi(id)?.name ?? id];
    final stops = tour.poiIds.length == 1
        ? t('stops_one')
        : t('stops_count', {'n': tour.poiIds.length});
    return names.isEmpty ? stops : '$stops: ${names.join(' → ')}';
  }

  Widget _right(SiteData? site, RobotState state) {
    final pois = site?.pois ?? const <Poi>[];
    final canGo = _has('go_to_poi');
    final goal = state.planner;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        _section(t('section_pois')),
        if (site != null && pois.isEmpty) Text(t('no_pois'), style: Txt.small),
        // its own Material: list tiles paint their ink there
        Material(
          type: MaterialType.transparency,
          child: Column(
            children: [
              for (final poi in pois)
                ListTile(
                  key: ValueKey('poi-${poi.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.place_rounded,
                    color: goal != null && goal.walking && goal.goal == poi.id
                        ? Palette.auto
                        : Palette.caution,
                  ),
                  title: Text(poi.name, style: Txt.body),
                  subtitle: poi.narration.isEmpty
                      ? null
                      : Text(
                          poi.narration,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Txt.small,
                        ),
                  trailing: IconButton(
                    key: ValueKey('poi-go-${poi.id}'),
                    tooltip: t('go_to_poi'),
                    onPressed: canGo && !_busy.contains('poi-${poi.id}') ? () => _goTo(poi) : null,
                    icon: const Icon(Icons.directions_walk_rounded, color: Palette.auto),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _speed(state.speed),
        const SizedBox(height: 12),
        _people(state.people),
      ],
    );
  }

  Widget _speed(WalkSpeed? speed) {
    final supported = _has('nav_speed');
    final children = <Widget>[
      Text(t('patrol_speed'), style: Txt.title),
      const SizedBox(height: 8),
    ];
    if (!supported || speed == null || speed.max <= speed.min) {
      final why = t(supported ? 'speed_unavailable' : 'speed_unsupported');
      children.add(Text(why, style: Txt.small));
    } else {
      final value = math.min(math.max(_speedDraft ?? speed.target, speed.min), speed.max);
      children.addAll([
        Text('${value.toStringAsFixed(2)} m/s', style: Txt.display.copyWith(fontSize: 34)),
        const SizedBox(height: 4),
        Slider(
          value: value,
          min: speed.min,
          max: speed.max,
          divisions: math.max(1, ((speed.max - speed.min) / 0.05).round()),
          label: value.toStringAsFixed(2),
          onChanged: _busy.contains('speed') ? null : (v) => setState(() => _speedDraft = v),
          onChangeEnd: _busy.contains('speed') ? null : _setSpeed,
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(speed.min.toStringAsFixed(2), style: Txt.small),
            Text(speed.max.toStringAsFixed(2), style: Txt.small),
          ],
        ),
        const SizedBox(height: 8),
        Text(t('patrol_speed_hint'), style: Txt.small),
      ]);
    }
    return Glass(
      color: Palette.panel,
      radius: 14,
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _people(PeopleStatus? people) {
    final live = _has('people_set') && people != null && people.state != 'offline';
    final lines = <String>[];
    if (people == null) {
      lines.add(t('people_missing'));
    } else {
      final count = people.count;
      if (count != null) {
        lines.add(
          t('people_detail', {'n': count, 'ms': people.latencyMs, 'backend': people.backend}),
        );
      }
      if (people.state == 'error' && people.error.isNotEmpty) lines.add(people.error);
    }
    return Glass(
      color: Palette.panel,
      radius: 14,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('section_people'), style: Txt.title),
          // its own Material: the panel's colour would hide the tile's ink
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              key: const ValueKey('people-switch'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(t('people_switch'), style: Txt.body),
              subtitle: Text(t('people_switch_hint'), style: Txt.small),
              value: people?.on ?? false,
              onChanged: live && !_busy.contains('people') ? _setPeople : null,
            ),
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(line, style: Txt.small.copyWith(color: Palette.text)),
            ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Text(
        title.toUpperCase(),
        style: Txt.small.copyWith(
          color: Palette.auto,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// One tour: its name, its stops and a start button.
class _TourTile extends StatelessWidget {
  const _TourTile({
    super.key,
    required this.startKey,
    required this.title,
    required this.subtitle,
    required this.active,
    required this.busy,
    required this.startLabel,
    required this.onStart,
  });

  final Key startKey;
  final String title;
  final String subtitle;

  /// This tour is under way.
  final bool active;
  final bool busy;
  final String startLabel;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: active ? Palette.auto : Palette.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.tour_rounded, color: active ? Palette.auto : Palette.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Txt.label.copyWith(fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Txt.small, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (busy)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Palette.auto),
              )
            else
              FilledButton.icon(
                key: startKey,
                onPressed: onStart,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(startLabel),
              ),
          ],
        ),
      ),
    );
  }
}
