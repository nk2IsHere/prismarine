import 'package:prismarine_cargo/prismarine_cargo.dart';
import 'package:test/test.dart';

void main() {
  final shared = Uri.directory(
    r'C:\s\apps\sample\.dart_tool\hooks_runner\shared\prismarine_pad\build',
    windows: true,
  );

  test('the target directory is cargo/ in the shared directory on POSIX', () {
    final posix = Uri.directory('/home/a/app/.dart_tool/shared/pad/build');
    expect(
      cargoTargetDir(posix, windows: false, environment: const {}),
      posix.resolve('cargo/'),
    );
  });

  test('the target directory on Windows is short and in LOCALAPPDATA', () {
    final dir = cargoTargetDir(
      shared,
      windows: true,
      environment: const {'LOCALAPPDATA': r'C:\Users\a\AppData\Local'},
    );
    final path = dir.toFilePath(windows: true);
    expect(
      path,
      matches(
        r'^C:\\Users\\a\\AppData\\Local\\prismarine\\cargo\\[0-9a-f]{8}\\$',
      ),
    );
    expect(
      cargoTargetDir(
        shared,
        windows: true,
        environment: const {'LOCALAPPDATA': r'C:\Users\a\AppData\Local'},
      ),
      dir,
    );
    final other = cargoTargetDir(
      shared.resolve('../../other/build/'),
      windows: true,
      environment: const {'LOCALAPPDATA': r'C:\Users\a\AppData\Local'},
    );
    expect(other, isNot(dir));
  });

  test('the target directory falls back to USERPROFILE, then to cargo/', () {
    expect(
      cargoTargetDir(
        shared,
        windows: true,
        environment: const {'USERPROFILE': r'C:\Users\a'},
      ).toFilePath(windows: true),
      startsWith(r'C:\Users\a\AppData\Local\prismarine\cargo\'),
    );
    expect(
      cargoTargetDir(shared, windows: true, environment: const {}),
      shared.resolve('cargo/'),
    );
  });
}
