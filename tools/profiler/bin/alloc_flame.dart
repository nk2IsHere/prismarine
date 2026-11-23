// alloc_flame: alloc_sites.dart's stacks (its JSON's byStack) as a flame
// graph: an HTML page (click a frame to zoom, hover for its share) or a
// text tree. The many small allocations a site list scatters add up under
// the code that makes them.
//
//   dart run bin/alloc_flame.dart <sites.json> [--isolate=<name>]
//     [--html=<out.html>] [--tree] [--min=<MB a frame>] [--depth=<n>]
//     [--sdk]
//
// --sdk keeps the SDK's frames (zone, futures, collections); without it a
// stack keeps only the project's frames, the allocated class its leaf.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final opts = <String, String>{};
  final files = <String>[];
  for (final a in args) {
    final m = RegExp(r'^--([a-z]+)(?:=(.*))?$').firstMatch(a);
    if (m == null) {
      files.add(a);
    } else {
      opts[m[1]!] = m[2] ?? '';
    }
  }
  if (files.length != 1) {
    stderr.writeln(
      'usage: alloc_flame <sites.json> [--isolate=…] '
      '[--html=out.html] [--tree] [--min=MB] [--depth=n] [--sdk]',
    );
    exit(64);
  }
  final report =
      jsonDecode(File(files.single).readAsStringSync()) as Map<String, Object?>;
  final perFrame = (report['perFrame'] as num?)?.toDouble() ?? 1;
  final keepSdk = opts.containsKey('sdk');
  final root = _Node('all');
  for (final MapEntry(key: isolate, :value) in report.entries) {
    if (value is! Map || value['byStack'] is! Map) continue;
    if (opts['isolate'] case final want? when want != isolate) continue;
    final node = root.child(isolate);
    for (final MapEntry(key: stack, value: bytes)
        in (value['byStack'] as Map).cast<String, num>().entries) {
      node.add(_frames(stack, keepSdk), bytes / perFrame / 1e6);
    }
  }
  // The isolates are added under the root directly: its total is theirs.
  for (final c in root.children.values) {
    root.total += c.total;
  }
  final top = root.children.length == 1 ? root.children.values.single : root;
  if (opts.containsKey('tree') || !opts.containsKey('html')) {
    final min = double.tryParse(opts['min'] ?? '') ?? 0.01;
    final depth = int.tryParse(opts['depth'] ?? '') ?? 12;
    _printTree(top, top.total, min, depth, '');
  }
  if (opts['html'] case final out?) {
    File(
      out,
    ).writeAsStringSync(_html(top, perFrame == 1 ? 'MB' : 'MB a frame'));
    stdout.writeln('wrote $out');
  }
}

/// [stack] (`Class @ leaf < caller < … < root`) root first, the class last.
List<String> _frames(String stack, bool keepSdk) {
  final at = stack.indexOf(' @ ');
  final cls = stack.substring(0, at);
  final frames = stack.substring(at + 3).split(' < ').reversed;
  return [
    for (final f in frames)
      if (keepSdk || !_sdk(f)) f,
    'new $cls',
  ];
}

/// Whether frame [f] (`name (file.dart)`) is the SDK's.
bool _sdk(String f) {
  final open = f.lastIndexOf('(');
  final file = open < 0 ? f : f.substring(open + 1, f.length - 1);
  return file.endsWith('_patch.dart') || _sdkFiles.contains(file);
}

const _sdkFiles = {
  'array.dart',
  'async_patch.dart',
  'compact_hash.dart',
  'double.dart',
  'future_impl.dart',
  'growable_array.dart',
  'integers.dart',
  'iterable.dart',
  'list.dart',
  'map.dart',
  'maps.dart',
  'set.dart',
  'schedule_microtask.dart',
  'stream_controller.dart',
  'stream_impl.dart',
  'timer.dart',
  'zone.dart',
  'collection_patch.dart',
  'hash_set.dart',
  'linked_hash_map.dart',
  'string_buffer.dart',
  'object.dart',
  'num.dart',
  'broadcast_stream_controller.dart',
  'stream.dart',
  'list_patch.dart',
  'splay_tree.dart',
  'queue.dart',
  'record_patch.dart',
  'iterable_patch.dart',
};

final class _Node {
  _Node(this.name);
  final String name;
  double self = 0, total = 0;
  final children = <String, _Node>{};

  _Node child(String n) => children[n] ??= _Node(n);

  void add(List<String> frames, double mb) {
    var n = this;
    n.total += mb;
    for (final f in frames) {
      n = n.child(f)..total += mb;
    }
    n.self += mb;
  }

  Map<String, Object?> json() => {
    'n': name,
    'v': total,
    if (children.isNotEmpty)
      'c': [
        for (final c
            in children.values.toList()
              ..sort((a, b) => b.total.compareTo(a.total)))
          c.json(),
      ],
  };
}

void _printTree(_Node n, double all, double min, int depth, String pad) {
  // A chain of single significant children prints as one line.
  final names = [_short(n.name)];
  var at = n;
  while (true) {
    final kids = at.children.values.where((c) => c.total >= min).toList();
    if (kids.length != 1 || kids.single.total < at.total * 0.9) break;
    at = kids.single;
    names.add(_short(at.name));
  }
  stdout.writeln(
    '$pad${at.total.toStringAsFixed(3)} '
    '${(100 * at.total / all).toStringAsFixed(1).padLeft(5)}%  '
    '${names.join(' ▸ ')}',
  );
  if (depth == 0) return;
  final kids = at.children.values.where((c) => c.total >= min).toList()
    ..sort((a, b) => b.total.compareTo(a.total));
  for (final c in kids) {
    _printTree(c, all, min, depth - 1, '$pad  ');
  }
}

/// [name] without its file.
String _short(String name) {
  final open = name.lastIndexOf(' (');
  return open < 0 ? name : name.substring(0, open);
}

String _html(_Node root, String unit) =>
    '''<!doctype html>
<html><head><meta charset="utf-8"><title>Allocation flame graph</title>
<style>
body{font:12px -apple-system,Helvetica,sans-serif;margin:8px;background:#fff;color:#222}
#crumbs span{cursor:pointer;color:#06c}#crumbs span:hover{text-decoration:underline}
#g{position:relative;margin-top:8px}
.f{position:absolute;height:17px;overflow:hidden;white-space:nowrap;box-sizing:border-box;
border:1px solid #fff;padding:1px 3px;cursor:pointer;font-size:11px}
#tip{position:fixed;pointer-events:none;background:#222;color:#fff;padding:4px 6px;
border-radius:3px;font-size:11px;display:none;max-width:60vw}
</style></head><body>
<div id="crumbs"></div><div id="g"></div><div id="tip"></div>
<script>
const data=${jsonEncode(root.json())};const unit=${jsonEncode(unit)};
const g=document.getElementById('g'),tip=document.getElementById('tip'),crumbs=document.getElementById('crumbs');
function colour(n){if(n.startsWith('new '))return '#c9c9c9';
 const m=n.match(/\\(([^)]*)\\)\$/);const f=m?m[1]:n;let h=0;for(const ch of f)h=(h*31+ch.charCodeAt(0))|0;
 return 'hsl('+(20+Math.abs(h)%40)+','+(55+Math.abs(h>>8)%30)+'%,'+(62+Math.abs(h>>16)%14)+'%)';}
let path=[data];
function draw(){const top=path[path.length-1];g.innerHTML='';const W=g.clientWidth;let depth=0;
 crumbs.innerHTML=path.map((p,i)=>'<span data-i="'+i+'">'+p.n.replace(/</g,'&lt;')+'</span>').join(' › ');
 function lay(n,x,w,d){if(w<1)return;depth=Math.max(depth,d);const e=document.createElement('div');
  e.className='f';e.style.left=x+'px';e.style.width=w+'px';e.style.top=(d*18)+'px';e.style.background=colour(n.n);
  e.textContent=w>30?n.n:'';e.onmousemove=ev=>{tip.style.display='block';tip.style.left=(ev.clientX+12)+'px';
  tip.style.top=(ev.clientY+12)+'px';tip.textContent=n.n+' — '+n.v.toFixed(4)+' '+unit+' ('+(100*n.v/top.v).toFixed(1)+'%)';};
  e.onmouseleave=()=>tip.style.display='none';e.onclick=()=>{path.push(n);draw();};g.appendChild(e);
  let cx=x;for(const c of n.c||[]){const cw=w*c.v/n.v;lay(c,cx,cw,d+1);cx+=cw;}}
 lay(top,0,W,0);g.style.height=((depth+1)*18)+'px';}
crumbs.onclick=e=>{const i=e.target.dataset.i;if(i!==undefined){path=path.slice(0,+i+1);draw();}};
window.onresize=draw;draw();
</script></body></html>
''';
