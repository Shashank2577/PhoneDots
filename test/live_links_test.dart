// End-to-end link handling through the real chat pipeline with live network.
// Skipped by default; run with:  LIVE=1 flutter test test/live_links_test.dart
// (The demo engine stands in for Gemma, so this checks everything up to the
// model: link detection, reading, the details handed to the model, the card.)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:phonedots/agent/agent.dart';
import 'package:phonedots/agent/conversation.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';

const _links = [
  // The three from the bug report, exactly as pasted.
  'https://www.instagram.com/p/DduI7Bps24j/?cplk=MW1nYmd6ZGVncmUwbQ==',
  'https://github.com/Shashank2577/PhoneDots',
  'https://youtu.be/dCS4er4Xcjo',
  'https://www.youtube.com/shorts/aqz-KE-bpKQ',
  'https://www.tiktok.com/@scout2015/video/6718335390845095173',
  'https://www.threads.com/@zuck',
  'https://www.threads.net/@oziil_hg/post/DIswUS-MfNp',
  'https://www.linkedin.com/feed/update/urn:li:share:7195964475009626112/',
  'https://medium.com/@karpathy/software-2-0-a64152b37c35',
  'what is this? youtube.com/watch?v=dQw4w9WgXcQ',
];

void main() {
  final live = Platform.environment['LIVE'] == '1';
  for (final message in _links) {
    test('chat: $message', () async {
      final s = await AppServices.create(store: MemoryJsonStore(), platform: 'demo');
      final chat = ChatController(s);
      await chat.send(message);
      final user = chat.messages.first;
      final reply = chat.messages.last;
      final step = reply.steps.firstWhere((x) => x.skillId == 'read_link');
      final r = step.result;
      print(
        '${r['rich'] == true ? 'RICH' : 'URL '} ${r['platform']}/${r['kind']}: ${r['title']}'
        '${r['author'] != null ? ' — ${r['author']}' : ''}',
      );
      expect(step.status, StepStatus.done);
      expect(user.linkContext, contains('[Link details read by PhoneDots]'));
      expect(reply.text, isNot(contains('cannot access')));
      expect(reply.text, contains('${r['title']}'));
    }, skip: live ? false : 'live network test; run with LIVE=1');
  }
}
