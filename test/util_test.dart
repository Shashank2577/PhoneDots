import 'package:flutter_test/flutter_test.dart';
import 'package:phonedots/agent/tool_call_parser.dart';
import 'package:phonedots/core/util/calculator.dart';
import 'package:phonedots/core/util/units.dart';
import 'package:phonedots/skills/builtin/audio_skills.dart';
import 'package:phonedots/skills/builtin/json_extract.dart';
import 'package:phonedots/skills/community/community_skill.dart';
import 'package:phonedots/skills/recipes/recipe.dart';

void main() {
  group('Calculator', () {
    test('precedence, powers, functions', () {
      expect(Calculator.evaluate('2 + 3 * 4'), 14);
      expect(Calculator.evaluate('(2 + 3) * 4'), 20);
      expect(Calculator.evaluate('2 ^ 3 ^ 2'), 512);
      expect(Calculator.evaluate('-3 + 5'), 2);
      expect(Calculator.evaluate('sqrt(16) + 1,000'), 1004);
      expect(Calculator.evaluate('18/100*2450'), 441);
      expect(Calculator.evaluate('50%'), 0.5);
      expect(Calculator.evaluate('10 % 4'), 2);
    });

    test('rejects junk', () {
      expect(() => Calculator.evaluate('2 +'), throwsFormatException);
      expect(() => Calculator.evaluate('drop table'), throwsFormatException);
    });

    test('formats', () {
      expect(Calculator.format(441), '441');
      expect(Calculator.format(0.1 + 0.2), '0.3');
    });
  });

  group('Units', () {
    test('length, mass, temperature', () {
      expect(Units.convert(5, 'miles', 'km'), closeTo(8.04672, 1e-6));
      expect(Units.convert(1, 'kg', 'lb'), closeTo(2.20462, 1e-4));
      expect(Units.convert(100, '°C', 'F'), closeTo(212, 1e-9));
      expect(() => Units.convert(1, 'kg', 'km'), throwsArgumentError);
    });
  });

  group('ToolCallParser', () {
    const tools = {'set_timer', 'calculate'};

    test('fenced JSON from our prompt format', () {
      final r = ToolCallParser.parse('Sure.\n```tool_call\n{"name": "set_timer", "arguments": {"seconds": 300}}\n```', tools);
      expect(r.calls.single.name, 'set_timer');
      expect(r.calls.single.arguments['seconds'], 300);
      expect(r.text, 'Sure.');
    });

    test('FunctionGemma format', () {
      final r = ToolCallParser.parse(
          '<start_function_call>call:set_timer{seconds:60,label:<escape>Tea, strong<escape>}<end_function_call>', tools);
      expect(r.calls.single.arguments, {'seconds': 60, 'label': 'Tea, strong'});
    });

    test('python style', () {
      final r = ToolCallParser.parse('[calculate(expression="2*3")]', tools);
      expect(r.calls.single.arguments['expression'], '2*3');
    });

    test('ignores unknown tools and plain text', () {
      expect(ToolCallParser.parse('```json\n{"name": "rm_rf", "arguments": {}}\n```', tools).calls, isEmpty);
      expect(ToolCallParser.parse('Just an answer.', tools).calls, isEmpty);
    });
  });

  test('extractJson handles fences and prose', () {
    expect(extractJson('Here:\n```json\n{"a": 1, "b": "}"}\n```'), {'a': 1, 'b': '}'});
    expect(extractJson('The result is {"title": "Hi"} done'), {'title': 'Hi'});
    expect(extractJson('nothing'), isNull);
  });

  test('recipe templates', () {
    final results = [
      {'text': 'hello world'},
      {'result': 'summary', 'items': ['a', 'b']},
    ];
    expect(fillTemplate('{{input}}!', 'x', results), 'x!');
    expect(fillTemplate('{{prev.result}}', '', results), 'summary');
    expect(fillTemplate('{{steps.1.text}}', '', results), 'hello world');
    expect(fillTemplate('{{prev.items}}', '', results), 'a\nb');
    expect(fillTemplate('{{prev.missing}}', '', results), '');
  });

  group('Community skills', () {
    test('samples are valid', () {
      for (final m in sampleCommunitySkills) {
        expect(CommunitySkill.parse(m).id, startsWith('c_'));
      }
    });

    test('rejects bad manifests', () {
      expect(() => CommunitySkill.parse({'schema': 'x'}), throwsFormatException);
      expect(
        () => CommunitySkill.parse({'schema': CommunitySkill.schema, 'id': 'Bad Id', 'name': 'n', 'description': 'd', 'prompt': {'user': 'u'}}),
        throwsFormatException,
      );
      expect(
        () => CommunitySkill.parse({'schema': CommunitySkill.schema, 'id': 'ok_id', 'name': 'n', 'description': 'd'}),
        throwsFormatException,
      );
    });
  });

  test('speaker merge and SRT', () {
    final words = [
      {'text': 'Hi', 'start': 0.0, 'end': 0.4},
      {'text': 'there.', 'start': 0.5, 'end': 0.9},
      {'text': 'Hello!', 'start': 1.5, 'end': 1.9},
    ];
    final turns = [
      {'speaker': 0, 'start': 0.0, 'end': 1.2},
      {'speaker': 1, 'start': 1.2, 'end': 2.0},
    ];
    final segments = mergeSpeakers(words, turns);
    expect(segments.map((s) => s['text']), ['Hi there.', 'Hello!']);
    expect(segments.map((s) => s['speaker']), [0, 1]);
    final srt = buildSrt(words, maxWords: 2);
    expect(srt, contains('00:00:00,000 --> 00:00:00,900'));
    expect(srt, contains('2\n00:00:01,500 --> 00:00:01,900\nHello!'));
  });
}
