import 'package:prismarine_replay/prismarine_replay.dart';

const format = RouteFormat('exampleRoute');

void main() {
  // A run records the input of each frame.
  final recorder = RouteRecorder(format, {'seed': 1});
  for (final input in [2, 0, 5]) {
    recorder.addFrame(1 / 60, {'add': input});
  }
  // A replay applies the same input frame by frame.
  final route = RouteReader(recorder.lines, format: format);
  var total = 0;
  for (var f = route.next(); f != null; f = route.next()) {
    total += f['add']! as int;
  }
  final hash = routeHashText(route.hashAt(route.length));
  print('total $total, route hash $hash');
}
