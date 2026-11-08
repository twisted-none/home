import 'package:flutter/material.dart';

import 'api.dart';
import 'ui.dart';

class ChoresView extends StatelessWidget {
  const ChoresView({
    super.key,
    required this.chores,
    required this.members,
    required this.onComplete,
    required this.onEdit,
    required this.busy,
  });

  final List<Json> chores;
  final List<Json> members;
  final ValueChanged<Json> onComplete;
  final ValueChanged<Json> onEdit;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final names = {for (final member in members) member['id']: member['name']};
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 96),
      children: [
        if (chores.isEmpty)
          const EmptyMessage(
            icon: Icons.checklist,
            title: 'Пока нет домашних дел',
            detail: 'Добавьте первое дело и выберите, как часто его повторять.',
          ),
        for (final chore in chores) ...[
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                IconButton.outlined(
                  icon: const Icon(Icons.check),
                  tooltip: 'Отметить выполненным',
                  onPressed: busy ? null : () => onComplete(chore),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ChoreLabel(
                    chore: chore,
                    assignee: names[chore['assignee_id']] as String?,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Изменить дело',
                  onPressed: busy ? null : () => onEdit(chore),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class ChoreLabel extends StatelessWidget {
  const ChoreLabel({super.key, required this.chore, this.assignee});

  final Json chore;
  final String? assignee;

  @override
  Widget build(BuildContext context) {
    final due = moscowTime(chore['due_at'] as String);
    final overdue = DateTime.parse(
      chore['due_at'] as String,
    ).isBefore(DateTime.now());
    final interval = chore['interval_days'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          chore['title'] as String,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 3),
        Text(
          interval == 1
              ? 'Каждый день · ${assignee ?? 'Для всех'}'
              : 'Интервал $interval дн. · ${assignee ?? 'Для всех'}',
          style: const TextStyle(color: muted),
        ),
        Text(
          '${overdue ? 'Просрочено · ' : ''}${ruDate(due)} в ${clockTime(due)}',
          style: TextStyle(color: overdue ? warm : accent),
        ),
      ],
    );
  }
}

class ChoreEditor extends StatefulWidget {
  const ChoreEditor({
    super.key,
    required this.api,
    required this.members,
    this.chore,
  });

  final FamilyApi api;
  final List<Json> members;
  final Json? chore;

  @override
  State<ChoreEditor> createState() => _ChoreEditorState();
}

class _ChoreEditorState extends State<ChoreEditor> {
  final form = GlobalKey<FormState>();
  late final TextEditingController title;
  late final TextEditingController interval;
  late DateTime day;
  late TimeOfDay time;
  late String assignee;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    final chore = widget.chore;
    final due = chore == null ? null : moscowTime(chore['due_at'] as String);
    final today = moscowTime(DateTime.now().toUtc().toIso8601String());
    title = TextEditingController(text: chore?['title'] as String?);
    interval = TextEditingController(
      text: (chore?['interval_days'] ?? 1).toString(),
    );
    day = due ?? today;
    time = due == null
        ? const TimeOfDay(hour: 19, minute: 0)
        : TimeOfDay(hour: due.hour, minute: due.minute);
    assignee = chore?['assignee_id'] as String? ?? '';
  }

  @override
  void dispose() {
    title.dispose();
    interval.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    final chore = widget.chore;
    await change(
      () => widget.api.send(
        chore == null ? 'POST' : 'PUT',
        chore == null ? '/chores' : '/chores/${chore['id']}',
        body: {
          'title': title.text.trim(),
          'interval_days': int.parse(interval.text),
          'first_date': dateKey(day),
          'reminder_time':
              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
          'assignee_id': assignee.isEmpty ? null : assignee,
          if (chore != null) 'expected_occurrence': chore['occurrence'],
        },
      ),
    );
  }

  Future<void> remove() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Убрать дело из списка?'),
        content: const Text('Отметки о выполнении останутся в истории.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Убрать'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await change(
        () => widget.api.send(
          'DELETE',
          '/chores/${widget.chore!['id']}',
          retry: true,
        ),
      );
    }
  }

  Future<void> change(Future<dynamic> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) toast(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.chore == null ? 'Новое дело' : 'Изменить дело'),
    ),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          TextFormField(
            enabled: !busy,
            controller: title,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Что нужно сделать?',
              counterText: '',
            ),
            validator: (value) =>
                value!.trim().isEmpty ? 'Введите название' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            enabled: !busy,
            controller: interval,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Повтор каждые N дней',
            ),
            validator: (value) {
              final days = int.tryParse(value!);
              return days == null || days < 1 || days > 365
                  ? 'Введите от 1 до 365 дней'
                  : null;
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: assignee,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Кому напоминать'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Всем в семье')),
              ...widget.members.map(
                (member) => DropdownMenuItem(
                  value: member['id'] as String,
                  child: Text(
                    member['name'] as String,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
            onChanged: busy
                ? null
                : (value) => setState(() => assignee = value!),
          ),
          const SizedBox(height: 12),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.calendar_today_outlined),
                  title: Text(
                    widget.chore == null ? 'Первый срок' : 'Следующий срок',
                  ),
                  subtitle: Text(ruDate(day)),
                  onTap: busy
                      ? null
                      : () async {
                          final value = await showDatePicker(
                            context: context,
                            initialDate: DateTime(day.year, day.month, day.day),
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100, 12, 31),
                          );
                          if (mounted && value != null) {
                            setState(() => day = value);
                          }
                        },
                ),
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: const Text('Время напоминания'),
                  subtitle: Text('${time.format(context)} · Москва'),
                  onTap: busy
                      ? null
                      : () async {
                          final value = await showTimePicker(
                            context: context,
                            initialTime: time,
                          );
                          if (mounted && value != null) {
                            setState(() => time = value);
                          }
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : save,
            child: Text(busy ? 'Сохраняем…' : 'Сохранить'),
          ),
          if (widget.chore != null)
            TextButton(
              onPressed: busy ? null : remove,
              child: const Text('Убрать из списка'),
            ),
        ],
      ),
    ),
  );
}

class ActivityView extends StatefulWidget {
  const ActivityView({super.key, required this.activity});

  final Json activity;

  @override
  State<ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends State<ActivityView> {
  static const colors = [
    Color(0xff393440),
    Color(0xff654770),
    Color(0xff8e5f9e),
    Color(0xffbd81ce),
    accent,
  ];
  static const months = [
    'Янв',
    'Фев',
    'Мар',
    'Апр',
    'Май',
    'Июн',
    'Июл',
    'Авг',
    'Сен',
    'Окт',
    'Ноя',
    'Дек',
  ];
  String? selected;

  @override
  Widget build(BuildContext context) {
    final start = DateTime.parse('${widget.activity['start']}T00:00:00Z');
    final today = DateTime.parse('${widget.activity['today']}T00:00:00Z');
    final days = widget.activity['days'] as Json;
    final selectedDay = selected ?? dateKey(today);
    final records = rows(days[selectedDay] ?? []);
    final monday = start.subtract(Duration(days: start.weekday - 1));
    final weeks = today.difference(monday).inDays ~/ 7 + 1;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(18),
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Последние 12 месяцев',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              const Text(
                'Выполненные домашние дела',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  children: List.generate(weeks, (index) {
                    final week = monday.add(Duration(days: index * 7));
                    final last = week.add(const Duration(days: 6));
                    final label = index == 0
                        ? months[start.month - 1]
                        : (week.day == 1 || week.month != last.month
                              ? months[last.month - 1]
                              : '');
                    return SizedBox(
                      width: 25,
                      child: Column(
                        children: [
                          Text(
                            label,
                            style: const TextStyle(fontSize: 10, color: muted),
                          ),
                          const SizedBox(height: 4),
                          for (var offset = 0; offset < 7; offset++)
                            tile(
                              week.add(Duration(days: offset)),
                              start,
                              today,
                              days,
                              selectedDay,
                            ),
                        ],
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 5,
                runSpacing: 5,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Меньше', style: TextStyle(color: muted)),
                  for (final color in colors)
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  const Text('Больше', style: TextStyle(color: muted)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ruDate(DateTime.parse(selectedDay)),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (records.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('За этот день отметок нет.'),
                ),
              for (final record in records)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.check_circle_outline,
                    color: accent,
                  ),
                  title: Text(record['title'] as String),
                  subtitle: Text(record['name'] as String),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget tile(
    DateTime day,
    DateTime start,
    DateTime today,
    Json days,
    String selectedDay,
  ) {
    if (day.isBefore(start) || day.isAfter(today)) {
      return const SizedBox(height: 25);
    }
    final key = dateKey(day);
    final count = (days[key] as List?)?.length ?? 0;
    return Semantics(
      button: true,
      selected: key == selectedDay,
      label: '${ruDate(day)}, выполнено $count',
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Material(
          color: colors[count.clamp(0, 4)],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(5),
            side: key == selectedDay
                ? const BorderSide(color: Colors.white, width: 1.4)
                : BorderSide.none,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(5),
            onTap: () => setState(() => selected = key),
            child: const SizedBox(width: 21, height: 21),
          ),
        ),
      ),
    );
  }
}
