/// The hash that [routeLineHash] starts from.
const routeHashSeed = 0xcbf29ce484222325;

/// Returns the route hash after [line], from the hash [hash] before it. The
/// hash is 64-bit FNV-1a over the UTF-16 code units of the line and then a
/// line feed.
int routeLineHash(int hash, String line) {
  var h = hash;
  for (var i = 0; i < line.length; i++) {
    h = (h ^ line.codeUnitAt(i)) * 0x100000001b3;
  }
  return (h ^ 10) * 0x100000001b3;
}

/// Returns [hash] as 16 hex digits. The two 32-bit halves are printed apart
/// since a negative int has no unsigned form on the VM.
String routeHashText(int hash) =>
    '${((hash >> 32) & 0xffffffff).toRadixString(16).padLeft(8, '0')}'
    '${(hash & 0xffffffff).toRadixString(16).padLeft(8, '0')}';

/// Reads a hash from its 16 hex digits.
int parseRouteHash(String text) =>
    (int.parse(text.substring(0, 8), radix: 16) << 32) |
    int.parse(text.substring(8), radix: 16);
