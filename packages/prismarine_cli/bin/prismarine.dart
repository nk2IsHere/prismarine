import 'dart:io';

import 'package:prismarine_cli/prismarine_cli.dart';
import 'package:prismarine_cli/src/self_update.dart';

Future<void> main(List<String> args) async {
  final code = await updateSelf(args) ?? await runPrismarine(args);
  await stdout.flush();
  exit(code);
}
