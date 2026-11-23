import 'dart:io';

/// Returns the environment variable `PRISMARINE_<name>`, else
/// `MCSM_<name>`.
String? envVar(String name) =>
    Platform.environment['PRISMARINE_$name'] ??
    Platform.environment['MCSM_$name'];
