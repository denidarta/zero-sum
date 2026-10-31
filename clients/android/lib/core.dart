// dart:ffi bridge to the Rust core (`crates/ffi-c`). Merge and budget rules live
// in Rust only, so this client cannot disagree with the server.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _Fn2 = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _Free = Void Function(Pointer<Utf8>);
typedef _FreeD = void Function(Pointer<Utf8>);

class CoreException implements Exception {
  CoreException(this.message);
  final String message;
  @override
  String toString() => 'CoreException: $message';
}

class Core {
  Core._(DynamicLibrary lib)
    : _merge = lib.lookupFunction<_Fn2, _Fn2>('zs_merge'),
      _budget = lib.lookupFunction<_Fn2, _Fn2>('zs_budget'),
      _entryId = lib.lookupFunction<_Fn2, _Fn2>('zs_entry_id'),
      _free = lib.lookupFunction<_Free, _FreeD>('zs_free');

  final _Fn2 _merge, _budget, _entryId;
  final _FreeD _free;

  /// Android packages `libzero_sum_ffi_c.so` in the APK. Host tests point
  /// `ZERO_SUM_FFI` at a locally built library.
  static final Core instance = Core._(
    DynamicLibrary.open(
      Platform.environment['ZERO_SUM_FFI'] ?? 'libzero_sum_ffi_c.so',
    ),
  );

  dynamic _call(_Fn2 f, String a, String b) {
    final pa = a.toNativeUtf8(), pb = b.toNativeUtf8();
    final out = f(pa, pb);
    malloc.free(pa);
    malloc.free(pb);
    try {
      final r = jsonDecode(out.toDartString()) as Map<String, dynamic>;
      if (r.containsKey('err')) throw CoreException(r['err'] as String);
      return r['ok'];
    } finally {
      _free(out);
    }
  }

  /// Merge an op into an entity (`null` for a new one). Throws on an invalid op.
  Map<String, dynamic> merge(
    Map<String, dynamic>? entity,
    Map<String, dynamic> op,
  ) =>
      _call(_merge, jsonEncode(entity), jsonEncode(op)) as Map<String, dynamic>;

  Map<String, dynamic> budget(
    List<Map<String, dynamic>> entities,
    String month,
  ) => _call(_budget, jsonEncode(entities), month) as Map<String, dynamic>;

  String budgetEntryId(String categoryId, String month) =>
      _call(_entryId, categoryId, month) as String;
}
