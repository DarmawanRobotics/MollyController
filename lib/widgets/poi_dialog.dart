import 'package:flutter/material.dart';

import '../l10n.dart';
import '../protocol/messages.dart';
import '../robot_actions.dart';
import '../theme.dart';

/// What the POI dialog gives back: the POI as edited, or that it is to be deleted.
class PoiEdit {
  const PoiEdit({
    this.name = '',
    this.description = '',
    this.narration = '',
    this.language = '',
    this.gesture = '',
    this.dwell = 0,
    this.here = false,
    this.delete = false,
  });

  final String name;
  final String description;
  final String narration;

  /// id, en, or empty for the robot's default.
  final String language;

  /// Empty: no gesture.
  final String gesture;
  final double dwell;

  /// Move the POI to where the robot stands now.
  final bool here;
  final bool delete;

  Map<String, Object?> _fields() => {
    'name': name,
    'description': description,
    'narration': narration,
    'language': language,
    'gesture': gesture,
    'dwell': dwell,
  };

  /// `poi_add` arguments: a new POI at the robot's pose.
  Map<String, Object?> addArgs() => _fields();

  /// `poi_update` arguments for [poi].
  Map<String, Object?> updateArgs(Poi poi) => {
    'poi': {'id': poi.id, ..._fields(), if (here) 'here': true},
  };
}

/// Adds a POI where the robot stands, or changes, moves or deletes one.
class PoiDialog extends StatefulWidget {
  const PoiDialog({super.key, required this.language, required this.gestures, this.poi});

  final String language;

  /// The gestures the robot offers (`welcome.gestures`).
  final List<String> gestures;

  /// Null for a new POI at the robot's pose.
  final Poi? poi;

  @override
  State<PoiDialog> createState() => _PoiDialogState();
}

class _PoiDialogState extends State<PoiDialog> {
  static const _dwells = [0.0, 5.0, 10.0, 20.0, 30.0, 60.0];

  late final _name = TextEditingController(text: widget.poi?.name ?? '');
  late final _description = TextEditingController(text: widget.poi?.description ?? '');
  late final _narration = TextEditingController(text: widget.poi?.narration ?? '');
  late String _language = _languageOf(widget.poi?.language ?? '');
  late String _gesture = widget.poi?.gesture ?? '';
  late double _dwell = _nearestDwell(widget.poi?.dwell ?? 0);
  bool _here = false;
  String? _nameError;

  String t(String key, [Map<String, Object> args = const {}]) => tr(widget.language, key, args);

  static String _languageOf(String value) => const {'id', 'en'}.contains(value) ? value : '';

  static double _nearestDwell(double value) =>
      _dwells.reduce((a, b) => (a - value).abs() <= (b - value).abs() ? a : b);

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _narration.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    setState(() => _nameError = name.isEmpty ? t('poi_name_error') : null);
    if (_nameError != null) return;
    Navigator.pop(
      context,
      PoiEdit(
        name: name,
        description: _description.text.trim(),
        narration: _narration.text.trim(),
        language: _language,
        gesture: _gesture,
        dwell: _dwell,
        here: _here,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final poi = widget.poi;
    // each name once (the dropdown needs one item per value), the POI's own one kept
    final gestures = <String>{
      ...widget.gestures.where((name) => name.isNotEmpty),
      if (_gesture.isNotEmpty) _gesture,
    }.toList();
    return AlertDialog(
      backgroundColor: Palette.panel,
      title: Text(poi == null ? t('poi_new') : t('poi_edit'), style: Txt.title),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('poi-name'),
                controller: _name,
                autofocus: poi == null,
                maxLength: 64,
                decoration: InputDecoration(labelText: t('poi_name'), errorText: _nameError),
              ),
              TextField(
                key: const ValueKey('poi-narration'),
                controller: _narration,
                minLines: 2,
                maxLines: 4,
                maxLength: 1000,
                decoration: InputDecoration(labelText: t('poi_narration')),
              ),
              TextField(
                key: const ValueKey('poi-description'),
                controller: _description,
                maxLines: 2,
                maxLength: 200,
                decoration: InputDecoration(labelText: t('poi_description')),
              ),
              const SizedBox(height: 4),
              Text(t('poi_language'), style: Txt.body),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: '', label: Text(t('lang_default'))),
                  const ButtonSegment(value: 'id', label: Text('Indonesia')),
                  const ButtonSegment(value: 'en', label: Text('English')),
                ],
                selected: {_language},
                showSelectedIcon: false,
                expandedInsets: EdgeInsets.zero,
                onSelectionChanged: (selection) => setState(() => _language = selection.first),
              ),
              if (gestures.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: Text(t('poi_gesture'), style: Txt.body)),
                    DropdownButton<String>(
                      key: const ValueKey('poi-gesture'),
                      value: _gesture,
                      dropdownColor: Palette.panel,
                      items: [
                        DropdownMenuItem(value: '', child: Text(t('gesture_none'))),
                        for (final name in gestures)
                          DropdownMenuItem(
                            value: name,
                            child: Text(robotAction(name).label(widget.language)),
                          ),
                      ],
                      onChanged: (value) => setState(() => _gesture = value ?? ''),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Text(t('poi_dwell', {'n': _dwell.round()}), style: Txt.body),
              Slider(
                key: const ValueKey('poi-dwell'),
                value: _dwells.indexOf(_dwell).toDouble(),
                max: (_dwells.length - 1).toDouble(),
                divisions: _dwells.length - 1,
                label: '${_dwell.round()} s',
                onChanged: (index) => setState(() => _dwell = _dwells[index.round()]),
              ),
              if (poi != null)
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    key: const ValueKey('poi-here'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('poi_here'), style: Txt.body),
                    value: _here,
                    onChanged: (here) => setState(() => _here = here),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (poi != null)
          TextButton(
            key: const ValueKey('poi-delete'),
            onPressed: () => Navigator.pop(context, const PoiEdit(delete: true)),
            child: Text(t('delete'), style: const TextStyle(color: Palette.stop)),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t('cancel'))),
        FilledButton(key: const ValueKey('poi-save'), onPressed: _save, child: Text(t('save'))),
      ],
    );
  }
}
