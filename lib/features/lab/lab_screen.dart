import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/model_catalog.dart';
import '../../core/runtime/engine_types.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/hand.dart';

class LabScreen extends StatelessWidget {
  const LabScreen({super.key});

  @override
  Widget build(BuildContext context) => const _Lab();
}

class _Lab extends StatefulWidget {
  const _Lab();

  @override
  State<_Lab> createState() => _LabState();
}

class _LabState extends State<_Lab> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => HandPage(
    body: Column(
      children: [
        Column0(
          child: PageIntro(
            'lab',
            _tab == 0
                ? 'Talk to the model directly, with your own instructions and settings.'
                : 'Measure how fast the brain runs on this phone.',
            doodle: Doodle.flask,
          ),
        ),
        Column0(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoicePill('prompt lab', selected: _tab == 0, onTap: () => setState(() => _tab = 0)),
              ChoicePill('speed test', selected: _tab == 1, onTap: () => setState(() => _tab = 1)),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(index: _tab, children: const [_PromptLab(), _Benchmark()]),
        ),
      ],
    ),
  );
}

const _templates = {
  'Free': '',
  'Summarize': 'Summarize in 3 bullet points.',
  'Rewrite': 'Rewrite this to be clear and friendly.',
  'Code': 'You are an expert programmer. Answer with code and a one-line explanation.',
  'Translate': 'Translate into French.',
};

class _PromptLab extends StatefulWidget {
  const _PromptLab();

  @override
  State<_PromptLab> createState() => _PromptLabState();
}

class _PromptLabState extends State<_PromptLab> {
  final _system = TextEditingController();
  final _prompt = TextEditingController();
  String _template = 'Free';
  double _temperature = 0.7;
  int _topK = 40;
  String _output = '';
  GenerationStats? _stats;
  bool _running = false;
  String? _error;

  @override
  void dispose() {
    _system.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final s = AppScope.services(context);
    if (_prompt.text.trim().isEmpty) return;
    setState(() {
      _running = true;
      _output = '';
      _stats = null;
      _error = null;
    });
    if (!s.isDemo && !await s.models.ensurePlanner()) {
      setState(() {
        _running = false;
        _error = 'Download a Gemma model in Models first.';
      });
      return;
    }
    final session = 'lab-${DateTime.now().microsecondsSinceEpoch}';
    await for (final e in s.llm.generate(
      GenerationRequest(
        modelId: s.settings.plannerId,
        sessionId: session,
        systemPrompt: _system.text,
        history: [EngineTurn(role: TurnRole.user, text: _prompt.text)],
        sampler: SamplerSettings(temperature: _temperature, topK: _topK, maxTokens: 1024),
      ),
    )) {
      if (!mounted) return;
      setState(() {
        switch (e) {
          case TokenEvent(:final text):
            _output += text;
          case DoneEvent(:final stats):
            _stats = stats;
          case ErrorEvent(:final message):
            _error = message;
          default:
        }
      });
    }
    await s.llm.resetSession(session);
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return ListView(
      padding: const EdgeInsets.fromLTRB(gutter, 16, gutter, 40),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in _templates.keys)
              HandTag(
                t.toLowerCase(),
                marked: _template == t,
                onTap: () => setState(() {
                  _template = t;
                  _system.text = _templates[t]!;
                }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _system,
          maxLines: null,
          decoration: const InputDecoration(labelText: 'System instruction'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _prompt,
          minLines: 3,
          maxLines: 10,
          decoration: const InputDecoration(labelText: 'Prompt'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 110,
              child: Text('Temperature ${_temperature.toStringAsFixed(1)}', style: context.text.bodySmall),
            ),
            Expanded(
              child: Slider(
                value: _temperature,
                max: 1.5,
                divisions: 15,
                onChanged: (v) => setState(() => _temperature = v),
              ),
            ),
          ],
        ),
        Row(
          children: [
            SizedBox(width: 110, child: Text('Top-K $_topK', style: context.text.bodySmall)),
            Expanded(
              child: Slider(
                value: _topK.toDouble(),
                min: 1,
                max: 100,
                divisions: 99,
                onChanged: (v) => setState(() => _topK = v.round()),
              ),
            ),
          ],
        ),
        InkButton('run', busy: _running, trailing: Doodle.play, expand: true, onTap: _run),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: TextStyle(color: p.danger)),
          ),
        if (_output.isNotEmpty || _stats != null) ...[
          const SectionHead('what it said'),
          Panel(
            color: context.pal.smudge,
            child: SelectableText(_output, style: context.text.bodyMedium),
          ),
          if (_stats != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'First token ${formatMs(_stats!.timeToFirstTokenMs)} · ${_stats!.effectiveTokensPerSec.toStringAsFixed(1)} tok/s · ${_stats!.outputTokens} tokens',
                style: context.text.bodySmall,
              ),
            ),
        ],
      ],
    );
  }
}

class _BenchResult {
  _BenchResult(this.model, this.ttft, this.tps, this.tokens, this.time);
  final String model;
  final int ttft;
  final double tps;
  final int tokens;
  final DateTime time;
}

class _Benchmark extends StatefulWidget {
  const _Benchmark();

  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark> {
  static const _prompts = [
    'Explain how a refrigerator works in one paragraph.',
    'List five ideas for a weekend in the mountains.',
    'Write a haiku about batteries.',
  ];
  final List<_BenchResult> _results = [];
  bool _running = false;
  int _done = 0;
  String? _error;

  Future<void> _run() async {
    final s = AppScope.services(context);
    setState(() {
      _running = true;
      _done = 0;
      _error = null;
    });
    if (!s.isDemo && !await s.models.ensurePlanner()) {
      setState(() {
        _running = false;
        _error = 'Download a Gemma model in Models first.';
      });
      return;
    }
    final stats = <GenerationStats>[];
    for (final prompt in _prompts) {
      final session = 'bench-${DateTime.now().microsecondsSinceEpoch}';
      await for (final e in s.llm.generate(
        GenerationRequest(
          modelId: s.settings.plannerId,
          sessionId: session,
          history: [EngineTurn(role: TurnRole.user, text: prompt)],
          sampler: const SamplerSettings(temperature: 0, topK: 1, maxTokens: 256),
        ),
      )) {
        if (e is DoneEvent) stats.add(e.stats);
        if (e is ErrorEvent) _error = e.message;
      }
      await s.llm.resetSession(session);
      if (!mounted) return;
      setState(() => _done++);
    }
    if (stats.isNotEmpty) {
      final ttft = stats.map((x) => x.timeToFirstTokenMs).reduce((a, b) => a + b) ~/ stats.length;
      final tps = stats.map((x) => x.effectiveTokensPerSec).reduce((a, b) => a + b) / stats.length;
      final tokens = stats.map((x) => x.outputTokens).reduce((a, b) => a + b);
      _results.insert(
        0,
        _BenchResult(modelById(s.settings.plannerId)?.name ?? s.settings.plannerId, ttft, tps, tokens, DateTime.now()),
      );
      await s.ledger.record('benchmark', '${_results.first.model}: ${tps.toStringAsFixed(1)} tok/s');
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    final best = _results.isEmpty ? null : _results.first;
    return ListView(
      padding: const EdgeInsets.fromLTRB(gutter, 16, gutter, 40),
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.isDemo ? 'Demo engine' : (modelById(s.settings.plannerId)?.name ?? '—'),
                style: context.text.titleMedium,
              ),
              Text(
                '${s.models.device.model.isEmpty ? s.platform : s.models.device.model} · ${s.settings.useGpu ? 'GPU' : 'CPU'}',
                style: context.text.bodySmall,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _Metric('tok/s', best == null ? '—' : best.tps.toStringAsFixed(1)),
                  _Metric('first token', best == null ? '—' : formatMs(best.ttft)),
                  _Metric('tokens', best == null ? '—' : '${best.tokens}'),
                ],
              ),
              const SizedBox(height: 16),
              if (_running)
                Column(
                  children: [
                    LinearProgressIndicator(value: _done / _prompts.length),
                    const SizedBox(height: 8),
                    Text('Prompt ${_done + 1} of ${_prompts.length}', style: context.text.bodySmall),
                  ],
                )
              else
                InkButton('run the speed test', trailing: Doodle.play, expand: true, onTap: _run),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(color: p.danger)),
                ),
            ],
          ),
        ),
        if (_results.length > 1) ...[
          const SectionHead('earlier runs'),
          for (final r in _results.skip(1))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(r.model),
              subtitle: Text(timeAgo(r.time)),
              trailing: Text('${r.tps.toStringAsFixed(1)} tok/s', style: context.text.bodyMedium),
            ),
        ],
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: context.text.headlineMedium),
        Text(label, style: context.text.bodySmall),
      ],
    ),
  );
}
