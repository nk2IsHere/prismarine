import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_frame/prismarine_frame.dart';
import 'package:prismarine_render/prismarine_render.dart';

// Tests which render passes a layout draws in pulled form: its named passes
// and those whose names start with one of its prefixes.
void main() {
  final layout = PulledLayout(
    objectRow: RowLayout('object', const []),
    instanceRow: RowLayout('instance', const []),
    passes: const {'main', 'glow_over'},
    passPrefixes: const ['main '],
    mainPass: 'main',
    cameraBlock: 'Camera',
    objectBlock: 'Object',
    instanceBlock: 'Instance',
    materialBaseBlock: 'MaterialBase',
    materialMainBlock: 'MaterialMain',
    materialTexturePrefix: 'Material',
    uvTransforms: const [],
    cascadesBuffer: 'cascades',
    frustumPlanes: (_) => const [],
  );

  test('the named passes and those a prefix starts', () {
    expect(layout.pulls('main'), isTrue);
    expect(layout.pulls('glow_over'), isTrue);
    expect(layout.pulls('main ui_dialog.scene'), isTrue);
    expect(layout.pulls('mainly'), isFalse);
    expect(layout.pulls('resolve'), isFalse);
  });
}
