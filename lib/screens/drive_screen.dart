import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';

import '../input/gamepad_input.dart';
import '../net/teleop_client.dart';
import '../protocol/messages.dart' show PlannerStatus, RobotState;
import '../robot_actions.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets/camera_view.dart';
import '../widgets/glance.dart';
import '../widgets/hud.dart';
import '../widgets/map_view.dart';
import '../widgets/poi_dialog.dart';
import '../widgets/tour_card.dart';
import 'guide_screen.dart';
import 'interaction_screen.dart';
import 'routes_screen.dart';
import 'settings_screen.dart';
import 'site_screen.dart';

/// Home while connected: the camera and the map (tap the small box to swap them), STOP and the
/// robot's own actions on the right, the tour under way at the top, mapping, guide and talk icons
/// at the bottom. Driving is on the gamepad; touch is for the views (pinch and drag the big map,
/// long press to walk somewhere).
class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key, required this.services});

  final Services services;

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  /// Navigation states in which the robot is not walking (Start shows instead of Pause).
  static const _idleNav = {'NAV_INACTIVE', 'NO_PATH', 'PAUSED', 'GOAL_REACHED'};

  Services get s => widget.services;
  TeleopClient get client => widget.services.client;

  final Set<String> _busy = {};
  Toast? _toast;
  Timer? _toastTimer;
  Timer? _loop;
  bool _hinted = false;
  bool _suspended = false;

  /// Pages and dialogs open over this screen; the sticks rest meanwhile.
  int _covers = 0;

  /// What the map shows, for both views and the buttons under the small one.
  final _viewport = MapViewport();

  /// The route being recorded: since when, and the stop points marked in it.
  DateTime? _recordingSince;
  final List<Offset> _marks = [];

  /// A route was loaded last (not a tour or a walk): Start follows it.
  bool _routeReady = false;

  /// The walk's state and when it changed: an arrival or a failure shows for a few seconds.
  String? _plannerState;
  DateTime _plannerChanged = DateTime.fromMillisecondsSinceEpoch(0);

  StreamSubscription<GamepadButton>? _buttons;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _loop = Timer.periodic(const Duration(milliseconds: 50), (_) => _drive());
    _buttons = s.gamepad.presses.listen(_onButton);
    _lifecycle = AppLifecycleListener(onPause: _suspend, onResume: _resume);
    client.addListener(_onClient);
    s.settings.addListener(_syncStreams);
    s.video.addListener(_syncStreams);
    s.gamepad.refresh(); // the plugin may not have listed the controls yet at app start
    // after the first frame: setting the streams notifies the screens below while this one builds
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onClient();
    });
  }

  @override
  void dispose() {
    _loop?.cancel();
    _toastTimer?.cancel();
    _buttons?.cancel();
    _lifecycle.dispose();
    client.removeListener(_onClient);
    s.settings.removeListener(_syncStreams);
    s.video.removeListener(_syncStreams);
    s.video.want(null, '');
    _viewport.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- input

  /// 20 Hz from the gamepad sticks; the client only sends in REMOTE mode.
  void _drive() {
    final pad = s.gamepad;
    if (_covers > 0 || (s.settings.deadman && !pad.pressed(GamepadButton.rightBumper))) {
      client.drive(0, 0, 0);
      _hinted = false;
      return;
    }
    final x = GamepadInput.shaped(pad.axis(GamepadAxis.leftStickX));
    final y = GamepadInput.shaped(pad.axis(GamepadAxis.leftStickY));
    final r = GamepadInput.shaped(pad.axis(GamepadAxis.rightStickX));
    final limits = client.welcome?.limits ?? const [0.5, 0.3, 1.0];
    final scale = AppSettings.speedScale[s.settings.gear - 1];
    // stick up = forward (+x), stick right = right (-y), turn right = clockwise (-z)
    client.drive(y * limits[0] * scale, -x * limits[1] * scale, -r * limits[2] * scale);

    final pushing = math.max(math.max(x.abs(), y.abs()), r.abs()) > 0.4;
    if (pushing &&
        !_hinted &&
        client.status == LinkStatus.connected &&
        !client.state.remote &&
        !client.state.estop) {
      _hinted = true;
      _show(Toast(s.t('auto_hint'), color: Palette.auto, icon: Icons.info_outline_rounded));
    }
    if (!pushing) _hinted = false;
  }

  void _onButton(GamepadButton button) {
    if (button == GamepadButton.b) {
      _estop(); // STOP works from every page
      return;
    }
    if (_covers > 0) return; // settings, routes or a dialog is open
    final shift = s.gamepad.pressed(GamepadButton.leftBumper);
    switch (button) {
      case GamepadButton.start:
        _setMode(client.state.remote ? 'auto' : 'remote');
      case GamepadButton.back:
        _swapViews();
      case GamepadButton.dpadUp:
        _setGear(s.settings.gear + 1);
      case GamepadButton.dpadDown:
        _setGear(s.settings.gear - 1);
      case GamepadButton.a when shift:
        _robotAction('stand_up');
      case GamepadButton.y when shift:
        _robotAction('sit_down');
      default:
        break;
    }
  }

  /// Follows the robot's recording flag and the walk; a reconnect (no telemetry yet) changes
  /// nothing.
  void _onClient() {
    _syncStreams();
    final state = client.state;
    if (client.status != LinkStatus.connected || state.seq == 0) return;
    if (state.recording) {
      if (_recordingSince == null) {
        // a fresh route: the map shows only what this recording covers
        _recordingSince = DateTime.now();
        _marks.clear();
        client.clearTrail();
      }
    } else {
      _recordingSince = null;
    }
    final planner = state.planner?.state;
    if (planner != _plannerState) {
      _plannerState = planner;
      _plannerChanged = DateTime.now();
    }
  }

  /// Streams for the settings (here or on the settings page) and the link. The camera comes over
  /// WebRTC when the robot offers it, as JPEG frames until that plays and whenever it fails.
  void _syncStreams() {
    final settings = s.settings;
    final offer = client.welcome?.video;
    final whep = settings.video && client.isLive && offer != null ? offer.whep(client.host) : null;
    s.video.want(whep, client.token);
    final jpeg = settings.video && s.video.renderer == null; // what the camera view can show
    final webrtc = whep != null;
    if (client.cameraEnabled != jpeg ||
        client.videoEnabled != webrtc ||
        client.lidarEnabled != settings.lidar ||
        client.cameraFps != settings.cameraFps) {
      client.setStreams(
        camera: jpeg,
        video: webrtc,
        lidar: settings.lidar,
        fps: settings.cameraFps,
      );
    }
  }

  // ---------------------------------------------------------------- actions

  Future<CommandResult> _run(
    String name, {
    Map<String, Object?> args = const {},
    String? label,
    bool quiet = false,
  }) async {
    setState(() => _busy.add(name));
    final result = await client.command(name, args);
    if (!mounted) return result;
    setState(() {
      _busy.remove(name);
      if (result.ok && name == 'load_route') _routeReady = true;
      if (result.ok && const {'tour_start', 'go_to_poi', 'go_to'}.contains(name)) {
        _routeReady = false;
      }
    });
    if (!result.ok || !quiet) {
      final text = label ?? name;
      _show(
        result.ok
            ? Toast(text, color: Palette.ok, icon: Icons.check_circle_rounded)
            : Toast(
                '$text: ${result.message.isEmpty ? s.t('failed') : result.message}',
                color: Palette.stop,
                icon: Icons.error_rounded,
              ),
      );
    }
    return result;
  }

  void _estop() {
    HapticFeedback.heavyImpact();
    _show(Toast(s.t('estop_sent'), color: Palette.stop, icon: Icons.pan_tool_rounded));
    client.estop().then((result) {
      if (mounted && !result.ok) {
        _show(Toast('E-stop: ${result.message}', color: Palette.stop, icon: Icons.error_rounded));
      }
    });
  }

  void _setMode(String mode) {
    if (_busy.contains('set_mode')) return;
    _run('set_mode', args: {'mode': mode}, label: mode.toUpperCase(), quiet: true);
  }

  void _setGear(int gear) {
    final next = math.min(3, math.max(1, gear));
    if (next == s.settings.gear) return;
    HapticFeedback.selectionClick();
    s.settings.update(gear: next);
    _show(
      Toast(s.t('speed_toast', {'n': next, 'name': s.t('speed_$next')}), icon: Icons.speed_rounded),
    );
  }

  void _swapViews() {
    HapticFeedback.selectionClick();
    s.settings.update(mainView: s.settings.mainView == 'map' ? 'camera' : 'map');
  }

  /// A point of interest where the robot stands; the map page edits it further.
  Future<void> _addPoiHere() async {
    final edit = await _cover(
      () => showDialog<PoiEdit>(
        context: context,
        builder: (context) => PoiDialog(
          language: s.settings.language,
          gestures: client.welcome?.gestures ?? const [],
        ),
      ),
    );
    if (edit == null || !mounted) return;
    await _run('poi_add', args: edit.addArgs(), label: s.t('poi_added', {'name': edit.name}));
  }

  Future<void> _markStop() async {
    final pose = client.state.pose;
    final dwell = s.settings.stopDwell;
    final result = await _run(
      'mark_stop',
      args: {'dwell': dwell},
      label: s.t('stop_marked', {'s': dwell.round()}),
    );
    if (result.ok && pose != null && mounted) setState(() => _marks.add(Offset(pose.x, pose.y)));
  }

  /// Start, pause or resume: the tour under way, else the walk or the loaded route; with nothing
  /// to follow the guide page opens to pick a tour. In REMOTE the robot only walks once in AUTO.
  Future<void> _primary() async {
    final state = client.state;
    final tour = state.tour;
    if (tour != null && tour.active) {
      final name = tour.paused ? 'tour_resume' : 'tour_pause';
      await _run(name, label: s.t('${name}_done'));
      return;
    }
    final CommandResult result;
    if (state.navPaused) {
      result = await _run('nav_resume', label: s.t('nav_resumed'), quiet: state.remote);
    } else if (!_idleNav.contains(state.nav)) {
      await _run('nav_pause', label: s.t('nav_paused'));
      return;
    } else if (_routeReady && (client.welcome?.has('nav_start') ?? false)) {
      result = await _run('nav_start', label: s.t('nav_started'), quiet: state.remote);
    } else {
      await _openGuide();
      return;
    }
    if (result.ok && mounted && client.state.remote) {
      _show(Toast(s.t('remote_nav_hint'), color: Palette.auto, icon: Icons.info_outline_rounded));
    }
  }

  /// End the tour, the walk or the route.
  Future<void> _end() async {
    final state = client.state;
    final tour = state.tour;
    if (tour != null && tour.active) {
      await _run('tour_stop', label: s.t('tour_stop_done'));
    } else if (state.planner?.walking ?? false) {
      await _run('go_cancel', label: s.t('walk_cancelled'));
    } else {
      await _run('nav_stop', label: s.t('nav_ended'));
    }
  }

  void _tourCommand(String name) {
    _run(name, label: s.t('${name}_done'));
  }

  /// The POI the robot is busy with: the tour's stop, else the goal it walks to.
  String? _focusPoi(RobotState state) {
    final tour = state.tour;
    if (tour != null && tour.active && tour.poiId.isNotEmpty) return tour.poiId;
    final planner = state.planner;
    if (planner != null && planner.walking && planner.goal.isNotEmpty) return planner.goal;
    return null;
  }

  /// A long press on the big map: walk there, the robot finds the way.
  Future<void> _goHere(Offset point) async {
    if (!(client.welcome?.has('go_to') ?? false)) return;
    final pose = client.state.pose;
    final yaw = pose == null ? 0.0 : math.atan2(point.dy - pose.y, point.dx - pose.x);
    final ok = await _confirm(
      s.t('go_here'),
      s.t('go_here_body', {'x': point.dx.toStringAsFixed(1), 'y': point.dy.toStringAsFixed(1)}),
      s.t('go'),
    );
    if (!ok || !mounted) return;
    await _run(
      'go_to',
      args: {'x': point.dx, 'y': point.dy, 'yaw': yaw},
      label: s.t('walking_there'),
    );
  }

  void _robotAction(String name) {
    final commands = client.welcome?.robotCommands ?? const <String>[];
    if (commands.contains(name)) _runAction(robotAction(name));
  }

  Future<void> _runAction(RobotAction action) async {
    final label = action.label(s.settings.language);
    if (action.confirm) {
      final ok = await _confirm(
        s.t('confirm_action', {'action': label}),
        s.t('confirm_action_body'),
        s.t('run'),
      );
      if (!ok || !mounted) return;
    }
    await _run(action.name, label: label);
  }

  void _show(Toast toast) {
    _toastTimer?.cancel();
    setState(() => _toast = toast);
    _toastTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  /// Runs [open] (a page or a dialog over this screen) with the sticks at rest until it closes.
  Future<T> _cover<T>(Future<T> Function() open) async {
    _covers++;
    client.drive(0, 0, 0);
    try {
      return await open();
    } finally {
      _covers--;
    }
  }

  Future<void> _push(Widget page) =>
      _cover(() => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => page)));

  Future<void> _openSettings() => _push(SettingsScreen(services: s));

  Future<void> _openRoutes() => _push(RoutesScreen(services: s, onRun: _run));

  Future<void> _openSite() => _push(
    SiteScreen(client: client, language: s.settings.language, onRun: _run, onRoutes: _openRoutes),
  );

  Future<void> _openGuide() =>
      _push(GuideScreen(client: client, language: s.settings.language, onRun: _run));

  Future<void> _openTalk() =>
      _push(InteractionScreen(client: client, language: s.settings.language, onRun: _run));

  Future<bool> _confirm(String title, String body, String action) async {
    final result = await _cover(
      () => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Palette.panel,
          title: Text(title, style: Txt.title),
          content: Text(body, style: Txt.body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(s.t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  Future<void> _leave() async {
    final ok = await _confirm(s.t('leave'), s.t('leave_body'), s.t('disconnect'));
    if (!ok || !mounted) return;
    _exit();
  }

  void _exit() {
    client.disconnect();
    Navigator.of(context).pop();
  }

  /// The app went to the background: let the robot go rather than hold a session.
  void _suspend() {
    if (client.status == LinkStatus.idle) return;
    _suspended = true;
    client.disconnect();
  }

  void _resume() {
    if (!_suspended) return;
    _suspended = false;
    client.retry();
  }

  // ---------------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: Palette.night,
        body: ListenableBuilder(
          listenable: Listenable.merge([client, s.settings, s.video]),
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) => _layout(constraints.biggest),
          ),
        ),
      ),
    );
  }

  Widget _layout(Size size) {
    const top = 50.0;
    const scrim = [Color(0xA6000000), Color(0x00000000)];
    final state = client.state;
    final tour = state.tour;
    final modeColor = Palette.forMode(state.mode);
    final mapMain = s.settings.mainView == 'map';
    final insetWidth = math.max(150.0, math.min(300.0, size.width * 0.27));
    final insetHeight = insetWidth * 0.62;
    // the middle column between the small view and the right rail
    final middleLeft = insetWidth + 20;
    const middleRight = 82.0;
    final status = _statusPill();
    final overlay = _linkOverlay();

    final camera = CameraView(
      frames: client.cameraFrame,
      enabled: s.settings.video,
      offText: s.t('camera_off'),
      waitText: s.t('camera_wait'),
      tags: state.tags,
      people: state.people?.on == true && state.people?.state == 'running'
          ? state.people!.boxes
          : const [],
      webrtc: s.video.renderer,
    );
    final map = MapView(
      viewport: _viewport,
      points: client.lidarPoints,
      route: client.routePoints,
      map: client.mapLayer,
      site: client.site,
      highlight: _focusPoi(state),
      onLongPress: _goHere,
      trail: client.trail,
      marks: state.recording ? _marks : const [],
      pose: state.pose,
      modeColor: modeColor,
      lidar: client.lidarEnabled,
      notLocalizedText: s.t('not_localized'),
      compact: !mapMain,
    );

    return Stack(
      children: [
        // the big view; both boxes keep their key when they swap, so the video keeps playing
        Positioned.fill(
          key: ValueKey(mapMain ? 'map' : 'camera'),
          child: _ViewBox(child: mapMain ? map : camera),
        ),
        const Positioned(
          key: ValueKey('scrim-top'),
          left: 0,
          right: 0,
          top: 0,
          height: 124,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: scrim,
                ),
              ),
            ),
          ),
        ),
        const Positioned(
          key: ValueKey('scrim-bottom'),
          left: 0,
          right: 0,
          bottom: 0,
          height: 96,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: scrim,
                ),
              ),
            ),
          ),
        ),

        // the small view: tap it to swap
        Positioned(
          key: ValueKey(mapMain ? 'camera' : 'map'),
          left: 10,
          top: top,
          width: insetWidth,
          height: insetHeight,
          child: _ViewBox(onTap: _swapViews, child: mapMain ? camera : map),
        ),
        Positioned(
          key: const ValueKey('view-buttons'),
          left: 10,
          top: top + insetHeight + 8,
          // the map listens to the viewport itself: a pinch does not rebuild the whole screen
          child: ListenableBuilder(listenable: _viewport, builder: (context, _) => _viewButtons()),
        ),
        // people in view and the robot's load, above the toolbar
        if (size.height - (top + insetHeight + 52) - 70 > 30)
          Positioned(
            key: const ValueKey('glance'),
            left: 10,
            top: top + insetHeight + 52,
            bottom: 70,
            width: insetWidth,
            child: Align(
              alignment: Alignment.topLeft,
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: GlancePanel(
                  state: state,
                  language: s.settings.language,
                  showLoad: s.settings.showLoad,
                ),
              ),
            ),
          ),

        Positioned(key: const ValueKey('top'), left: 8, right: 8, top: 6, child: _topBar()),
        Positioned(
          key: const ValueKey('right'),
          right: 10,
          top: top,
          child: _rightRail(size.height - top - 80),
        ),
        // mapping and patrol, bottom centre (clear of the right rail)
        Positioned(
          key: const ValueKey('toolbar'),
          left: middleRight,
          right: middleRight,
          bottom: 10,
          child: Center(child: _toolbar()),
        ),
        // recording / patrol state, e-stop and messages under the top bar
        Positioned(
          key: const ValueKey('notices'),
          top: top,
          left: middleLeft,
          right: middleRight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!s.gamepad.connected)
                IgnorePointer(
                  key: const ValueKey('no-gamepad'),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ToastView(
                      toast: Toast(
                        s.t('no_gamepad'),
                        color: Palette.caution,
                        icon: Icons.videogame_asset_off_rounded,
                      ),
                    ),
                  ),
                ),
              if (tour != null && tour.active)
                Padding(
                  key: const ValueKey('tour'),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TourCard(
                    tour: tour,
                    language: s.settings.language,
                    busy: _busy,
                    onCommand: _tourCommand,
                  ),
                ),
              if (status != null)
                IgnorePointer(
                  key: const ValueKey('status'),
                  child: Padding(padding: const EdgeInsets.only(bottom: 8), child: status),
                ),
              if (state.estop)
                Padding(
                  key: const ValueKey('estop'),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _estopBanner(),
                ),
              IgnorePointer(
                key: const ValueKey('toast'),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _toast == null
                      ? const SizedBox.shrink()
                      : ToastView(key: ValueKey(_toast), toast: _toast!),
                ),
              ),
            ],
          ),
        ),

        if (overlay != null) Positioned.fill(key: const ValueKey('overlay'), child: overlay),
      ],
    );
  }

  Widget _topBar() {
    final state = client.state;
    final welcome = client.welcome;
    final name = welcome != null && welcome.name.isNotEmpty ? welcome.name : client.host;
    final signal = client.signal;
    final rtt = client.rttMs;
    final field = _fieldChip(state.field);
    final loc = _localizationChip(state);

    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                HudButton(
                  icon: Icons.close_rounded,
                  size: 36,
                  label: s.t('disconnect'),
                  onPressed: _leave,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: HudChip(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SignalBars(
                          level: signal,
                          color: signal >= 2 ? Palette.ok : Palette.caution,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(name, style: Txt.label, overflow: TextOverflow.ellipsis),
                        ),
                        if (rtt != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            '${rtt.round()} ms',
                            style: Txt.figure.copyWith(fontSize: 12, color: Palette.muted),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        ModeSwitch(
          mode: state.mode,
          autoLabel: s.t('mode_auto'),
          remoteLabel: s.t('mode_remote'),
          busy: _busy.contains('set_mode'),
          onSelect: _setMode,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state.healthOk == false) ...[
                  HudChip(
                    border: Palette.caution.withValues(alpha: 0.5),
                    onTap: () => _show(
                      Toast(
                        state.healthIssues.isEmpty
                            ? s.t('health_issues')
                            : state.healthIssues.join(', '),
                        color: Palette.caution,
                        icon: Icons.health_and_safety_rounded,
                      ),
                    ),
                    child: const Icon(
                      Icons.health_and_safety_rounded,
                      size: 16,
                      color: Palette.caution,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(child: loc),
                const SizedBox(width: 6),
                if (field != null) ...[
                  Flexible(child: field),
                  const SizedBox(width: 6),
                ],
                BatteryChip(battery: state.battery),
                const SizedBox(width: 8),
                HudButton(
                  icon: Icons.settings_rounded,
                  size: 36,
                  label: s.t('settings'),
                  onPressed: _openSettings,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Localization source: start pose (identity), AprilTag, RViz pose or none; tap for details.
  Widget _localizationChip(RobotState state) {
    final kind = state.localizationKind;
    final (color, icon) = switch (kind) {
      'tag' => (Palette.ok, Icons.qr_code_2_rounded),
      'pose' => (Palette.ok, Icons.ads_click_rounded),
      'start' => (Palette.caution, Icons.home_rounded),
      'other' => (Palette.ok, Icons.my_location_rounded),
      _ => (Palette.stop, Icons.location_disabled_rounded),
    };
    final tag = state.localizationTag;
    final label = kind == 'tag' && tag != null
        ? s.t('loc_tag_named', {'tag': tag})
        : s.t('loc_$kind');
    return HudChip(
      border: color.withValues(alpha: 0.5),
      onTap: () => _show(
        Toast(
          kind == 'none' ? s.t('not_localized') : state.localization,
          color: color,
          icon: icon,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: Txt.label.copyWith(color: color),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Protective field: a quiet shield while clear, its state in words when it slows or stops.
  Widget? _fieldChip(String? field) {
    if (field == null) return null;
    final (color, key) = switch (field) {
      'clear' => (Palette.ok, 'field_clear'),
      'limited' => (Palette.caution, 'field_limited'),
      'stop' => (Palette.stop, 'field_stop'),
      'stale' => (Palette.caution, 'field_stale'),
      _ => (Palette.muted, 'field_off'),
    };
    final loud = const {'limited', 'stop', 'stale'}.contains(field);
    return HudChip(
      border: color.withValues(alpha: 0.5),
      onTap: () => _show(Toast(s.t(key), color: color, icon: Icons.shield_rounded)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shield_rounded, size: 16, color: color),
          if (loud) ...[
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                s.t(key),
                style: Txt.label.copyWith(color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Under the small view: swap the two views; the map follows the robot or shows the route,
  /// and the compass turns it north up or with the robot's heading.
  Widget _viewButtons() {
    final follow = _viewport.mode == MapMode.follow;
    final fit = _viewport.mode == MapMode.fit;
    final headingUp = _viewport.headingUp;
    final pose = client.state.pose;
    // not localized: the map shows the robot looking up, unturned
    final rotation = pose == null ? 0.0 : _viewport.rotationFor(pose.yaw);
    final turned = headingUp || _viewport.rotation.abs() > 0.01;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HudButton(
          icon: Icons.swap_horiz_rounded,
          size: 36,
          label: s.t('swap_views'),
          onPressed: _swapViews,
        ),
        const SizedBox(width: 8),
        HudButton(
          icon: Icons.gps_fixed_rounded,
          size: 36,
          label: s.t('map_follow'),
          tint: follow ? Palette.auto : Palette.text,
          active: follow,
          onPressed: _viewport.follow,
        ),
        const SizedBox(width: 8),
        HudButton(
          icon: Icons.zoom_out_map_rounded,
          size: 36,
          label: s.t('map_fit'),
          tint: fit ? Palette.auto : Palette.text,
          active: fit,
          onPressed: _viewport.fit,
        ),
        const SizedBox(width: 8),
        // the needle points to map north; turned or heading up: back to north up
        HudButton(
          icon: Icons.navigation_rounded,
          iconAngle: -rotation,
          size: 36,
          label: s.t(turned ? 'map_north' : 'map_heading'),
          tint: headingUp ? Palette.auto : Palette.text,
          active: headingUp,
          onPressed: turned ? _viewport.northUp : _viewport.trackHeading,
        ),
      ],
    );
  }

  /// Mapping (the map page, a POI where the robot stands, the AprilTags; while a route is recorded
  /// its finish and stop points), guiding (localize, the guide page, start / pause / resume, end)
  /// and talking with the visitors.
  Widget _toolbar() {
    final state = client.state;
    final welcome = client.welcome;
    bool has(String command) => welcome?.has(command) ?? false;
    bool busy(String command) => _busy.contains(command);
    final recording = state.recording;
    final mapping = state.mapping?.active ?? false;
    final tour = state.tour;
    final touring = tour != null && tour.active;
    final walking = state.planner?.walking ?? false;
    final moving = !_idleNav.contains(state.nav);
    final paused = touring ? tour.paused : state.navPaused;
    final running = touring || moving;
    const width = 50.0;

    return Glass(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // a route being recorded: its finish and stop points take the map and POI places
            if (recording) ...[
              ActionButton(
                key: const ValueKey('act-finish'),
                icon: Icons.stop_circle_rounded,
                label: s.t('act_finish'),
                tint: Palette.stop,
                active: true,
                width: width,
                busy: busy('record_stop'),
                onPressed: has('record_stop')
                    ? () => _run('record_stop', label: s.t('record_saved'))
                    : null,
              ),
              ActionButton(
                key: const ValueKey('act-point'),
                icon: Icons.add_location_alt_rounded,
                label: s.t('act_stop_point'),
                tint: Palette.caution,
                width: width,
                busy: busy('mark_stop'),
                onPressed: has('mark_stop') ? _markStop : null,
              ),
            ] else ...[
              ActionButton(
                key: const ValueKey('act-map'),
                icon: Icons.map_rounded,
                label: s.t('act_map'),
                tint: Palette.remote,
                active: mapping,
                width: width,
                onPressed: welcome != null ? _openSite : null,
              ),
              ActionButton(
                key: const ValueKey('act-poi'),
                icon: Icons.add_location_alt_rounded,
                label: s.t('act_poi'),
                tint: Palette.caution,
                width: width,
                busy: busy('poi_add'),
                onPressed: has('poi_add') && state.pose != null ? _addPoiHere : null,
              ),
            ],
            ActionButton(
              icon: Icons.qr_code_2_rounded,
              label: s.t('act_tags'),
              width: width,
              busy: busy('record_tags'),
              onPressed: has('record_tags')
                  ? () => _run('record_tags', label: s.t('tags_recorded'))
                  : null,
            ),
            const _ToolbarDivider(),
            ActionButton(
              icon: Icons.my_location_rounded,
              label: s.t('act_localize'),
              width: width,
              busy: busy('localize'),
              onPressed: has('localize') ? () => _run('localize', label: s.t('localized')) : null,
            ),
            ActionButton(
              icon: Icons.tour_rounded,
              label: s.t('act_guide'),
              tint: Palette.auto,
              active: touring,
              width: width,
              onPressed: has('tour_start') || has('go_to_poi') ? _openGuide : null,
            ),
            ActionButton(
              icon: running && !paused ? Icons.pause_rounded : Icons.play_arrow_rounded,
              label: s.t(paused ? 'act_resume' : (running ? 'act_pause' : 'act_start')),
              tint: Palette.auto,
              active: running,
              width: width,
              busy:
                  busy('tour_pause') ||
                  busy('tour_resume') ||
                  busy('nav_start') ||
                  busy('nav_pause') ||
                  busy('nav_resume'),
              onPressed: has('tour_start') || has('nav_start') ? _primary : null,
            ),
            ActionButton(
              icon: Icons.stop_rounded,
              label: s.t('act_end'),
              width: width,
              busy: busy('tour_stop') || busy('go_cancel') || busy('nav_stop'),
              onPressed: touring || walking || state.nav != 'NAV_INACTIVE' ? _end : null,
            ),
            const _ToolbarDivider(),
            ActionButton(
              key: const ValueKey('act-talk'),
              icon: Icons.record_voice_over_rounded,
              label: s.t('act_talk'),
              tint: Palette.auto,
              active: state.speech?.speaking ?? false,
              width: width,
              onPressed: has('say') || has('greet') || has('gesture') || has('ask')
                  ? _openTalk
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// STOP, then the robot driver's own commands (stand up, sit down, gaits, ...).
  Widget _rightRail(double listHeight) {
    final commands = client.welcome?.robotCommands ?? const <String>[];
    final language = s.settings.language;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        StopButton(engaged: client.state.estop, onPressed: _estop),
        if (commands.isNotEmpty && listHeight >= 60) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: listHeight),
            child: Glass(
              radius: 16,
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final name in commands)
                      ActionButton(
                        icon: robotAction(name).icon,
                        label: robotAction(name).label(language),
                        width: 58,
                        busy: _busy.contains(name),
                        onPressed: () => _runAction(robotAction(name)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Recording, mapping, walking or route state, under the top bar (a tour has its own card).
  Widget? _statusPill() {
    final state = client.state;
    final since = _recordingSince;
    final mapping = state.mapping;
    final planner = state.planner;
    final touring = state.tour?.active ?? false;
    final recent = DateTime.now().difference(_plannerChanged) < const Duration(seconds: 6);
    final String text;
    final Color color;
    final IconData icon;
    if (state.recording && since != null) {
      final elapsed = DateTime.now().difference(since);
      String two(int value) => value.toString().padLeft(2, '0');
      text = [
        '${s.t('rec')} ${two(elapsed.inMinutes)}:${two(elapsed.inSeconds % 60)}',
        if (_marks.isNotEmpty) s.t('stop_count', {'n': _marks.length}),
      ].join('  ·  ');
      color = Palette.stop;
      icon = Icons.fiber_manual_record_rounded;
    } else if (mapping != null && mapping.active) {
      final area = mapping.area;
      text = [
        s.t('mapping_pill', {'site': mapping.site}),
        if (area != null) '${area.round()} m²',
        s.t('scans', {'n': mapping.scans}),
      ].join('  ·  ');
      color = Palette.remote;
      icon = Icons.map_rounded;
    } else if (touring) {
      return null;
    } else if (planner != null && (planner.walking || (recent && planner.state != 'idle'))) {
      text = _plannerText(planner);
      color = switch (planner.state) {
        'failed' => Palette.stop,
        'arrived' => Palette.ok,
        'cancelled' => Palette.muted,
        _ => Palette.auto,
      };
      icon = Icons.directions_walk_rounded;
    } else if (state.nav != 'NAV_INACTIVE') {
      final label = s.navLabel(state.nav);
      text = state.navMessage.isEmpty ? label : '$label  ·  ${state.navMessage}';
      color = switch (state.nav) {
        'FOLLOWING' || 'JOINING' || 'APPROACHING' || 'DWELLING' => Palette.auto,
        'GOAL_REACHED' => Palette.ok,
        'PAUSED' || 'NO_PATH' || 'TF_UNAVAILABLE' => Palette.caution,
        _ => Palette.stop,
      };
      icon = Icons.route_rounded;
    } else {
      return null;
    }
    return Glass(
      color: Palette.glassHigh,
      border: color.withValues(alpha: 0.6),
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: Txt.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  /// Where the robot walks to (a POI by name, or a place) and how far it still is.
  String _plannerText(PlannerStatus planner) {
    final goal = planner.goal.isEmpty
        ? s.t('a_place')
        : (client.site.value?.poi(planner.goal)?.name ?? planner.goal);
    final line = switch (planner.state) {
      'arrived' => s.t('arrived_at', {'name': goal}),
      'failed' => s.t('no_way', {'name': goal}),
      'cancelled' => s.t('walk_cancelled'),
      'planning' => s.t('finding_way', {'name': goal}),
      _ => s.t('walking_to', {'name': goal}),
    };
    final remaining = planner.remaining;
    return [
      line,
      if (planner.walking && remaining != null)
        s.t('metres_left', {'m': remaining.toStringAsFixed(1)}),
      if (planner.message.isNotEmpty) planner.message,
    ].join('  ·  ');
  }

  Widget _estopBanner() {
    return Glass(
      color: Palette.stop.withValues(alpha: 0.9),
      border: Colors.white.withValues(alpha: 0.55),
      radius: 14,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          const Icon(Icons.pan_tool_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s.t('estop_on'),
              style: Txt.label.copyWith(color: Colors.white),
              maxLines: 2,
            ),
          ),
          const SizedBox(width: 8),
          HoldButton(
            label: s.t('estop_release'),
            busy: _busy.contains('estop_release'),
            onHeld: () => _run('estop_release', label: s.t('estop_released')),
          ),
        ],
      ),
    );
  }

  Widget? _linkOverlay() {
    final name = client.welcome?.name ?? client.host;
    switch (client.status) {
      case LinkStatus.connected:
        return null;
      case LinkStatus.lost:
      case LinkStatus.connecting:
      case LinkStatus.idle:
        final text = client.status == LinkStatus.lost
            ? s.t('link_lost')
            : s.t('connecting_to', {'robot': name});
        return IgnorePointer(
          child: Center(
            child: Glass(
              color: Palette.glassHigh,
              radius: 16,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Palette.caution),
                  ),
                  const SizedBox(width: 12),
                  Text(text, style: Txt.label),
                ],
              ),
            ),
          ),
        );
      case LinkStatus.denied:
      case LinkStatus.busy:
      case LinkStatus.unreachable:
        final (title, hint) = switch (client.status) {
          LinkStatus.denied => (s.t('denied'), s.t('denied_hint')),
          LinkStatus.busy => (s.t('busy'), client.statusDetail),
          _ => (s.t('unreachable'), s.t('unreachable_hint', {'host': client.host})),
        };
        return ColoredBox(
          color: const Color(0xB3000000),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Glass(
                color: Palette.glassHigh,
                radius: 16,
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Txt.title),
                    if (hint.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(hint, style: Txt.body.copyWith(color: Palette.muted)),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(onPressed: _exit, child: Text(s.t('disconnect'))),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: client.retry, child: Text(s.t('retry'))),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
    }
  }
}

/// The camera or the map, full screen or as the small framed box that swaps them on tap.
///
/// The same widget in both places, so a view keeps its state (the decoded video) when moved.
class _ViewBox extends StatelessWidget {
  const _ViewBox({required this.child, this.onTap});

  final Widget child;

  /// Set for the small box.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final small = onTap != null;
    final radius = BorderRadius.circular(small ? 12 : 0);
    final frame = Border.all(color: Colors.white.withValues(alpha: 0.45), width: 1.5);
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(borderRadius: radius, border: small ? frame : null),
        child: ClipRRect(
          borderRadius: radius,
          clipBehavior: small ? Clip.antiAlias : Clip.none,
          child: child,
        ),
      ),
    );
  }
}

class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 34,
      margin: const EdgeInsets.symmetric(horizontal: 5),
      color: Palette.line,
    );
  }
}

/// Press and hold to confirm (releasing the e-stop must be deliberate).
class HoldButton extends StatefulWidget {
  const HoldButton({super.key, required this.label, required this.onHeld, this.busy = false});

  final String label;
  final VoidCallback onHeld;
  final bool busy;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController _hold =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            HapticFeedback.mediumImpact();
            widget.onHeld();
            _hold.value = 0;
          }
        });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.busy ? null : (_) => _hold.forward(),
      onTapUp: (_) => _hold.reverse(),
      onTapCancel: () => _hold.reverse(),
      child: AnimatedBuilder(
        animation: _hold,
        builder: (context, child) => Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            gradient: LinearGradient(
              colors: const [Colors.white, Colors.white, Color(0x33FFFFFF), Color(0x33FFFFFF)],
              stops: [0, _hold.value, _hold.value, 1],
            ),
            border: Border.all(color: Colors.white),
          ),
          child: widget.busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Palette.stop),
                )
              : Text(
                  widget.label,
                  style: Txt.label.copyWith(
                    color: _hold.value > 0.5 ? Palette.stop : Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}
