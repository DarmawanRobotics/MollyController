import 'package:flutter/material.dart';

import '../l10n.dart';
import '../protocol/messages.dart';
import '../theme.dart';

/// What the tour dialog gives back: the tour as edited, or that it is to be deleted.
class TourEdit {
  const TourEdit({
    this.name = '',
    this.description = '',
    this.poiIds = const [],
    this.returnPoiId = '',
    this.delete = false,
  });

  final String name;
  final String description;
  final List<String> poiIds;

  /// Empty: the robot stays at the last stop.
  final String returnPoiId;
  final bool delete;

  /// `tour_save` arguments; an empty [id] makes a new tour.
  Map<String, Object?> saveArgs(String id) => {
    'tour': Tour(
      id: id,
      name: name,
      description: description,
      poiIds: poiIds,
      returnPoiId: returnPoiId,
    ).toJson(),
  };
}

/// Makes a tour from the site's POIs (its stops in order and where it ends), or changes or
/// deletes one.
class TourDialog extends StatefulWidget {
  const TourDialog({super.key, required this.language, required this.pois, this.tour});

  final String language;
  final List<Poi> pois;

  /// Null for a new tour.
  final Tour? tour;

  @override
  State<TourDialog> createState() => _TourDialogState();
}

class _TourDialogState extends State<TourDialog> {
  late final _name = TextEditingController(text: widget.tour?.name ?? '');
  late final _description = TextEditingController(text: widget.tour?.description ?? '');
  late final List<String> _stops = [
    for (final id in widget.tour?.poiIds ?? const <String>[])
      if (_known(id)) id,
  ];
  late String _returnTo = _known(widget.tour?.returnPoiId ?? '')
      ? widget.tour!.returnPoiId
      : '';
  String? _nameError;
  String? _stopsError;

  String t(String key, [Map<String, Object> args = const {}]) => tr(widget.language, key, args);

  bool _known(String id) => widget.pois.any((poi) => poi.id == id);

  String _nameOf(String id) {
    for (final poi in widget.pois) {
      if (poi.id == id) return poi.name;
    }
    return id;
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    setState(() {
      _nameError = name.isEmpty ? t('tour_name_error') : null;
      _stopsError = _stops.isEmpty ? t('tour_stops_error') : null;
    });
    if (_nameError != null || _stopsError != null) return;
    Navigator.pop(
      context,
      TourEdit(
        name: name,
        description: _description.text.trim(),
        poiIds: List.of(_stops),
        returnPoiId: _returnTo,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tour = widget.tour;
    final left = [
      for (final poi in widget.pois)
        if (!_stops.contains(poi.id)) poi,
    ];
    return AlertDialog(
      backgroundColor: Palette.panel,
      title: Text(tour == null ? t('tour_new') : t('tour_edit'), style: Txt.title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('tour-name'),
                controller: _name,
                autofocus: tour == null,
                maxLength: 64,
                decoration: InputDecoration(labelText: t('tour_name'), errorText: _nameError),
              ),
              TextField(
                key: const ValueKey('tour-description'),
                controller: _description,
                maxLength: 200,
                decoration: InputDecoration(labelText: t('tour_description')),
              ),
              const SizedBox(height: 4),
              Text(t('tour_stops'), style: Txt.body),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < _stops.length; i++)
                    InputChip(
                      key: ValueKey('tour-stop-${_stops[i]}'),
                      label: Text('${i + 1}. ${_nameOf(_stops[i])}'),
                      onDeleted: () => setState(() => _stops.removeAt(i)),
                    ),
                ],
              ),
              if (_stopsError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_stopsError!, style: Txt.small.copyWith(color: Palette.stop)),
                ),
              if (left.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(t('tour_add_stop'), style: Txt.small),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final poi in left)
                      ActionChip(
                        key: ValueKey('tour-add-${poi.id}'),
                        avatar: const Icon(Icons.add_rounded, size: 16),
                        label: Text(poi.name),
                        onPressed: () => setState(() {
                          _stops.add(poi.id);
                          _stopsError = null;
                        }),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: Text(t('tour_return'), style: Txt.body)),
                  DropdownButton<String>(
                    key: const ValueKey('tour-return'),
                    value: _returnTo,
                    dropdownColor: Palette.panel,
                    items: [
                      DropdownMenuItem(value: '', child: Text(t('tour_return_none'))),
                      for (final poi in widget.pois)
                        DropdownMenuItem(value: poi.id, child: Text(poi.name)),
                    ],
                    onChanged: (value) => setState(() => _returnTo = value ?? ''),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (tour != null)
          TextButton(
            key: const ValueKey('tour-delete'),
            onPressed: () => Navigator.pop(context, const TourEdit(delete: true)),
            child: Text(t('delete'), style: const TextStyle(color: Palette.stop)),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t('cancel'))),
        FilledButton(key: const ValueKey('tour-save'), onPressed: _save, child: Text(t('save'))),
      ],
    );
  }
}
