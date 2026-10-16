// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: public_member_api_docs

part of flutter_gpu;

// Lazily registers the Flutter GPU service extensions the first time a
// shader library is loaded in debug mode. Mirrors `_setupHooks` in
// `lib/ui/natives.dart` but is driven on demand because the `flutter_gpu`
// library is loaded only when the embedder imports it. Calling more than
// once is safe.
bool _hooksRegistered = false;
void _ensureHooksRegistered() {
  if (_hooksRegistered) {
    return;
  }
  _hooksRegistered = true;
  developer.registerExtension(
    'ext.ui.gpu.reinitializeShaderLibrary',
    _reinitializeShaderLibrary,
  );
}

Future<developer.ServiceExtensionResponse> _reinitializeShaderLibrary(
  String method,
  Map<String, String> parameters,
) async {
  final String? assetKey = parameters['assetKey'];
  if (assetKey != null) {
    ShaderLibrary.reinitialize(assetKey);
  }
  return developer.ServiceExtensionResponse.result(
    json.encode(<String, String>{'type': 'Success'}),
  );
}

// mcsm G1: whether the engine has the perf E exports (resolved-slot binds and
// the cached draw; third_party/flutter_engine/patches). With Flutter's
// prebuilt engine every call takes the stock path.
final bool _mcsmEngineE3 = DynamicLibrary.process().providesSymbol(
  'InternalFlutterGpu_RenderPass_BindUniformIndexed',
);
