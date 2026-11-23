import 'package:hooks/hooks.dart';
import 'package:prismarine_cook/prismarine_cook.dart';

// Cooks the shaders of prismarine.yaml when their inputs changed.
void main(List<String> args) async {
  await build(args, cookHook);
}
