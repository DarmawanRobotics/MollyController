import 'package:flutter/material.dart';

/// How a robot driver command or a gesture looks on the action rail and the talk page.
class RobotAction {
  const RobotAction(this.name, this.icon, this.labelId, this.labelEn, {this.confirm = false});

  final String name;
  final IconData icon;
  final String labelId;
  final String labelEn;

  /// Ask before running: the robot drops, or its control changes hands.
  final bool confirm;

  String label(String language) => language == 'id' ? labelId : labelEn;
}

/// The Deep Robotics Lite3 driver's commands (`welcome.robot_commands`) and Molly's gestures
/// (`welcome.gestures`).
const _known = <RobotAction>[
  // posture and modes
  RobotAction('stand_up', Icons.accessibility_new_rounded, 'Berdiri', 'Stand up'),
  RobotAction('sit_down', Icons.airline_seat_recline_normal_rounded, 'Duduk', 'Sit down'),
  RobotAction('move_mode', Icons.directions_walk_rounded, 'Mode jalan', 'Walk mode'),
  RobotAction('pose_mode', Icons.open_with_rounded, 'Mode pose', 'Pose mode'),
  RobotAction('navigation_mode', Icons.navigation_rounded, 'Mode navigasi', 'Nav mode'),
  RobotAction(
    'manual_mode',
    Icons.sports_esports_rounded,
    'Mode manual',
    'Manual mode',
    confirm: true,
  ),
  // gaits
  RobotAction('gait_slow', Icons.speed_rounded, 'Gait pelan', 'Slow gait'),
  RobotAction('gait_medium', Icons.speed_rounded, 'Gait sedang', 'Medium gait'),
  RobotAction('gait_fast', Icons.fast_forward_rounded, 'Gait cepat', 'Fast gait'),
  RobotAction('gait_general', Icons.terrain_rounded, 'Gait umum', 'All-terrain gait'),
  RobotAction('gait_grip', Icons.hiking_rounded, 'Gait cengkeram', 'Grip gait'),
  RobotAction('gait_crawl', Icons.pets_rounded, 'Merangkak', 'Crawl gait'),
  RobotAction('gait_high_step', Icons.stairs_rounded, 'Langkah tinggi', 'High step'),
  RobotAction('keep_stepping_on', Icons.directions_run_rounded, 'Jalan di tempat', 'Step in place'),
  RobotAction(
    'keep_stepping_off',
    Icons.do_not_step_rounded,
    'Berhenti melangkah',
    'Stop stepping',
  ),
  // gestures
  RobotAction('hello', Icons.waving_hand_rounded, 'Sapa', 'Hello'),
  RobotAction('nod', Icons.swap_vert_rounded, 'Mengangguk', 'Nod'),
  RobotAction('bow', Icons.arrow_downward_rounded, 'Membungkuk', 'Bow'),
  RobotAction('look_left', Icons.west_rounded, 'Tengok kiri', 'Look left'),
  RobotAction('look_right', Icons.east_rounded, 'Tengok kanan', 'Look right'),
  RobotAction('stop_action', Icons.do_not_disturb_on_rounded, 'Henti aksi', 'Stop action'),
  // system
  RobotAction('speaker_on', Icons.volume_up_rounded, 'Speaker nyala', 'Speaker on'),
  RobotAction('speaker_off', Icons.volume_off_rounded, 'Speaker mati', 'Speaker off'),
  RobotAction('save_data', Icons.save_rounded, 'Simpan data', 'Save data'),
  RobotAction(
    'reset_zero',
    Icons.restart_alt_rounded,
    'Kalibrasi nol',
    'Zero the joints',
    confirm: true,
  ),
  RobotAction(
    'emergency_stop',
    Icons.dangerous_rounded,
    'Stop motor',
    'Motor stop',
    confirm: true,
  ),
];

final _byName = {for (final action in _known) action.name: action};

/// The catalog entry of a command, or a generic one built from its name.
RobotAction robotAction(String name) {
  final known = _byName[name];
  if (known != null) return known;
  final words = name.replaceAll('_', ' ').trim();
  final label = words.isEmpty ? name : words[0].toUpperCase() + words.substring(1);
  return RobotAction(name, Icons.bolt_rounded, label, label);
}
