// Ported from Lua 5.2.3 loslib.c (MIT, see LICENSE-lua). The time comes
// from the host, and the local time is UTC. Nothing runs outside the VM.
// `execute`, `exit`, `remove` and `rename` are refused and logged.

import '../number.dart';
import '../state.dart';
import '../table.dart';

const _ansiOptions = 'aAbBcdHIjmMpSUwWxXyYz%';
const _posixOptions = 'aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%';
const _days = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December', //
];

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
int _daysFromCivil(int y, int m, int d) {
  y -= m <= 2 ? 1 : 0;
  final era = (y >= 0 ? y : y - 399) ~/ 400;
  final yoe = y - era * 400;
  final doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) ~/ 5 + d - 1;
  final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;
  return era * 146097 + doe - 719468;
}

class _Tm {
  /// [t] broken down in UTC. [floor] counts the days before 1970 down, and
  /// else towards zero.
  _Tm.fromEpoch(int t, {bool floor = false}) {
    var days = t ~/ 86400;
    var rem = t % 86400;
    if (floor && t < 0 && rem != 0) days--;
    if (rem < 0) {
      rem += 86400;
      days--;
    }
    hour = rem ~/ 3600;
    min = (rem % 3600) ~/ 60;
    sec = rem % 60;
    wday = (4 + days) % 7;
    if (wday < 0) wday += 7;
    final z = days + 719468;
    final era = (z >= 0 ? z : z - 146096) ~/ 146097;
    final doe = z - era * 146097;
    final yoe = (doe - doe ~/ 1460 + doe ~/ 36524 - doe ~/ 146096) ~/ 365;
    final doy = doe - (365 * yoe + yoe ~/ 4 - yoe ~/ 100);
    final mp = (5 * doy + 2) ~/ 153;
    mday = doy - (153 * mp + 2) ~/ 5 + 1;
    mon = mp < 10 ? mp + 3 : mp - 9;
    year = yoe + era * 400 + (mon <= 2 ? 1 : 0);
    yday = days - _daysFromCivil(year, 1, 1);
  }
  late int sec, min, hour, mday, mon, year, wday, yday;
}

String _two(int n) => n.toString().padLeft(2, '0');

String _strftime(String spec, _Tm t) {
  final c = spec[spec.length - 1];
  final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  int weekNo(int firstDay) {
    final wd = (t.wday - firstDay + 7) % 7;
    return (t.yday + 7 - wd) ~/ 7;
  }

  switch (c) {
    case 'a':
      return _days[t.wday].substring(0, 3);
    case 'A':
      return _days[t.wday];
    case 'b' || 'h':
      return _months[t.mon - 1].substring(0, 3);
    case 'B':
      return _months[t.mon - 1];
    case 'c':
      return '${_strftime('%a', t)} ${_strftime('%b', t)} ${t.mday.toString().padLeft(2)} '
          '${_two(t.hour)}:${_two(t.min)}:${_two(t.sec)} ${t.year}';
    case 'C':
      return _two(t.year ~/ 100);
    case 'd':
      return _two(t.mday);
    case 'D' || 'x':
      return '${_two(t.mon)}/${_two(t.mday)}/${_two(t.year % 100)}';
    case 'e':
      return t.mday.toString().padLeft(2);
    case 'F':
      return '${t.year}-${_two(t.mon)}-${_two(t.mday)}';
    case 'H':
      return _two(t.hour);
    case 'I':
      return _two(hour12);
    case 'j':
      return (t.yday + 1).toString().padLeft(3, '0');
    case 'm':
      return _two(t.mon);
    case 'M':
      return _two(t.min);
    case 'n':
      return '\n';
    case 'p':
      return t.hour < 12 ? 'AM' : 'PM';
    case 'r':
      return '${_two(hour12)}:${_two(t.min)}:${_two(t.sec)} ${t.hour < 12 ? 'AM' : 'PM'}';
    case 'R':
      return '${_two(t.hour)}:${_two(t.min)}';
    case 'S':
      return _two(t.sec);
    case 't':
      return '\t';
    case 'T' || 'X':
      return '${_two(t.hour)}:${_two(t.min)}:${_two(t.sec)}';
    case 'u':
      return '${t.wday == 0 ? 7 : t.wday}';
    case 'U':
      return _two(weekNo(0));
    case 'w':
      return '${t.wday}';
    case 'W':
      return _two(weekNo(1));
    case 'y':
      return _two(t.year % 100);
    case 'Y':
      return '${t.year}';
    case 'z':
      return '+0000';
    case 'Z':
      return 'UTC';
    case '%':
      return '%';
    default:
      return '';
  }
}

int _date(LuaThread L) {
  var s = L.optString(1, '%c')!;
  final tn = L.arg(2) == null ? L.vm.host.time().toDouble() : L.checkNumber(2);
  if (!tn.isFinite) {
    // The time_t of inf or NaN is undefined in C. gmtime then fails and the
    // result is nil.
    L.push(null);
    return 1;
  }
  final rt = L.vm.runtime;
  final t = L.vm.integer64 ? luaToInteger(tn, true) : tn.truncate();
  if (s.startsWith('!')) s = s.substring(1);
  if (!rt.gmtimeAccepts(t)) {
    L.push(null);
    return 1;
  }
  final tm = _Tm.fromEpoch(t, floor: rt.gmtimeFloors);
  if (s == '*t') {
    final r = LuaTable(0, 9)
      ..set('sec', tm.sec.toDouble())
      ..set('min', tm.min.toDouble())
      ..set('hour', tm.hour.toDouble())
      ..set('day', tm.mday.toDouble())
      ..set('month', tm.mon.toDouble())
      ..set('year', tm.year.toDouble())
      ..set('wday', (tm.wday + 1).toDouble())
      ..set('yday', (tm.yday + 1).toDouble())
      ..set('isdst', false);
    L.push(r);
    return 1;
  }
  final options = rt.posixDate ? _posixOptions : _ansiOptions;
  final b = StringBuffer();
  var i = 0;
  while (i < s.length) {
    if (s[i] != '%') {
      b.write(s[i++]);
      continue;
    }
    i++;
    final conv = s.substring(i);
    var ok = false;
    var spec = '';
    if (i < s.length && options.contains(s[i])) {
      spec = '%${s[i]}';
      i++;
      ok = true;
    } else if (rt.posixDate && i + 1 < s.length) {
      if ((s[i] == 'E' && 'cCxXyY'.contains(s[i + 1])) ||
          (s[i] == 'O' && 'deHImMSuUVwWy'.contains(s[i + 1]))) {
        spec = '%${s[i + 1]}';
        i += 2;
        ok = true;
      }
    }
    if (!ok) L.argError(1, "invalid conversion specifier '%$conv'");
    b.write(_strftime(spec, tm));
  }
  L.push(b.toString());
  return 1;
}

int _getField(LuaThread L, String key, int d) {
  L.getField(-1, key);
  final v = L.arg(-1);
  L.pop();
  final n = v is double
      ? v
      : (v is String ? parseLuaNumber(v, L.vm.numberMode) : null);
  if (n == null) {
    if (d < 0) L.luaError("field '$key' missing in date table");
    return d;
  }
  return luaToCInt(n, L.vm.integer64);
}

int _time(LuaThread L) {
  int t;
  if (L.arg(1) == null) {
    t = L.vm.host.time();
  } else {
    L.checkType(1, 'table');
    L.setTop(1);
    final sec = _getField(L, 'sec', 0);
    final min = _getField(L, 'min', 0);
    final hour = _getField(L, 'hour', 12);
    final day = _getField(L, 'day', -1);
    final month = _getField(L, 'month', -1) - 1;
    final year = _getField(L, 'year', -1);
    final y = year + (month >= 0 ? month ~/ 12 : -((11 - month) ~/ 12));
    final m = month % 12;
    t =
        (_daysFromCivil(y, m + 1, 1) + day - 1) * 86400 +
        hour * 3600 +
        min * 60 +
        sec;
  }
  L.push(L.number(t.toDouble()));
  return 1;
}

int _refuse(LuaThread L, String what) {
  L.vm.host.log('os', what);
  L.push(null);
  L.push('$what: not supported');
  L.push(1.0);
  return 3;
}

/// `luaopen_os` into [t] in the order of `syslib`.
LuaTable openOs(LuaTable t) {
  for (final (name, f) in <(String, LuaCFunction)>[
    (
      'clock',
      (L) {
        L.push(L.number(L.vm.host.clock()));
        return 1;
      },
    ),
    ('date', _date),
    (
      'difftime',
      (L) {
        final a = L.checkNumber(1);
        final b = L.optNumber(2, 0) ?? 0;
        L.push(
          a.isFinite && b.isFinite
              ? L.number((a.truncate() - b.truncate()).toDouble())
              : L.number(a - b),
        );
        return 1;
      },
    ),
    (
      'execute',
      (L) {
        if (L.arg(1) == null) {
          L.push(false);
          return 1;
        }
        return _refuse(L, 'execute ${L.checkString(1)}');
      },
    ),
    (
      'exit',
      (L) {
        L.vm.host.log('os', 'exit');
        return 0;
      },
    ),
    (
      'getenv',
      (L) {
        L.checkString(1);
        L.push(null);
        return 1;
      },
    ),
    ('remove', (L) => _refuse(L, L.checkString(1))),
    ('rename', (L) => _refuse(L, L.checkString(1))),
    (
      'setlocale',
      (L) {
        final l = L.optString(1, null);
        L.checkOption(2, 'all', [
          'all',
          'collate',
          'ctype',
          'monetary',
          'numeric',
          'time',
        ]);
        L.push(l == null || l.isEmpty || l == 'C' ? 'C' : null);
        return 1;
      },
    ),
    ('time', _time),
    (
      'tmpname',
      (L) {
        L.push('/tmp/lua_mcsm');
        return 1;
      },
    ),
  ]) {
    t.set(name, LuaNative(f, name));
  }
  return t;
}
