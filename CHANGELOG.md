# Changelog

Versions follow `version` in `pubspec.yaml`.

## Unreleased

**Docs**
- README: configuration table (defaults from `lib/settings.dart`) and a protocol section.
- Comments no longer call the stop point wait an inspection time.

## 0.1.0 (2026-10-17)

The first Molly Controller, started from Pashupati Controller 2.6.1 (its history is kept).

**Added**
- Molly's teleop protocol v1 (`molly-1`, UDP port 9880, `MLY1` stream header): the site,
  mapping, path finder, tour, speech, visitor and greeter state, the welcome's gestures and
  features, and the beacon's site.
- The map (stream 4) and site (stream 5) streams. A map or site whose revision the handheld
  missed is asked for again (`get_map`, `get_site`).
- The site's occupancy map on the map view, under the path, the trail and the lidar, with the
  points of interest and their names. A long press on the map walks the robot there (`go_to`).
- Map page: the robot's sites, a new map or the active one extended, save and stop, AprilTags,
  localization, points of interest (name, narration, language, gesture, wait; edit, move to the
  robot, delete), tours from the points of interest, routes.
- POI icon on the main screen: a point of interest where the robot stands.
- Guide page: start a tour or a tour of every point, walk to a point, walking speed, person
  detection. The tour under way has a card on the main screen and on the Guide page: pause /
  resume, next stop, end.
- Talk page: say typed text or quick phrases in Indonesian or English, cut in, stop talking, ask
  a question, the greeter, gestures and the visitors around the robot.
- At a glance: what the robot says, the visitors and how many follow, the greeter.
- The Deep Robotics Lite3's commands and gestures on the action rail, in both languages.

**Changed**
- App name Molly Controller, Android id `com.darmawanrobotics.molly_controller`, the Molly logo,
  version 0.1.0.
- The toolbar: Map, POI, Tags | Localize, Guide, Start, End | Talk. While a route is recorded,
  Finish and Point take the places of Map and POI. Routes moved to the Map page.
- Start resumes or pauses the tour under way, else the walk or the loaded route; with nothing to
  follow it opens the Guide page. End stops the tour, the walk or the route.

**Removed**
- The VLM inspection (its page, state and commands): Molly guides, it does not inspect.
- The screenshot test and its workflow.
