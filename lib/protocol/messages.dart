/// JSON messages of the Molly teleop protocol v1 (molly_bridge/PROTOCOL.md).
library;

/// Commands that belong to Molly itself; everything else in `welcome.commands` is the robot's.
const mollyCommands = {
  'set_mode',
  'estop',
  'estop_release',
  'nav_start',
  'nav_stop',
  'nav_pause',
  'nav_resume',
  'nav_speed',
  'record_start',
  'record_stop',
  'mark_stop',
  'load_route',
  'get_route',
  'list_routes',
  'localize',
  'record_tags',
  'site_list',
  'site_load',
  'map_start',
  'map_stop',
  'map_save',
  'get_map',
  'get_site',
  'poi_add',
  'poi_update',
  'poi_delete',
  'tour_save',
  'tour_delete',
  'tour_start',
  'tour_pause',
  'tour_resume',
  'tour_stop',
  'tour_skip',
  'go_to_poi',
  'go_to',
  'go_cancel',
  'say',
  'stop_speech',
  'greet',
  'greeter_set',
  'gesture',
  'ask',
  'people_set',
};

/// A site, POI or tour id as the robot takes it.
final idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,47}$');

/// A site name for `map_start` from what the operator typed, or null when nothing usable is left:
/// lower case, spaces to `_`, other characters dropped (`Lobby East` -> `lobby_east`).
String? siteName(String text) {
  final name = text
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'[^a-z0-9_-]'), '');
  return idPattern.hasMatch(name) ? name : null;
}

double? _num(Object? value) => value is num && value.isFinite ? value.toDouble() : null;

int? _int(Object? value) => _num(value)?.round();

String _str(Object? value, [String fallback = '']) => value is String ? value : fallback;

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const <String>[];

/// A revision counter as text (`3` and `3.0` are the same); null when there is none.
String? revision(Object? value) {
  if (value is String) return value.isEmpty ? null : value;
  final number = _num(value);
  if (number == null) return null;
  return number == number.roundToDouble() ? '${number.round()}' : '$number';
}

/// `state.tags`: rows of [id, x0, y0, x1, y1, x2, y2, x3, y3]; broken rows are skipped.
List<Tag> _tags(Object? value) {
  if (value is! List) return const [];
  final out = <Tag>[];
  for (final row in value) {
    if (row is! List || row.length != 9) continue;
    final numbers = [for (final v in row) _num(v)];
    if (numbers.contains(null)) continue;
    out.add(Tag(numbers.first!.round(), [for (final v in numbers.skip(1)) v!]));
  }
  return out;
}

/// Answer to a LAN `discover` probe.
class Beacon {
  const Beacon({
    required this.host,
    required this.name,
    required this.secured,
    required this.inUseBy,
    required this.seen,
    this.mode,
    this.battery,
    this.site = '',
  });

  factory Beacon.fromJson(Map<String, dynamic> json, String host) => Beacon(
    host: host,
    name: _str(json['name'], host),
    secured: json['secured'] == true,
    inUseBy: _str(json['in_use_by']),
    mode: json['mode'] is String ? json['mode'] as String : null,
    battery: _num(json['battery']),
    site: _str(json['site']),
    seen: DateTime.now(),
  );

  final String host;
  final String name;
  final bool secured;
  final String inUseBy;
  final String? mode;
  final double? battery;

  /// The robot's active site, empty when none is loaded.
  final String site;
  final DateTime seen;
}

/// WebRTC video the robot offers (MediaMTX, WHEP): `http://<robot>:<port>/<path>/whep`.
class VideoOffer {
  const VideoOffer(this.port, this.path);

  /// Null unless `welcome.video` names a valid port and path.
  static VideoOffer? fromJson(Object? json) {
    if (json is! Map) return null;
    final port = json['port'];
    final path = json['path'];
    if (port is! int || port <= 0 || port > 65535) return null;
    if (path is! String || !RegExp(r'^[A-Za-z0-9_.~-]+(/[A-Za-z0-9_.~-]+)*$').hasMatch(path)) {
      return null;
    }
    if (path.split('/').any((segment) => segment == '.' || segment == '..')) return null;
    return VideoOffer(port, path);
  }

  final int port;
  final String path;

  /// The WHEP endpoint on the robot at [host] (the address the teleop link uses).
  Uri whep(String host) =>
      Uri(scheme: 'http', host: host, port: port, pathSegments: [...path.split('/'), 'whep']);
}

/// The robot's answer to `hello`.
class Welcome {
  const Welcome({
    required this.name,
    required this.commands,
    required this.robotCommands,
    required this.limits,
    this.protocol = '',
    this.gestures = const [],
    this.features = const [],
    this.video,
  });

  factory Welcome.fromJson(Map<String, dynamic> json) {
    final commands = _strings(json['commands']);
    final robot = json.containsKey('robot_commands')
        ? _strings(json['robot_commands'])
        : commands.where((c) => !mollyCommands.contains(c)).toList();
    final raw = json['limits'];
    final limits = raw is List && raw.length == 3 && raw.every((v) => _num(v) != null)
        ? raw.map((v) => _num(v)!).toList()
        : const [0.5, 0.3, 1.0];
    return Welcome(
      name: _str(json['name']),
      commands: commands,
      robotCommands: robot,
      limits: limits,
      protocol: _str(json['protocol']),
      gestures: _strings(json['gestures']),
      features: _strings(json['features']),
      video: VideoOffer.fromJson(json['video']),
    );
  }

  final String name;
  final List<String> commands;

  /// The robot driver's commands (std_srvs/Trigger), in the order the robot lists them.
  final List<String> robotCommands;

  /// Speed maxima [vx m/s, vy m/s, wz rad/s].
  final List<double> limits;

  /// `molly-1` for this protocol.
  final String protocol;

  /// Gestures `gesture` takes (hello, nod, bow, ...).
  final List<String> gestures;

  /// What runs on the robot: mapping, planner, guide, speech, greeter, conversation, people.
  final List<String> features;

  /// WebRTC video, when the robot runs MediaMTX; else the camera comes as JPEG frames only.
  final VideoOffer? video;

  bool has(String command) => commands.contains(command);

  bool hasFeature(String feature) => features.contains(feature);
}

class Pose {
  const Pose(this.x, this.y, this.yaw);

  final double x;
  final double y;
  final double yaw;
}

class Battery {
  const Battery({this.percent, this.voltage, this.current, this.temperature});

  final double? percent;
  final double? voltage;
  final double? current;
  final double? temperature;
}

/// One `state` telemetry message (10 Hz).
class RobotState {
  const RobotState({
    this.seq = 0,
    this.pose,
    this.mode = 'auto',
    this.nav = 'NAV_INACTIVE',
    this.navMessage = '',
    this.mission = '',
    this.localization = 'none',
    this.recording = false,
    this.battery,
    this.driverLevel,
    this.driverMessage = '',
    this.cmd = const [0.0, 0.0, 0.0],
    this.healthOk,
    this.healthIssues = const [],
    this.estop = false,
    this.field,
    this.tags = const [],
    this.people,
    this.load,
    this.speed,
    this.site,
    this.mapping,
    this.planner,
    this.tour,
    this.speech,
    this.visitors,
    this.greeter,
    this.mapRev,
  });

  factory RobotState.fromJson(Map<String, dynamic> json) {
    final pose = json['pose'];
    final battery = json['battery'];
    final driver = json['driver'];
    final health = json['health'];
    final cmd = json['cmd'];
    return RobotState(
      seq: json['seq'] is int ? json['seq'] as int : 0,
      pose: pose is List && pose.length == 3 && pose.every((v) => _num(v) != null)
          ? Pose(_num(pose[0])!, _num(pose[1])!, _num(pose[2])!)
          : null,
      mode: _str(json['mode'], 'auto'),
      nav: _str(json['nav'], 'NAV_INACTIVE'),
      navMessage: _str(json['nav_msg']),
      mission: _str(json['mission']),
      localization: _str(json['localization'], 'none'),
      recording: json['recording'] == true,
      battery: battery is Map
          ? Battery(
              percent: _num(battery['pct']),
              voltage: _num(battery['v']),
              current: _num(battery['a']),
              temperature: _num(battery['temp']),
            )
          : null,
      driverLevel: driver is Map && driver['level'] is int ? driver['level'] as int : null,
      driverMessage: driver is Map ? _str(driver['msg']) : '',
      cmd: cmd is List && cmd.length == 3
          ? cmd.map((v) => _num(v) ?? 0.0).toList()
          : const [0.0, 0.0, 0.0],
      healthOk: health is Map ? health['ok'] == true : null,
      healthIssues: health is Map ? _strings(health['issues']) : const [],
      estop: json['estop'] == true,
      field: json['field'] is String ? json['field'] as String : null,
      tags: _tags(json['tags']),
      people: PeopleStatus.fromJson(json['people']),
      load: SystemLoad.fromJson(health),
      speed: WalkSpeed.fromJson(json['speed']),
      site: SiteStatus.fromJson(json['site']),
      mapping: MappingStatus.fromJson(json['mapping']),
      planner: PlannerStatus.fromJson(json['planner']),
      tour: TourStatus.fromJson(json['tour']),
      speech: SpeechStatus.fromJson(json['speech']),
      visitors: Visitors.fromJson(json['visitors']),
      greeter: GreeterStatus.fromJson(json['greeter']),
      mapRev: revision(json['map_rev']),
    );
  }

  final int seq;
  final Pose? pose;

  /// `auto` (navigation drives) or `remote` (the handheld drives).
  final String mode;
  final String nav;
  final String navMessage;
  final String mission;
  final String localization;
  final bool recording;
  final Battery? battery;
  final int? driverLevel;
  final String driverMessage;

  /// Velocity actually sent to the robot [vx, vy, wz].
  final List<double> cmd;
  final bool? healthOk;
  final List<String> healthIssues;
  final bool estop;

  /// Protective field: clear, limited, stop, stale, off, or null.
  final String? field;

  /// AprilTags the robot sees in the camera image now.
  final List<Tag> tags;

  /// Person detection on the camera; null when the robot runs none.
  final PeopleStatus? people;

  /// CPU, GPU and memory use of the robot's computer, from its health monitor.
  final SystemLoad? load;

  /// Walking speed of the navigation; null when navigation does not run.
  final WalkSpeed? speed;

  /// The active site; null when the robot runs no site manager.
  final SiteStatus? site;

  /// The mapping session; null when the robot runs no mapper.
  final MappingStatus? mapping;

  /// Walking to a POI or pose with the path finder; null without a planner.
  final PlannerStatus? planner;

  /// The guide's tour; null without a guide.
  final TourStatus? tour;

  /// What the robot says; null without speech.
  final SpeechStatus? speech;

  /// People around the robot from the lidar; null without a visitor tracker.
  final Visitors? visitors;

  /// Automatic greeting of visitors; null without one.
  final GreeterStatus? greeter;

  /// Revision of the map the robot has now; differs from the map received: ask `get_map`.
  final String? mapRev;

  bool get remote => mode == 'remote';
  bool get localized => localization.isNotEmpty && localization != 'none';

  /// Where map->odom comes from: none, start (the map origin), tag, pose (RViz), other.
  String get localizationKind {
    if (!localized) return 'none';
    if (localization.startsWith('tag:') || localization.startsWith('apriltag')) return 'tag';
    if (localization == 'origin' || localization.startsWith('start')) return 'start';
    if (localization == 'pose_estimate' || localization.contains('Pose Estimate')) return 'pose';
    return 'other';
  }

  /// The tag frame of a tag localization (`lobby_1` from `tag:lobby_1`, or from
  /// `apriltag "lobby_1" (auto start)`).
  String? get localizationTag {
    if (localization.startsWith('tag:')) {
      final frame = localization.substring(4).trim();
      return frame.isEmpty ? null : frame;
    }
    return RegExp(r'"([^"]+)"').firstMatch(localization)?.group(1);
  }

  bool get navPaused => nav == 'PAUSED';
  bool get navActive => !const {'NAV_INACTIVE', 'NO_PATH', 'PAUSED'}.contains(nav);
}

/// An AprilTag in the camera image.
class Tag {
  const Tag(this.id, this.corners);

  final int id;

  /// x0, y0, ... x3, y3 as fractions of the image width and height.
  final List<double> corners;
}

class RoutePoint {
  const RoutePoint(this.x, this.y, this.dwell);

  final double x;
  final double y;

  /// Seconds the robot stops here; 0 for a plain waypoint.
  final double dwell;

  bool get isStop => dwell > 0;
}

/// `state.speed`: the walking speed and the range the handheld may set, m/s.
class WalkSpeed {
  const WalkSpeed(this.target, this.min, this.max);

  /// Null unless all three are numbers and 0 < min <= max.
  static WalkSpeed? fromJson(Object? json) {
    if (json is! Map) return null;
    final target = _num(json['target']);
    final low = _num(json['min']);
    final high = _num(json['max']);
    if (target == null || low == null || high == null || low <= 0 || high < low) return null;
    return WalkSpeed(target, low, high);
  }

  final double target;
  final double min;
  final double max;
}

/// `state.people`: the robot's person detection on the camera (person_detector_node).
class PeopleStatus {
  const PeopleStatus({
    required this.on,
    required this.state,
    this.count,
    this.latencyMs = 0,
    this.age,
    this.backend = '',
    this.error = '',
    this.boxes = const [],
  });

  /// Null unless the robot sent a people object.
  static PeopleStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    return PeopleStatus(
      on: json['on'] == true,
      state: _str(json['state'], 'offline'),
      count: _num(json['count'])?.round(),
      latencyMs: _num(json['ms'])?.round() ?? 0,
      age: _num(json['age'])?.round(),
      backend: _str(json['backend']),
      error: _str(json['error']),
      boxes: _personBoxes(json['boxes']),
    );
  }

  static List<PersonBox> _personBoxes(Object? json) {
    if (json is! List) return const [];
    final boxes = <PersonBox>[];
    for (final row in json) {
      if (row is! List || row.length != 5) continue;
      final v = [for (final x in row) _num(x)];
      if (v.contains(null)) continue;
      boxes.add(PersonBox(v[0]!, v[1]!, v[2]!, v[3]!, v[4]!));
    }
    return boxes;
  }

  final bool on;

  /// People in the last frame, as fractions of the image; empty when that frame is old.
  final List<PersonBox> boxes;

  /// loading, running, off, error, or offline (the robot stopped hearing from the detector).
  final String state;

  /// People in the last frame the robot looked at; null before the first.
  final int? count;
  final int latencyMs;

  /// Seconds since that frame; null when unknown.
  final int? age;

  /// What runs the model, e.g. onnxruntime-cpu.
  final String backend;
  final String error;
}

/// The robot computer's load (`state.health`): percentages, memory in GB, hottest zone in C.
class SystemLoad {
  const SystemLoad({this.cpu, this.gpu, this.ram, this.ramUsed, this.ramTotal, this.temp});

  /// Null unless the health object carries at least one figure.
  static SystemLoad? fromJson(Object? json) {
    if (json is! Map) return null;
    final load = SystemLoad(
      cpu: _num(json['cpu']),
      gpu: _num(json['gpu']),
      ram: _num(json['ram']),
      ramUsed: _num(json['ram_used']),
      ramTotal: _num(json['ram_total']),
      temp: _num(json['temp']),
    );
    final figures = [load.cpu, load.gpu, load.ram, load.ramUsed, load.temp];
    return figures.every((v) => v == null) ? null : load;
  }

  final double? cpu;

  /// Null on a computer without a Jetson GPU.
  final double? gpu;
  final double? ram;
  final double? ramUsed;
  final double? ramTotal;
  final double? temp;
}

/// A detected person: corners as fractions of the camera image, and the detector's score.
class PersonBox {
  const PersonBox(this.x1, this.y1, this.x2, this.y2, this.score);

  final double x1, y1, x2, y2, score;
}

/// `state.site`: the robot's active site and what it holds.
class SiteStatus {
  const SiteStatus({
    this.name = '',
    this.hasMap = false,
    this.pois = 0,
    this.tours = 0,
    this.tags = 0,
    this.rev,
  });

  static SiteStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    return SiteStatus(
      name: _str(json['name']),
      hasMap: json['map'] == true,
      pois: _int(json['pois']) ?? 0,
      tours: _int(json['tours']) ?? 0,
      tags: _int(json['tags']) ?? 0,
      rev: revision(json['rev']),
    );
  }

  /// Empty when no site is loaded.
  final String name;
  final bool hasMap;
  final int pois;
  final int tours;

  /// AprilTags recorded for the site.
  final int tags;

  /// Revision of the site stream (POIs and tours); differs from the one received: `get_site`.
  final String? rev;

  bool get loaded => name.isNotEmpty;
}

/// `state.mapping`: the mapping session.
class MappingStatus {
  const MappingStatus({this.active = false, this.site = '', this.scans = 0, this.area});

  static MappingStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    return MappingStatus(
      active: json['active'] == true,
      site: _str(json['site']),
      scans: _int(json['scans']) ?? 0,
      area: _num(json['area']),
    );
  }

  /// Scans are being added to the map.
  final bool active;
  final String site;
  final int scans;

  /// Known area of the map, square metres.
  final double? area;
}

/// `state.planner`: walking to a POI or a pose with the path finder.
class PlannerStatus {
  const PlannerStatus({this.state = 'idle', this.goal = '', this.remaining, this.message = ''});

  static PlannerStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    return PlannerStatus(
      state: _str(json['state'], 'idle'),
      goal: _str(json['goal']),
      remaining: _num(json['remaining']),
      message: _str(json['msg']),
    );
  }

  /// idle, planning, following, replanning, arrived, failed, cancelled.
  final String state;

  /// POI id, empty for a pose.
  final String goal;

  /// Metres still to walk.
  final double? remaining;
  final String message;

  /// Walking (or about to): the walk can be cancelled.
  bool get walking => const {'planning', 'following', 'replanning'}.contains(state);
}

/// `state.tour`: the guide's tour.
class TourStatus {
  const TourStatus({
    this.state = 'idle',
    this.tourId = '',
    this.name = '',
    this.index = -1,
    this.total = 0,
    this.poiId = '',
    this.poiName = '',
    this.activity = '',
    this.message = '',
  });

  static TourStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    return TourStatus(
      state: _str(json['state'], 'idle'),
      tourId: _str(json['tour_id']),
      name: _str(json['name']),
      index: _int(json['index']) ?? -1,
      total: _int(json['total']) ?? 0,
      poiId: _str(json['poi_id']),
      poiName: _str(json['poi_name']),
      activity: _str(json['activity']),
      message: _str(json['msg']),
    );
  }

  /// idle, starting, running, paused, stopping, error.
  final String state;
  final String tourId;
  final String name;

  /// The stop under way, 0-based; -1 when idle.
  final int index;
  final int total;
  final String poiId;
  final String poiName;

  /// navigating, waiting_visitors, performing_motion, narrating, dwelling, returning or empty.
  final String activity;
  final String message;

  /// A tour is under way (also while paused or failing).
  bool get active => state != 'idle';
  bool get paused => state == 'paused';
  bool get running => state == 'running' || state == 'starting';
}

/// `state.speech`: what the robot says.
class SpeechStatus {
  const SpeechStatus({this.state = 'idle', this.text = '', this.queued = 0});

  static SpeechStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    return SpeechStatus(
      state: _str(json['state'], 'idle'),
      text: _str(json['text']),
      queued: _int(json['queued']) ?? 0,
    );
  }

  /// idle, speaking, done, failed, cancelled.
  final String state;
  final String text;

  /// Utterances waiting after this one.
  final int queued;

  bool get speaking => state == 'speaking';
}

/// `state.visitors`: people around the robot (lidar).
class Visitors {
  const Visitors({this.count = 0, this.front = 0, this.behind = 0, this.nearest});

  static Visitors? fromJson(Object? json) {
    if (json is! Map) return null;
    return Visitors(
      count: _int(json['count']) ?? 0,
      front: _int(json['front']) ?? 0,
      behind: _int(json['behind']) ?? 0,
      nearest: _num(json['nearest']),
    );
  }

  final int count;

  /// In front of the robot.
  final int front;

  /// Behind the robot: following it on a tour.
  final int behind;

  /// Metres to the nearest one; null when nobody is near.
  final double? nearest;
}

/// `state.greeter`: greeting approaching visitors on its own.
class GreeterStatus {
  const GreeterStatus({this.enabled = false, this.state = ''});

  static GreeterStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    return GreeterStatus(enabled: json['enabled'] == true, state: _str(json['state']));
  }

  final bool enabled;
  final String state;
}

/// A point of interest of the active site (map frame).
class Poi {
  const Poi({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    this.yaw = 0,
    this.description = '',
    this.narration = '',
    this.language = '',
    this.gesture = '',
    this.dwell = 0,
  });

  /// Null unless the entry has an id and a position.
  static Poi? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final x = _num(json['x']);
    final y = _num(json['y']);
    if (id is! String || id.isEmpty || x == null || y == null) return null;
    return Poi(
      id: id,
      name: _str(json['name'], id),
      x: x,
      y: y,
      yaw: _num(json['yaw']) ?? 0,
      description: _str(json['description']),
      narration: _str(json['narration']),
      language: _str(json['language']),
      gesture: _str(json['gesture']),
      dwell: _num(json['dwell']) ?? 0,
    );
  }

  final String id;
  final String name;
  final double x;
  final double y;

  /// Heading the robot takes on arrival, radians.
  final double yaw;
  final String description;

  /// Said on arrival; empty: nothing.
  final String narration;

  /// Narration language (id, en); empty: the robot's default.
  final String language;

  /// Gesture on arrival; empty: none.
  final String gesture;

  /// Seconds the robot stays after the narration.
  final double dwell;

  /// As `poi_update` takes it (every field).
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'x': x,
    'y': y,
    'yaw': yaw,
    'narration': narration,
    'language': language,
    'gesture': gesture,
    'dwell': dwell,
  };
}

/// An ordered list of POIs the guide walks through.
class Tour {
  const Tour({
    required this.id,
    required this.name,
    this.description = '',
    this.poiIds = const [],
    this.returnPoiId = '',
  });

  /// Null unless the entry has an id.
  static Tour? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    return Tour(
      id: id,
      name: _str(json['name'], id),
      description: _str(json['description']),
      poiIds: _strings(json['poi_ids']),
      returnPoiId: _str(json['return_poi_id']),
    );
  }

  /// Empty for a tour not saved yet (the robot gives it one).
  final String id;
  final String name;
  final String description;
  final List<String> poiIds;

  /// Where the robot walks after the last stop; empty: it stays there.
  final String returnPoiId;

  /// As `tour_save` takes it.
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'poi_ids': poiIds,
    'return_poi_id': returnPoiId,
  };
}

/// The site stream: the POIs and tours of the active site.
class SiteData {
  const SiteData({this.rev, this.name = '', this.pois = const [], this.tours = const []});

  /// Broken POIs and tours are skipped; null unless [json] is a map.
  static SiteData? fromJson(Object? json) {
    if (json is! Map) return null;
    final pois = json['pois'];
    final tours = json['tours'];
    return SiteData(
      rev: revision(json['rev']),
      name: _str(json['name']),
      pois: pois is List ? pois.map(Poi.fromJson).whereType<Poi>().toList() : const <Poi>[],
      tours: tours is List ? tours.map(Tour.fromJson).whereType<Tour>().toList() : const <Tour>[],
    );
  }

  final String? rev;
  final String name;
  final List<Poi> pois;
  final List<Tour> tours;

  Poi? poi(String id) {
    for (final poi in pois) {
      if (poi.id == id) return poi;
    }
    return null;
  }

  Tour? tour(String id) {
    for (final tour in tours) {
      if (tour.id == id) return tour;
    }
    return null;
  }
}

/// Where the map image lies in the map frame (the JSON header of the map stream).
class MapHeader {
  const MapHeader({
    required this.resolution,
    required this.originX,
    required this.originY,
    required this.width,
    required this.height,
    this.rev,
    this.site = '',
  });

  /// Null unless the resolution and the size are positive.
  static MapHeader? fromJson(Object? json) {
    if (json is! Map) return null;
    final resolution = _num(json['res']);
    final x = _num(json['ox']);
    final y = _num(json['oy']);
    final width = _int(json['w']);
    final height = _int(json['h']);
    if (resolution == null || resolution <= 0 || x == null || y == null) return null;
    if (width == null || height == null || width <= 0 || height <= 0) return null;
    return MapHeader(
      resolution: resolution,
      originX: x,
      originY: y,
      width: width,
      height: height,
      rev: revision(json['rev']),
      site: _str(json['site']),
    );
  }

  /// Metres per pixel.
  final double resolution;

  /// Map position of the bottom-left corner of the image.
  final double originX;
  final double originY;

  /// Pixels.
  final int width;
  final int height;
  final String? rev;
  final String site;

  double get widthMetres => width * resolution;
  double get heightMetres => height * resolution;
}
