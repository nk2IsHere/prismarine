import 'package:args/args.dart';

import 'shader_bundle.dart';

/// The options of `prismarine_shaders bundle`.
ArgParser bundleArgParser() => ArgParser()
  ..addOption(
    'impellerc',
    help:
        'The impellerc to run. The default is PRISMARINE_IMPELLERC, else '
        'MCSM_IMPELLERC.',
  )
  ..addMultiOption(
    'backend',
    defaultsTo: ['metal_desktop=metal', 'vulkan=vulkan'],
    help:
        'An impellerc backend and the folder of its bundles, as <backend>=<folder>.',
  )
  ..addMultiOption(
    'impellerc-arg',
    splitCommas: false,
    help: 'An argument for every impellerc run, such as --metal-version=2.3.',
  )
  ..addMultiOption(
    'option',
    splitCommas: false,
    help:
        'An entry option and its value, such as '
        'metal_preserve_invariance=true. Values true and false are booleans.',
  )
  ..addOption(
    'jobs',
    defaultsTo: '4',
    help: 'The number of impellerc runs at a time.',
  )
  ..addOption(
    'shard',
    defaultsTo: '$shardEntries',
    help: 'The number of entries in a shard.',
  )
  ..addOption(
    'cache',
    help: 'The directory of the shard cache. The default is no cache.',
  )
  ..addMultiOption(
    'effects',
    help: 'Builds only the shards of these effects again.',
  )
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Prints this help.');

/// Returns the bundle settings of the parsed [args].
ShaderBundleSettings bundleSettings(ArgResults args) {
  MapEntry<String, String> pair(String text) {
    final at = text.indexOf('=');
    if (at <= 0) {
      throw FormatException('Expected <name>=<value>, got "$text".');
    }
    return MapEntry(text.substring(0, at), text.substring(at + 1));
  }

  return ShaderBundleSettings(
    backends: Map.fromEntries((args['backend'] as List<String>).map(pair)),
    impellercArgs: args['impellerc-arg'] as List<String>,
    entryOptions: {
      for (final MapEntry(:key, :value) in (args['option'] as List<String>).map(
        pair,
      ))
        key: switch (value) {
          'true' => true,
          'false' => false,
          _ => value,
        },
    },
  );
}

/// Runs the command line with [arguments] and writes its output to [out].
/// Returns the exit code.
Future<int> runShadersCli(List<String> arguments, StringSink out) async {
  final parser = bundleArgParser();
  const usage = 'prismarine_shaders bundle <root> [options]';
  if (arguments.isEmpty || arguments.first != 'bundle') {
    out.writeln('Usage: $usage\n${parser.usage}');
    return 64;
  }
  final ArgResults args;
  try {
    args = parser.parse(arguments.skip(1));
  } on FormatException catch (e) {
    out.writeln('${e.message}\nUsage: $usage');
    return 64;
  }
  if (args['help'] as bool) {
    out.writeln(
      'Builds the shader bundles of the program tree in <root>/programs '
      'into <root>/bundle.\nUsage: $usage\n${parser.usage}',
    );
    return 0;
  }
  if (args.rest.length != 1) {
    out.writeln('Expected one <root>.\nUsage: $usage');
    return 64;
  }
  final impellerc = args['impellerc'] as String? ?? findImpellerc();
  if (impellerc == null) {
    out.writeln(
      'No impellerc found. Set PRISMARINE_IMPELLERC or pass --impellerc.',
    );
    return 66;
  }
  final ShaderBundleSettings settings;
  try {
    settings = bundleSettings(args);
  } on FormatException catch (e) {
    out.writeln(e.message);
    return 64;
  }
  final effects = args['effects'] as List<String>;
  final report = await buildShaderBundles(
    args.rest.single,
    settings,
    impellerc: impellerc,
    jobs: int.parse(args['jobs'] as String),
    shard: int.parse(args['shard'] as String),
    effects: effects.isEmpty ? null : effects.toSet(),
    cacheDir: args['cache'] as String?,
  );
  out.writeln(
    '${report.bundled} bundled, ${report.cached} from the cache, '
    '${report.failed.length} failed, bytes per backend ${report.bytes}',
  );
  for (final MapEntry(:key, :value) in report.failed.entries) {
    out.writeln('failed $key: $value');
  }
  return report.failed.isEmpty ? 0 : 1;
}
