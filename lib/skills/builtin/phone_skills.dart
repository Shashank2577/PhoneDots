import '../skill.dart';

/// Wraps a native device action. Results go straight back to the model.
FnSkill _device({
  required String id,
  required String name,
  required String description,
  required String action,
  List<SkillParam> params = const [],
  ConfirmPolicy confirm = ConfirmPolicy.never,
  Set<String> platforms = const {},
  List<String> examples = const [],
  String Function(Map<String, dynamic> args, Map<String, dynamic> result)? summary,
  List<UiCard> Function(Map<String, dynamic> result)? cards,
}) => FnSkill(
  id: id,
  name: name,
  description: description,
  kind: SkillKind.device,
  category: SkillCategory.phone,
  params: params,
  confirm: confirm,
  platforms: platforms,
  examples: examples,
  handler: (args, ctx) async {
    final r = await ctx.device(action, args);
    if (r['error'] != null) return SkillResult.error('${r['error']}');
    return SkillResult({
      ...r,
      if (summary != null && r['demo'] != true) 'summary': summary(args, r),
    }, cards: cards?.call(r) ?? const []);
  },
);

String _two(int n) => n.toString().padLeft(2, '0');

List<Skill> phoneSkills() => [
  _device(
    id: 'set_timer',
    name: 'Set a timer',
    description: 'Start a countdown timer.',
    action: 'timer.set',
    params: const [
      SkillParam('seconds', ParamType.integer, 'Timer length in seconds.'),
      SkillParam('label', ParamType.string, 'Optional label.', required: false),
    ],
    examples: const ['Set a timer for 10 minutes'],
    summary: (a, _) => 'Timer set for ${a.integer('seconds') ~/ 60} min ${a.integer('seconds') % 60} s.',
  ),
  _device(
    id: 'set_alarm',
    name: 'Set an alarm',
    description: 'Set an alarm at a time of day (24-hour clock).',
    action: 'alarm.set',
    params: const [
      SkillParam('hour', ParamType.integer, 'Hour 0-23.'),
      SkillParam('minute', ParamType.integer, 'Minute 0-59.'),
      SkillParam('label', ParamType.string, 'Optional label.', required: false),
    ],
    examples: const ['Wake me at 6:30'],
    summary: (a, _) => 'Alarm set for ${_two(a.integer('hour'))}:${_two(a.integer('minute'))}.',
  ),
  _device(
    id: 'create_event',
    name: 'Create calendar event',
    description: 'Add an event or reminder to the calendar.',
    action: 'calendar.create',
    confirm: ConfirmPolicy.firstTime,
    params: const [
      SkillParam('title', ParamType.string, 'Event title.'),
      SkillParam('start', ParamType.string, 'Start as ISO 8601 local time, e.g. 2026-11-02T15:00.'),
      SkillParam('end', ParamType.string, 'End as ISO 8601. Defaults to one hour later.', required: false),
      SkillParam('location', ParamType.string, 'Where.', required: false),
      SkillParam('notes', ParamType.string, 'Details.', required: false),
    ],
    examples: const ['Remind me to call Sam tomorrow at 5pm'],
    summary: (a, _) => 'Added "${a.str('title')}" to your calendar.',
  ),
  _device(
    id: 'list_events',
    name: 'Upcoming events',
    description: 'List calendar events in the next few days.',
    action: 'calendar.list',
    confirm: ConfirmPolicy.firstTime,
    params: const [SkillParam('days', ParamType.integer, 'How many days ahead (default 1).', required: false)],
    examples: const ["What's on my calendar today?"],
    cards: (r) => [
      UiCard(
        'timeline',
        title: 'Upcoming',
        data: {
          'items': [
            for (final e in (r['events'] as List? ?? const []).cast<Map>())
              {'time': '${e['start']}'.replaceFirst('T', ' ').split('.').first, 'text': '${e['title']}'},
          ],
        },
      ),
    ],
  ),
  _device(
    id: 'find_contact',
    name: 'Find contact',
    description: 'Look up a contact by name and return their phone numbers and emails.',
    action: 'contacts.search',
    confirm: ConfirmPolicy.firstTime,
    params: const [SkillParam('name', ParamType.string, 'Name to search for.')],
  ),
  _device(
    id: 'call_number',
    name: 'Call',
    description: 'Open the dialer with a phone number ready to call.',
    action: 'phone.dial',
    confirm: ConfirmPolicy.always,
    params: const [SkillParam('number', ParamType.string, 'Phone number.')],
  ),
  _device(
    id: 'draft_text_message',
    name: 'Draft a text',
    description: 'Open the messages app with a drafted SMS. The user sends it.',
    action: 'sms.compose',
    confirm: ConfirmPolicy.always,
    params: const [
      SkillParam('to', ParamType.string, 'Phone number.'),
      SkillParam('body', ParamType.string, 'Message text.'),
    ],
  ),
  _device(
    id: 'draft_email',
    name: 'Draft an email',
    description: 'Open the mail app with a drafted email. The user sends it.',
    action: 'email.compose',
    confirm: ConfirmPolicy.always,
    params: const [
      SkillParam('to', ParamType.string, 'Recipient email.'),
      SkillParam('subject', ParamType.string, 'Subject.'),
      SkillParam('body', ParamType.string, 'Body text.'),
    ],
  ),
  _device(
    id: 'open_app',
    name: 'Open app',
    description: 'Open an installed app by name.',
    action: 'app.open',
    params: const [SkillParam('name', ParamType.string, 'App name, e.g. Camera or Spotify.')],
    platforms: const {'android'},
  ),
  _device(
    id: 'open_url',
    name: 'Open link',
    description: 'Open a web link or deep link.',
    action: 'url.open',
    confirm: ConfirmPolicy.firstTime,
    params: const [SkillParam('url', ParamType.string, 'The URL.')],
  ),
  _device(
    id: 'navigate_to',
    name: 'Navigate',
    description: 'Start directions to a place in the maps app.',
    action: 'maps.navigate',
    params: const [
      SkillParam('destination', ParamType.string, 'Address or place name.'),
      SkillParam(
        'mode',
        ParamType.string,
        'Travel mode.',
        required: false,
        options: ['driving', 'walking', 'transit', 'cycling'],
      ),
    ],
  ),
  _device(
    id: 'toggle_flashlight',
    name: 'Flashlight',
    description: 'Turn the flashlight on or off.',
    action: 'torch',
    params: const [SkillParam('on', ParamType.boolean, 'true to turn on, false to turn off.')],
    examples: const ['Turn on the flashlight'],
    summary: (a, _) => 'Flashlight ${a.boolean('on') ? 'on' : 'off'}.',
  ),
  _device(
    id: 'open_settings',
    name: 'Open settings',
    description: 'Open a system settings page.',
    action: 'settings.open',
    params: const [
      SkillParam(
        'page',
        ParamType.string,
        'Which page.',
        options: ['wifi', 'bluetooth', 'dnd', 'display', 'sound', 'battery', 'location', 'apps', 'app'],
      ),
    ],
  ),
  _device(
    id: 'set_volume',
    name: 'Set volume',
    description: 'Set media, ring or alarm volume as a percentage.',
    action: 'volume.set',
    platforms: const {'android'},
    params: const [
      SkillParam('percent', ParamType.integer, 'Volume 0-100.'),
      SkillParam('stream', ParamType.string, 'Which volume.', required: false, options: ['media', 'ring', 'alarm']),
    ],
    summary: (a, _) => '${a.str('stream', 'media')} volume set to ${a.integer('percent')}%.',
  ),
  _device(
    id: 'battery_status',
    name: 'Battery',
    description: 'Get battery level and charging state.',
    action: 'battery',
    summary: (_, r) => 'Battery at ${r['level']}%${r['charging'] == true ? ', charging' : ''}.',
  ),
  _device(
    id: 'storage_status',
    name: 'Storage',
    description: 'Get free and total storage on the phone.',
    action: 'storage',
  ),
  _device(
    id: 'share_text',
    name: 'Share',
    description: 'Open the share sheet with some text.',
    action: 'share.text',
    params: const [SkillParam('text', ParamType.string, 'What to share.')],
  ),
  _device(
    id: 'copy_to_clipboard',
    name: 'Copy',
    description: 'Copy text to the clipboard.',
    action: 'clipboard.set',
    params: const [SkillParam('text', ParamType.string, 'Text to copy.')],
    summary: (_, _) => 'Copied to clipboard.',
  ),
  _device(
    id: 'read_clipboard',
    name: 'Read clipboard',
    description: 'Read the text currently on the clipboard.',
    action: 'clipboard.get',
    confirm: ConfirmPolicy.firstTime,
  ),
  _device(
    id: 'get_datetime',
    name: 'Date & time',
    description: 'Get the current local date, time, weekday and time zone.',
    action: 'datetime',
  ),
];
