// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: public_member_api_docs

part of flutter_gpu;

base class UniformSlot {
  UniformSlot._(this.shader, this.uniformName);
  final Shader shader;
  final String uniformName;

  // mcsm G2: the shader's index for this name as a uniform struct and as a
  // texture, resolved on first use (-2 = not yet, -1 = no such uniform).
  int _structIndex = -2;
  int _textureIndex = -2;

  int get _resolvedStructIndex => _structIndex != -2
      ? _structIndex
      : (_structIndex = shader._resolveUniformStruct(uniformName));

  int get _resolvedTextureIndex => _textureIndex != -2
      ? _textureIndex
      : (_textureIndex = shader._resolveUniformTexture(uniformName));

  /// The reflected total size of a shader's uniform struct by name.
  ///
  /// Returns [null] if the shader does not contain a uniform struct with the
  /// given name.
  int? get sizeInBytes {
    int size = shader._getUniformStructSize(uniformName);
    return size < 0 ? null : size;
  }

  /// Get the reflected offset of a named member in the uniform struct.
  ///
  /// Returns [null] if the shader does not contain a uniform struct with the
  /// given name, or if the uniform struct does not contain a member with the
  /// given name.
  int? getMemberOffsetInBytes(String memberName) {
    int offset = shader._getUniformMemberOffset(uniformName, memberName);
    return offset < 0 ? null : offset;
  }
}

base class Shader extends NativeFieldWrapperClass1 {
  // [Shader] handles are instantiated when interacting with a [ShaderLibrary].
  Shader._();

  UniformSlot getUniformSlot(String uniformName) {
    return UniformSlot._(this, uniformName);
  }

  // mcsm G2
  @Native<Int Function(Pointer<Void>, Handle)>(
    symbol: 'InternalFlutterGpu_Shader_ResolveUniformStruct',
  )
  external int _resolveUniformStruct(String uniformStructName);

  // mcsm G2
  @Native<Int Function(Pointer<Void>, Handle)>(
    symbol: 'InternalFlutterGpu_Shader_ResolveUniformTexture',
  )
  external int _resolveUniformTexture(String uniformTextureName);

  @Native<Int Function(Pointer<Void>, Handle)>(
    symbol: 'InternalFlutterGpu_Shader_GetUniformStructSize',
  )
  external int _getUniformStructSize(String uniformStructName);

  @Native<Int Function(Pointer<Void>, Handle, Handle)>(
    symbol: 'InternalFlutterGpu_Shader_GetUniformMemberOffset',
  )
  external int _getUniformMemberOffset(
    String uniformStructName,
    String memberName,
  );

  /// Test-only. Whether this shader is currently marked dirty (will be
  /// evicted and re-registered with the impeller shader library on next
  /// pipeline build). Used by tests to assert that reload dedupe keeps
  /// unchanged shaders clean.
  bool get debugIsDirty => _debugIsDirty();

  @Native<Bool Function(Pointer<Void>)>(
    symbol: 'InternalFlutterGpu_Shader_DebugIsDirty',
  )
  external bool _debugIsDirty();
}
