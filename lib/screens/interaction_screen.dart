import 'package:flutter/material.dart';

import '../l10n.dart';
import '../net/teleop_client.dart';
import '../protocol/messages.dart';
import '../robot_actions.dart';
import '../theme.dart';
import '../widgets/hud.dart';
import '../widgets/page_header.dart';

/// Talking with visitors: what the robot says (typed or a quick phrase, in Indonesian or English),
/// a visitor's question for the robot to answer, the greeter and the robot's gestures.
class InteractionScreen extends StatefulWidget {
  const InteractionScreen({
    super.key,
    required this.client,
    required this.language,
    required this.onRun,
  });

  final TeleopClient client;

  /// The interface language, also the first choice for the spoken one.
  final String language;
  final RunCommand onRun;

  @override
  State<InteractionScreen> createState() => _InteractionScreenState();
}

class _InteractionScreenState extends State<InteractionScreen> {
  /// Quick phrases: `phrase_<name>` labels the chip, `say_<name>` is said in the spoken language.
  static const _phrases = ['welcome', 'follow', 'wait', 'excuse', 'questions', 'thanks', 'goodbye'];

  final Set<String> _busy = {};
  final _say = TextEditingController();
  final _ask = TextEditingController();

  /// The spoken language: id or en.
  late String _lang = widget.language == 'en' ? 'en' : 'id';

  /// Stop what the robot says before saying this.
  bool _interrupt = false;
  bool _speakAnswer = true;
  String? _question;
  String? _answer;

  /// What the last command did, shown in the header until the next one.
  String? _done;

  TeleopClient get client => widget.client;

  String t(String key, [Map<String, Object> args = const {}]) => tr(widget.language, key, args);

  bool _has(String command) => client.welcome?.has(command) ?? false;

  @override
  void dispose() {
    _say.dispose();
    _ask.dispose();
    super.dispose();
  }

  /// Runs a command; [key] marks its control busy meanwhile. A failure shows why, a success shows
  /// [label] in the header.
  Future<CommandResult> _send(
    String key,
    String name,
    Map<String, Object?> args,
    String label,
  ) async {
    setState(() {
      _busy.add(key);
      _done = null;
    });
    final result = await widget.onRun(name, args: args, label: label, quiet: true);
    if (!mounted) return result;
    setState(() {
      _busy.remove(key);
      if (result.ok) _done = label;
    });
    if (!result.ok) {
      final why = result.message.isEmpty ? t('failed') : result.message;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label: $why')));
    }
    return result;
  }

  Map<String, Object?> _sayArgs(String text) => {
    'text': text,
    'lang': _lang,
    'interrupt': _interrupt,
  };

  Future<void> _sayTyped() async {
    final text = _say.text.trim();
    if (text.isEmpty || _busy.contains('say')) return;
    final result = await _send('say', 'say', _sayArgs(text), t('say_sent'));
    if (result.ok && mounted) _say.clear();
  }

  void _sayPhrase(String phrase) {
    _send('phrase-$phrase', 'say', _sayArgs(tr(_lang, 'say_$phrase')), t('phrase_$phrase'));
  }

  Future<void> _askQuestion() async {
    final question = _ask.text.trim();
    if (question.isEmpty || _busy.contains('ask')) return;
    setState(() {
      _question = question;
      _answer = null;
    });
    final result = await _send('ask', 'ask', {
      'question': question,
      'lang': _lang,
      'speak': _speakAnswer,
    }, t('ask_answered'));
    if (!mounted) return;
    final data = result.data;
    final answer = data is Map ? data['answer'] : null;
    setState(() {
      if (answer is String && answer.trim().isNotEmpty) {
        _answer = answer.trim();
      } else {
        _answer = result.ok ? t('ask_no_answer') : null;
      }
    });
    if (result.ok) _ask.clear();
  }

  void _setGreeter(bool on) {
    _send('greeter', 'greeter_set', {'enabled': on}, t(on ? 'greeter_on' : 'greeter_off'));
  }

  Future<void> _gesture(String name) async {
    final action = robotAction(name);
    final label = action.label(widget.language);
    if (action.confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Palette.panel,
          title: Text(t('confirm_action', {'action': label}), style: Txt.title),
          content: Text(t('confirm_action_body'), style: Txt.body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t('run'))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _send('gesture-$name', 'gesture', {'name': name}, label);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.night,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: client,
          builder: (context, _) {
            final state = client.state;
            return Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHeader(title: t('talk_page'), done: _done),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 6, child: _talk(state)),
                        const SizedBox(width: 16),
                        Expanded(flex: 5, child: _around(state)),
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

  /// Saying something, the quick phrases, the speech under way and a visitor's question.
  Widget _talk(RobotState state) {
    final canSay = _has('say');
    return ListView(
      padding: const EdgeInsets.only(left: 8, right: 4, bottom: 16),
      children: [
        SectionTitle(t('section_say'), top: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('say-text'),
                controller: _say,
                enabled: canSay,
                maxLength: 500,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(hintText: t('say_hint'), counterText: ''),
                onSubmitted: (_) => _sayTyped(),
              ),
            ),
            const SizedBox(width: 8),
            if (_busy.contains('say'))
              const _Spinner(size: 24)
            else
              IconButton.filled(
                key: const ValueKey('say-send'),
                onPressed: canSay ? _sayTyped : null,
                tooltip: t('say_send'),
                icon: const Icon(Icons.campaign_rounded),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<String>(
              key: const ValueKey('say-lang'),
              segments: const [
                ButtonSegment(value: 'id', label: Text('Indonesia')),
                ButtonSegment(value: 'en', label: Text('English')),
              ],
              selected: {_lang},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => setState(() => _lang = selection.first),
            ),
            FilterChip(
              key: const ValueKey('say-interrupt'),
              label: Text(t('say_interrupt')),
              selected: _interrupt,
              onSelected: (on) => setState(() => _interrupt = on),
            ),
          ],
        ),
        SectionTitle(t('section_phrases')),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final phrase in _phrases)
              ActionChip(
                key: ValueKey('phrase-$phrase'),
                avatar: _busy.contains('phrase-$phrase') ? const _Spinner(size: 14) : null,
                label: Text(t('phrase_$phrase')),
                onPressed: canSay && !_busy.contains('phrase-$phrase')
                    ? () => _sayPhrase(phrase)
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 12),
        _speech(state.speech),
        SectionTitle(t('section_ask')),
        if (!_has('ask'))
          Text(t('ask_unsupported'), style: Txt.small)
        else ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('ask-text'),
                  controller: _ask,
                  maxLength: 300,
                  textInputAction: TextInputAction.send,
                  decoration: InputDecoration(hintText: t('ask_hint'), counterText: ''),
                  onSubmitted: (_) => _askQuestion(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('ask-send'),
                onPressed: _busy.contains('ask') ? null : _askQuestion,
                child: Text(t('ask_send')),
              ),
            ],
          ),
          // its own Material: list tiles paint their ink there
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              key: const ValueKey('ask-speak'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(t('ask_speak'), style: Txt.body),
              value: _speakAnswer,
              onChanged: (on) => setState(() => _speakAnswer = on),
            ),
          ),
          if (_question != null) _answerCard(),
        ],
      ],
    );
  }

  /// What the robot says now, what waits after it, and a button to stop it.
  Widget _speech(SpeechStatus? speech) {
    final speaking = speech?.speaking ?? false;
    final color = speaking ? Palette.auto : Palette.muted;
    final title = switch (speech?.state) {
      null => t('speech_missing'),
      'speaking' => t('speech_speaking'),
      'done' => t('speech_done'),
      'failed' => t('speech_failed'),
      'cancelled' => t('speech_cancelled'),
      _ => t('speech_idle'),
    };
    final text = speech?.text ?? '';
    final queued = speech?.queued ?? 0;
    return Glass(
      color: Palette.panel,
      border: color.withValues(alpha: 0.5),
      radius: 14,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: [
          Icon(
            speaking ? Icons.record_voice_over_rounded : Icons.voice_over_off_rounded,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Txt.label.copyWith(color: speaking ? Palette.auto : null)),
                if (speaking && text.isNotEmpty)
                  Text(
                    '“$text”',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Txt.small.copyWith(color: Palette.text),
                  ),
                if (queued > 0) Text(t('speech_queued', {'n': queued}), style: Txt.small),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const ValueKey('speech-stop'),
            onPressed: _has('stop_speech') && !_busy.contains('speech-stop')
                ? () => _send('speech-stop', 'stop_speech', const {}, t('speech_stopped'))
                : null,
            icon: const Icon(Icons.stop_rounded),
            label: Text(t('stop_speech')),
          ),
        ],
      ),
    );
  }

  /// The last question and the robot's answer (or that it is thinking).
  Widget _answerCard() {
    final answer = _answer;
    return Glass(
      key: const ValueKey('ask-answer'),
      color: Palette.panel,
      radius: 14,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_question ?? '', style: Txt.small),
          const SizedBox(height: 6),
          if (_busy.contains('ask'))
            Row(
              children: [
                const _Spinner(size: 14),
                const SizedBox(width: 8),
                Text(t('ask_thinking'), style: Txt.body),
              ],
            )
          else if (answer != null)
            Text(answer, style: Txt.body),
        ],
      ),
    );
  }

  /// The visitors around the robot, the greeter and the gestures.
  Widget _around(RobotState state) {
    final gestures = {...?client.welcome?.gestures}.where((name) => name.isNotEmpty).toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        SectionTitle(t('section_visitors'), top: 6),
        _visitors(state.visitors),
        SectionTitle(t('section_greeter')),
        _greeter(state.greeter),
        SectionTitle(t('section_gestures')),
        if (gestures.isEmpty || !_has('gesture'))
          Text(t('no_gestures'), style: Txt.small)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final name in gestures)
                OutlinedButton.icon(
                  key: ValueKey('gesture-$name'),
                  onPressed: _busy.contains('gesture-$name') ? null : () => _gesture(name),
                  icon: Icon(robotAction(name).icon, size: 18),
                  label: Text(robotAction(name).label(widget.language)),
                ),
            ],
          ),
      ],
    );
  }

  Widget _visitors(Visitors? visitors) {
    final lines = <String>[];
    var near = false;
    if (visitors == null) {
      lines.add(t('visitors_missing'));
    } else if (visitors.count == 0) {
      lines.add(t('visitors_none'));
    } else {
      near = true;
      lines.add(
        t('visitors_detail', {
          'n': visitors.count,
          'front': visitors.front,
          'behind': visitors.behind,
        }),
      );
      final nearest = visitors.nearest;
      if (nearest != null) lines.add(t('visitors_nearest', {'m': nearest.toStringAsFixed(1)}));
    }
    return Glass(
      color: Palette.panel,
      radius: 14,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.groups_rounded, color: near ? Palette.auto : Palette.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < lines.length; i++)
                  Text(lines[i], style: i == 0 && near ? Txt.label : Txt.small),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _greeter(GreeterStatus? greeter) {
    return Glass(
      color: Palette.panel,
      radius: 14,
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // its own Material: the panel's colour would hide the tile's ink
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              key: const ValueKey('greeter-switch'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(t('greeter_switch'), style: Txt.body),
              value: greeter?.enabled ?? false,
              onChanged: _has('greeter_set') && !_busy.contains('greeter') ? _setGreeter : null,
            ),
          ),
          FilledButton.tonalIcon(
            key: const ValueKey('greet'),
            onPressed: _has('greet') && !_busy.contains('greet')
                ? () => _send('greet', 'greet', const {}, t('greeted'))
                : null,
            icon: const Icon(Icons.waving_hand_rounded),
            label: Text(t('greet')),
          ),
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: const CircularProgressIndicator(strokeWidth: 2, color: Palette.auto),
    );
  }
}
