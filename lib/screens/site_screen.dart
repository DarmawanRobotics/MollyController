import 'package:flutter/material.dart';

import '../l10n.dart';
import '../net/teleop_client.dart';
import '../protocol/messages.dart';
import '../theme.dart';
import '../widgets/hud.dart';
import '../widgets/page_header.dart';
import '../widgets/poi_dialog.dart';
import '../widgets/tour_dialog.dart';

/// The robot's sites: load one, map a new one or extend the active one, record its AprilTags and
/// routes, and edit its points of interest and tours.
class SiteScreen extends StatefulWidget {
  const SiteScreen({
    super.key,
    required this.client,
    required this.language,
    required this.onRun,
    this.onRoutes,
  });

  final TeleopClient client;
  final String language;
  final RunCommand onRun;

  /// Opens the list of recorded routes.
  final VoidCallback? onRoutes;

  @override
  State<SiteScreen> createState() => _SiteScreenState();
}

class _SiteScreenState extends State<SiteScreen> {
  final Set<String> _busy = {};
  SiteList? _sites;
  String? _sitesError;

  /// What the last command did, shown in the header until the next one.
  String? _done;

  TeleopClient get client => widget.client;

  String t(String key, [Map<String, Object> args = const {}]) => tr(widget.language, key, args);

  bool _has(String command) => client.welcome?.has(command) ?? false;

  @override
  void initState() {
    super.initState();
    _fetchSites();
  }

  Future<void> _fetchSites() async {
    if (!_has('site_list')) return;
    final result = await widget.onRun('site_list', label: t('section_sites'), quiet: true);
    if (!mounted) return;
    setState(() {
      _sites = SiteList.fromJson(result.data);
      _sitesError = result.ok ? null : (result.message.isEmpty ? t('failed') : result.message);
    });
  }

  /// Runs a command; [key] marks its control busy meanwhile. A failure shows why, a success shows
  /// [label] in the header.
  Future<bool> _send(String key, String name, Map<String, Object?> args, String label) async {
    setState(() {
      _busy.add(key);
      _done = null;
    });
    final result = await widget.onRun(name, args: args, label: label, quiet: true);
    if (!mounted) return result.ok;
    setState(() {
      _busy.remove(key);
      if (result.ok) _done = label;
    });
    if (!result.ok) {
      final why = result.message.isEmpty ? t('failed') : result.message;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label: $why')));
    }
    return result.ok;
  }

  Future<void> _load(String site) async {
    final ok = await _send('site-$site', 'site_load', {
      'site': site,
    }, t('site_loaded', {'name': site}));
    if (ok) await _fetchSites();
  }

  Future<void> _newMap() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) =>
          _NewMapDialog(language: widget.language, taken: _sites?.sites ?? const []),
    );
    if (name == null || !mounted) return;
    final ok = await _send('map', 'map_start', {
      'site': name,
      'reset': true,
    }, t('map_started', {'site': name}));
    if (ok) await _fetchSites();
  }

  Future<void> _extendMap(String site) async {
    await _send('map', 'map_start', {
      'site': site,
      'reset': false,
    }, t('map_started', {'site': site}));
  }

  Future<void> _saveMap() async {
    final ok = await _send('map-save', 'map_save', const {}, t('map_saved'));
    if (ok) await _fetchSites();
  }

  void _toggleRoute(bool recording) {
    if (recording) {
      _send('record', 'record_stop', const {}, t('record_saved'));
    } else {
      _send('record', 'record_start', const {}, t('record_started'));
    }
  }

  Future<void> _addPoi() async {
    final edit = await showDialog<PoiEdit>(
      context: context,
      builder: (context) =>
          PoiDialog(language: widget.language, gestures: client.welcome?.gestures ?? const []),
    );
    if (edit == null || !mounted) return;
    await _send('poi-add', 'poi_add', edit.addArgs(), t('poi_added', {'name': edit.name}));
  }

  Future<void> _editPoi(Poi poi) async {
    final edit = await showDialog<PoiEdit>(
      context: context,
      builder: (context) => PoiDialog(
        language: widget.language,
        gestures: client.welcome?.gestures ?? const [],
        poi: poi,
      ),
    );
    if (edit == null || !mounted) return;
    if (edit.delete) {
      await _send('poi-${poi.id}', 'poi_delete', {'id': poi.id}, t('poi_deleted'));
      return;
    }
    await _send(
      'poi-${poi.id}',
      'poi_update',
      edit.updateArgs(poi),
      t('poi_saved', {'name': edit.name}),
    );
  }

  /// Makes a tour ([tour] null) or changes or deletes one.
  Future<void> _editTour(Tour? tour, List<Poi> pois) async {
    final edit = await showDialog<TourEdit>(
      context: context,
      builder: (context) => TourDialog(language: widget.language, pois: pois, tour: tour),
    );
    if (edit == null || !mounted) return;
    final key = 'tour-${tour?.id ?? 'new'}';
    if (edit.delete && tour != null) {
      await _send(key, 'tour_delete', {'id': tour.id}, t('tour_deleted'));
      return;
    }
    await _send(
      key,
      'tour_save',
      edit.saveArgs(tour?.id ?? ''),
      t('tour_saved', {'name': edit.name}),
    );
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
            final name = state.site?.name ?? '';
            return Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHeader(
                    title: name.isEmpty ? t('site_page') : '${t('site_page')}  ·  $name',
                    done: _done,
                    action: IconButton(
                      onPressed: _has('site_list') ? _fetchSites : null,
                      tooltip: t('refresh'),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 5, child: _left(state)),
                        const SizedBox(width: 16),
                        Expanded(flex: 6, child: _right(state, site)),
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

  /// Sites, mapping, AprilTags and routes.
  Widget _left(RobotState state) {
    final sites = _sites;
    final error = _sitesError;
    final active = state.site?.name ?? sites?.active ?? '';
    final mapping = state.mapping;
    final mappingNow = mapping?.active ?? false;
    final recording = state.recording;
    return PageColumn(
      padding: const EdgeInsets.only(left: 8, right: 4, bottom: 16),
      children: [
        SectionTitle(t('section_sites')),
        if (!_has('site_list'))
          Text(t('sites_unsupported'), style: Txt.small)
        else if (sites == null)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator(color: Palette.auto)),
          )
        else if (error != null)
          Text(error, style: Txt.body.copyWith(color: Palette.stop))
        else if (sites.sites.isEmpty)
          Text(t('no_sites'), style: Txt.small),
        for (final name in sites?.sites ?? const <String>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _SiteTile(
              key: ValueKey('site-$name'),
              loadKey: ValueKey('site-load-$name'),
              name: name,
              active: name == active,
              activeLabel: t('site_active'),
              loadLabel: t('site_load'),
              busy: _busy.contains('site-$name'),
              onLoad: _has('site_load') && !mappingNow ? () => _load(name) : null,
            ),
          ),
        SectionTitle(t('section_mapping')),
        if (!_has('map_start'))
          Text(t('mapping_unsupported'), style: Txt.small)
        else ...[
          _mappingCard(mapping, state.site),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!mappingNow)
                FilledButton.icon(
                  key: const ValueKey('map-new'),
                  onPressed: _busy.contains('map') ? null : _newMap,
                  icon: const Icon(Icons.add_rounded),
                  label: Text(t('map_new')),
                ),
              if (!mappingNow && active.isNotEmpty)
                OutlinedButton.icon(
                  key: const ValueKey('map-extend'),
                  onPressed: _busy.contains('map') ? null : () => _extendMap(active),
                  icon: const Icon(Icons.edit_location_alt_rounded),
                  label: Text(t('map_extend')),
                ),
              if (mappingNow)
                FilledButton.icon(
                  key: const ValueKey('map-save'),
                  onPressed: _has('map_save') && !_busy.contains('map-save') ? _saveMap : null,
                  icon: const Icon(Icons.save_rounded),
                  label: Text(t('map_save')),
                ),
              if (mappingNow)
                OutlinedButton.icon(
                  key: const ValueKey('map-stop'),
                  onPressed: _has('map_stop') && !_busy.contains('map-stop')
                      ? () => _send('map-stop', 'map_stop', const {}, t('map_stopped'))
                      : null,
                  icon: const Icon(Icons.stop_rounded),
                  label: Text(t('map_stop')),
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('record-tags'),
              onPressed: _has('record_tags') && !_busy.contains('tags')
                  ? () => _send('tags', 'record_tags', const {}, t('tags_recorded'))
                  : null,
              icon: const Icon(Icons.qr_code_2_rounded),
              label: Text(t('act_tags')),
            ),
            OutlinedButton.icon(
              key: const ValueKey('localize'),
              onPressed: _has('localize') && !_busy.contains('localize')
                  ? () => _send('localize', 'localize', const {}, t('localized'))
                  : null,
              icon: const Icon(Icons.my_location_rounded),
              label: Text(t('act_localize')),
            ),
          ],
        ),
        SectionTitle(t('section_routes')),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('record-route'),
              onPressed: _has('record_start') && !_busy.contains('record')
                  ? () => _toggleRoute(recording)
                  : null,
              icon: Icon(
                recording ? Icons.stop_circle_rounded : Icons.fiber_manual_record_rounded,
                color: Palette.stop,
              ),
              label: Text(t(recording ? 'record_stop' : 'record_route')),
            ),
            OutlinedButton.icon(
              key: const ValueKey('open-routes'),
              onPressed: widget.onRoutes,
              icon: const Icon(Icons.route_rounded),
              label: Text(t('open_routes')),
            ),
          ],
        ),
      ],
    );
  }

  /// The mapping session, or how to make a map while there is none.
  Widget _mappingCard(MappingStatus? mapping, SiteStatus? site) {
    final active = mapping != null && mapping.active;
    final lines = <String>[
      if (mapping != null && mapping.active)
        t('mapping_detail', {'scans': mapping.scans, 'area': (mapping.area ?? 0).round()}),
      if (site != null && site.loaded) t('tags_detail', {'n': site.tags}),
    ];
    final color = active ? Palette.remote : Palette.muted;
    return Glass(
      color: Palette.panel,
      border: color.withValues(alpha: 0.5),
      radius: 14,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.map_rounded, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  mapping != null && mapping.active
                      ? t('mapping_active', {'site': mapping.site})
                      : t('mapping_idle'),
                  style: Txt.title.copyWith(color: color),
                ),
              ),
            ],
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(line, style: Txt.small.copyWith(color: Palette.text)),
            ),
          if (!active) ...[
            const SizedBox(height: 4),
            Text(t('map_new_body'), style: Txt.small),
          ],
        ],
      ),
    );
  }

  /// The site's points of interest and tours.
  Widget _right(RobotState state, SiteData? site) {
    final pois = site?.pois ?? const <Poi>[];
    final tours = site?.tours ?? const <Tour>[];
    final canEdit = _has('poi_update');
    final canAdd = _has('poi_add') && state.pose != null && !_busy.contains('poi-add');
    return PageColumn(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        SectionTitle(t('section_pois')),
        if (site == null)
          Text(t('no_site'), style: Txt.small)
        else if (pois.isEmpty)
          Text(t('no_pois'), style: Txt.small),
        // its own Material: list tiles paint their ink there
        Material(
          type: MaterialType.transparency,
          child: Column(
            children: [
              for (final poi in pois)
                ListTile(
                  key: ValueKey('site-poi-${poi.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.place_rounded, color: Palette.caution),
                  title: Text(poi.name, style: Txt.body),
                  subtitle: Text(
                    poi.narration.isEmpty
                        ? '${poi.x.toStringAsFixed(1)}, ${poi.y.toStringAsFixed(1)} m'
                        : poi.narration,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.small,
                  ),
                  trailing: _busy.contains('poi-${poi.id}')
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Palette.auto),
                        )
                      : const Icon(Icons.edit_rounded, size: 18, color: Palette.muted),
                  onTap: canEdit && !_busy.contains('poi-${poi.id}') ? () => _editPoi(poi) : null,
                ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('poi-add'),
            onPressed: canAdd ? _addPoi : null,
            icon: const Icon(Icons.add_location_alt_rounded),
            label: Text(state.pose == null ? t('poi_needs_pose') : t('poi_add')),
          ),
        ),
        SectionTitle(t('section_tours')),
        if (site != null && tours.isEmpty) Text(t('no_tours'), style: Txt.small),
        Material(
          type: MaterialType.transparency,
          child: Column(
            children: [
              for (final tour in tours)
                ListTile(
                  key: ValueKey('site-tour-${tour.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.tour_rounded, color: Palette.auto),
                  title: Text(tour.name, style: Txt.body),
                  subtitle: Text(
                    [for (final id in tour.poiIds) site?.poi(id)?.name ?? id].join(' → '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.small,
                  ),
                  trailing: _busy.contains('tour-${tour.id}')
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Palette.auto),
                        )
                      : const Icon(Icons.edit_rounded, size: 18, color: Palette.muted),
                  onTap: _has('tour_save') && !_busy.contains('tour-${tour.id}')
                      ? () => _editTour(tour, pois)
                      : null,
                ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('tour-new'),
            onPressed: _has('tour_save') && pois.isNotEmpty && !_busy.contains('tour-new')
                ? () => _editTour(null, pois)
                : null,
            icon: const Icon(Icons.playlist_add_rounded),
            label: Text(t('tour_new')),
          ),
        ),
      ],
    );
  }
}

/// One site on the robot: its name, and whether it is the active one or a button to load it.
class _SiteTile extends StatelessWidget {
  const _SiteTile({
    super.key,
    required this.loadKey,
    required this.name,
    required this.active,
    required this.activeLabel,
    required this.loadLabel,
    required this.busy,
    required this.onLoad,
  });

  final Key loadKey;
  final String name;
  final bool active;
  final String activeLabel;
  final String loadLabel;
  final bool busy;
  final VoidCallback? onLoad;

  @override
  Widget build(BuildContext context) {
    final Widget end;
    if (busy) {
      end = const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Palette.auto),
      );
    } else if (active) {
      end = Text(activeLabel, style: Txt.small.copyWith(color: Palette.ok));
    } else {
      end = TextButton(key: loadKey, onPressed: onLoad, child: Text(loadLabel));
    }
    return Material(
      color: Palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: active ? Palette.ok : Palette.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
        child: Row(
          children: [
            Icon(
              active ? Icons.check_circle_rounded : Icons.map_outlined,
              color: active ? Palette.ok : Palette.muted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: Txt.label.copyWith(fontSize: 15),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(height: 36, child: Center(child: end)),
          ],
        ),
      ),
    );
  }
}

/// Asks the name of a new site; what is typed becomes one (`Lobby East` -> `lobby_east`).
class _NewMapDialog extends StatefulWidget {
  const _NewMapDialog({required this.language, required this.taken});

  final String language;

  /// The robot's sites: a new map cannot take their names.
  final List<String> taken;

  @override
  State<_NewMapDialog> createState() => _NewMapDialogState();
}

class _NewMapDialogState extends State<_NewMapDialog> {
  final _name = TextEditingController();
  String? _error;

  String t(String key) => tr(widget.language, key);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _start() {
    final name = siteName(_name.text);
    final String? error;
    if (name == null) {
      error = t('map_name_error');
    } else if (widget.taken.contains(name)) {
      error = t('map_name_taken');
    } else {
      error = null;
    }
    setState(() => _error = error);
    if (error == null) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Palette.panel,
      title: Text(t('map_new_title'), style: Txt.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('map_new_body'), style: Txt.small),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('map-name'),
                controller: _name,
                autofocus: true,
                maxLength: 48,
                decoration: InputDecoration(
                  labelText: t('map_name'),
                  hintText: 'lobby_east',
                  errorText: _error,
                ),
                onSubmitted: (_) => _start(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t('cancel'))),
        FilledButton(
          key: const ValueKey('map-name-start'),
          onPressed: _start,
          child: Text(t('map_new')),
        ),
      ],
    );
  }
}
