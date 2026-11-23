import 'package:flutter_test/flutter_test.dart';
import 'package:prismarine_scene/build_hooks.dart';

void main() {
  test('a bundle keeps the backend that the target loads', () {
    expect(shaderBackendsFor('macos'), {'metal_desktop'});
    expect(shaderBackendsFor('linux'), {'vulkan'});
    expect(shaderBackendsFor('windows'), {'vulkan'});
    expect(shaderBackendsFor(null), {'metal_desktop', 'vulkan'});
  });
}
