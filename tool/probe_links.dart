// Live check of link processing against real URLs.
//   dart run tool/probe_links.dart [url ...]
// Results depend on the network: sites rate-limit data-centre IPs much more
// than phones on home or mobile connections.
import 'dart:io';

import 'package:phonedots/saved/deep_reader.dart';
import 'package:phonedots/saved/link_preview.dart';

const _defaults = [
  'https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=AbCdEf123',
  'https://youtu.be/dQw4w9WgXcQ?si=xyz',
  'https://www.youtube.com/shorts/aqz-KE-bpKQ',
  'https://www.tiktok.com/@scout2015/video/6718335390845095173?is_from_webapp=1&sender_device=pc',
  'https://www.instagram.com/p/DYhqaremniv/?igsh=MTc4MmM1YmI2Ng==',
  'https://www.instagram.com/nasa/',
  'https://www.threads.net/@oziil_hg/post/DIswUS-MfNp?xmt=AQGz',
  'https://www.threads.com/@zuck',
  'https://www.linkedin.com/feed/update/urn:li:share:7195964475009626112/',
  'https://www.linkedin.com/company/google/',
  'https://github.com/Shashank2577/PhoneDots',
  'https://medium.com/@karpathy/software-2-0-a64152b37c35',
  'https://x.com/googledevs',
];

Future<void> main(List<String> args) async {
  final urls = args.isEmpty ? _defaults : args;
  final p = LinkPreviewer();
  final deep = DeepReader();
  var rich = 0;
  for (final u in urls) {
    final r = await p.preview(u);
    await deep.read(r);
    if (r.rich) rich++;
    stdout.writeln(
      '${r.rich ? 'OK  ' : 'URL '} ${r.platform.padRight(9)} ${r.kind.padRight(7)} via ${r.via.padRight(6)} '
      'http ${r.status ?? '-'}  "${r.title}"${r.author != null ? '  by ${r.author}' : ''}${r.imageUrl != null ? '  [image]' : ''}',
    );
    if (r.description != null && r.description!.isNotEmpty) {
      final d = r.description!.replaceAll('\n', ' ');
      stdout.writeln('       ${d.length > 110 ? '${d.substring(0, 110)}…' : d}');
    }
    if (r.body != null) {
      final b = r.body!.replaceAll('\n', ' ');
      stdout.writeln(
        '       FULL TEXT (${r.bodyFrom}, ${r.body!.length} chars): ${b.length > 140 ? '${b.substring(0, 140)}…' : b}',
      );
    }
    stdout.writeln('       ${r.url}');
  }
  stdout.writeln('\n$rich/${urls.length} with real metadata; the rest saved with a title from the URL.');
  p.close();
  deep.close();
}
