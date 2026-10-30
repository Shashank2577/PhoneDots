import '../skill.dart';
import 'json_extract.dart';

const _imageParam = SkillParam('image', ParamType.attachment, 'The photo or image to use.');

SkillResult? _needImage(Attachment? a) =>
    a == null || a.kind != 'image' ? SkillResult.error('Attach or take a photo first.') : null;

List<Skill> visionSkills() => [
      FnSkill(
        id: 'describe_image',
        name: 'Ask about an image',
        description: 'Answer a question about a photo using Gemma vision (scene, objects, what is happening).',
        kind: SkillKind.model,
        category: SkillCategory.vision,
        params: const [
          _imageParam,
          SkillParam('question', ParamType.string, 'What to find out about the image.', required: false),
        ],
        examples: const ['What is in this photo?'],
        handler: (args, ctx) async {
          final a = ctx.attachment(args['image']);
          final missing = _needImage(a);
          if (missing != null) return missing;
          final answer = await ctx.ask(
            system: 'You describe images accurately and concisely. Say when you are unsure.',
            prompt: args.str('question', 'Describe this image.'),
            imagePaths: [a!.path],
          );
          return SkillResult({'answer': answer});
        },
      ),
      FnSkill(
        id: 'read_text_in_image',
        name: 'Read text in image',
        description: 'Extract all readable text from a photo of a document, sign, menu or screen.',
        kind: SkillKind.model,
        category: SkillCategory.vision,
        params: const [_imageParam],
        examples: const ['Read this document'],
        handler: (args, ctx) async {
          final a = ctx.attachment(args['image']);
          final missing = _needImage(a);
          if (missing != null) return missing;
          ctx.progress('Reading with Gemma vision');
          final text = await ctx.ask(
            system: 'Transcribe all text in the image exactly, preserving line breaks. Output only the text.',
            prompt: 'Transcribe the text.',
            imagePaths: [a!.path],
          );
          return SkillResult({'text': text}, cards: [UiCard('text', title: 'Text in image', data: {'text': text, 'copy': true})]);
        },
      ),
      FnSkill(
        id: 'analyze_photo',
        name: 'Analyze photo',
        description: 'Tag a photo (scene, kind, people, pets), score its quality and find faces (Eye).',
        kind: SkillKind.model,
        category: SkillCategory.vision,
        params: const [_imageParam],
        requiresModels: const ['desertant.eye'],
        examples: const ['Tag this photo'],
        handler: (args, ctx) async {
          final a = ctx.attachment(args['image']);
          final missing = _needImage(a);
          if (missing != null) return missing;
          final r = await ctx.specialist('desertant.eye', 'analyze', {'imagePath': a!.path});
          if (r['error'] != null) return SkillResult.error('${r['error']}');
          final tags = (r['tags'] as List? ?? const []).map((e) => '$e').toList();
          final aesthetic = (r['aesthetic'] as num?)?.toDouble();
          return SkillResult({
            'kind': r['kind'],
            'tags': tags,
            'aesthetic_percentile': aesthetic == null ? null : (aesthetic * 100).round(),
            'faces': r['faces'],
          }, cards: [
            UiCard('tags', title: 'Tags', data: {'tags': tags}),
            UiCard('kv', title: 'Photo', data: {
              'Kind': '${r['kind'] ?? '—'}',
              if (aesthetic != null) 'Aesthetics': 'better than ${(aesthetic * 100).round()}% of photos',
              'Faces': '${r['faces'] ?? 0}',
            }),
          ]);
        },
      ),
      FnSkill(
        id: 'pick_best_photo',
        name: 'Pick the best shot',
        description: 'Compare all attached photos and pick the best one by quality and aesthetics (Eye).',
        kind: SkillKind.model,
        category: SkillCategory.vision,
        requiresModels: const ['desertant.eye'],
        examples: const ['Which of these photos is best?'],
        handler: (args, ctx) async {
          final images = ctx.attachments.where((a) => a.kind == 'image').toList();
          if (images.length < 2) return SkillResult.error('Attach at least two photos.');
          final scored = <(Attachment, double)>[];
          for (final img in images) {
            ctx.progress('Scoring ${img.name}');
            final r = await ctx.specialist('desertant.eye', 'analyze', {'imagePath': img.path});
            scored.add((img, ((r['keeper'] ?? r['aesthetic'] ?? 0) as num).toDouble()));
          }
          scored.sort((a, b) => b.$2.compareTo(a.$2));
          final best = scored.first.$1;
          return SkillResult({
            'best': best.id,
            'ranking': [for (final s in scored) '${s.$1.id}: ${(s.$2 * 100).round()}'],
          }, cards: [
            UiCard('image', title: 'Best shot', data: {'path': best.path}),
            UiCard('bars', title: 'Scores', data: {
              'labels': [for (final s in scored) s.$1.name],
              'values': [for (final s in scored) (s.$2 * 100).roundToDouble()],
            }),
          ]);
        },
      ),
      FnSkill(
        id: 'check_image_safety',
        name: 'Check image safety',
        description: 'Detect nudity or explicit content in an image before sharing (Moderator).',
        kind: SkillKind.model,
        category: SkillCategory.vision,
        params: const [_imageParam],
        requiresModels: const ['desertant.moderator'],
        handler: (args, ctx) async {
          final a = ctx.attachment(args['image']);
          final missing = _needImage(a);
          if (missing != null) return missing;
          final r = await ctx.specialist('desertant.moderator', 'analyze', {'imagePath': a!.path});
          if (r['error'] != null) return SkillResult.error('${r['error']}');
          final nsfw = r['isNSFW'] == true;
          return SkillResult({
            'nsfw': nsfw,
            'score': r['score'],
            'summary': nsfw ? 'This image may contain explicit content.' : 'No explicit content detected.',
          });
        },
      ),
      FnSkill(
        id: 'receipt_to_expense',
        name: 'Receipt to expense',
        description: 'Read a receipt photo into merchant, date, total, currency and line items.',
        kind: SkillKind.model,
        category: SkillCategory.vision,
        params: const [_imageParam],
        examples: const ['Log this receipt'],
        handler: (args, ctx) async {
          final a = ctx.attachment(args['image']);
          final missing = _needImage(a);
          if (missing != null) return missing;
          ctx.progress('Reading receipt');
          final raw = await ctx.ask(
            system: 'Extract the receipt. Reply with JSON only: {"merchant": string, "date": "YYYY-MM-DD", '
                '"total": number, "currency": string, "items": [{"name": string, "price": number}]}',
            prompt: 'Extract this receipt.',
            imagePaths: [a!.path],
          );
          final r = extractJson(raw);
          if (r == null) return SkillResult.error('Could not read the receipt.');
          final items = (r['items'] as List? ?? const []).whereType<Map>().toList();
          await ctx.addKnowledge(
            'Expense: ${r['merchant']} ${r['date']}',
            'Receipt from ${r['merchant']} on ${r['date']}. Total ${r['total']} ${r['currency']}. '
                'Items: ${items.map((i) => '${i['name']} ${i['price']}').join(', ')}',
            source: 'expenses',
          );
          return SkillResult({...r, 'saved_to': 'expenses'}, cards: [
            UiCard('kv', title: '${r['merchant'] ?? 'Receipt'}', data: {
              'Date': '${r['date'] ?? '—'}',
              'Total': '${r['total'] ?? '—'} ${r['currency'] ?? ''}',
            }),
            if (items.isNotEmpty)
              UiCard('table', title: 'Items', data: {
                'columns': ['Item', 'Price'],
                'rows': [
                  for (final i in items) ['${i['name']}', '${i['price']}'],
                ],
              }),
          ]);
        },
      ),
    ];
