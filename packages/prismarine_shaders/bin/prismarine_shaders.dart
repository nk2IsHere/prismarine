import 'dart:io';

import 'package:prismarine_shaders/src/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runShadersCli(args, stdout);
}
