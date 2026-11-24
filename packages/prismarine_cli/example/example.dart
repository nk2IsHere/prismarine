import 'package:prismarine_cli/prismarine_cli.dart';

/// Runs `prismarine doctor` in the current folder and prints its exit code.
Future<void> main() async {
  print('doctor exited with ${await runPrismarine(['doctor'])}');
}
