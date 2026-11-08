import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'chores.dart';
import 'shopping.dart';
import 'ui.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.api,
    required this.profile,
    required this.pushEnabled,
    required this.onExpired,
    required this.signOut,
  });

  final FamilyApi api;
  final Json profile;
  final bool pushEnabled;
  final Future<void> Function() onExpired;
  final Future<void> Function() signOut;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const titles = ['Домашние дела', 'Активность', 'Покупки', 'Семья'];
  late Json profile;
  Json? activity;
  List<Json> chores = [];
  List<Json> draft = [];
  List<Json> items = [];
  List<Json> notices = [];
  Object? error;
  int tab = 0;
  int loadVersion = 0;
  bool loading = true;
  bool busy = false;
  bool foreground = true;
  Timer? refresh;
  String? installationId;
  bool reportPushResult = false;
  String? publishKey;
  String? publishDraft;
  final subscriptions = <StreamSubscription<dynamic>>[];

  FamilyApi get api => widget.api;
  List<Json> get members => rows(profile['members']);
  Json get family => profile['family'] as Json;

  @override
  void initState() {
    super.initState();
    profile = widget.profile;
    WidgetsBinding.instance.addObserver(this);
    load();
    refresh = Timer.periodic(const Duration(seconds: 20), (_) {
      if (foreground && !busy && !loading) load();
    });
    if (widget.pushEnabled) startMessaging();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    refresh?.cancel();
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      load();
      if (widget.pushEnabled) registerPush();
    }
  }

  void startMessaging() {
    subscriptions.add(
      FirebaseMessaging.onMessage.listen((message) {
        if (!mounted) return;
        toast(
          context,
          message.data['kind'] == 'shopping'
              ? 'Семья обновила список покупок'
              : 'Пора выполнить домашнее дело',
        );
        load();
      }),
    );
    subscriptions.add(FirebaseMessaging.onMessageOpenedApp.listen(openPush));
    subscriptions.add(
      FirebaseMessaging.instance.onRegistered.listen(
        saveInstallation,
        onError: (Object _) => showPushResult(false),
      ),
    );
    FirebaseMessaging.instance
        .getInitialMessage()
        .then((message) {
          if (message != null && mounted) openPush(message);
        })
        .catchError((Object _) {});
    registerPush();
  }

  void openPush(RemoteMessage message) {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => tab = message.data['kind'] == 'shopping' ? 2 : 0);
    load();
  }

  Future<void> registerPush({bool ask = false}) async {
    if (!widget.pushEnabled) return;
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = ask
          ? await messaging.requestPermission()
          : await messaging.getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.authorized) {
        if (ask && mounted) {
          toast(context, 'Разрешите уведомления в настройках Android.');
        }
        return;
      }
      if (!mounted) return;
      if (ask) reportPushResult = true;
      await messaging.register();
    } catch (_) {
      if (ask && mounted && !reportPushResult) {
        toast(context, 'Не удалось включить push-уведомления.');
      }
      showPushResult(false);
    }
  }

  Future<void> saveInstallation(String fid) async {
    try {
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      if (!mounted ||
          settings.authorizationStatus != AuthorizationStatus.authorized) {
        return;
      }
      if (fid != installationId) {
        await api.send(
          'PUT',
          '/devices',
          retry: true,
          body: {
            'installation_id': fid,
            'previous_installation_id': installationId,
          },
        );
        installationId = fid;
      }
      showPushResult(true);
    } catch (_) {
      showPushResult(false);
    }
  }

  void showPushResult(bool registered) {
    if (!mounted || !reportPushResult) return;
    reportPushResult = false;
    toast(
      context,
      registered
          ? 'Push-уведомления включены'
          : 'Не удалось включить push-уведомления.',
    );
  }

  Future<void> load() async {
    final version = ++loadVersion;
    loading = true;
    try {
      final values = await Future.wait([
        api.get('/family'),
        api.get('/chores'),
        api.get('/activity'),
        api.get('/shopping'),
        api.get('/notifications'),
      ]);
      if (!mounted || version != loadVersion) return;
      final shopping = values[3] as Json;
      setState(() {
        profile = values[0] as Json;
        chores = rows(values[1]);
        activity = values[2] as Json;
        draft = rows(shopping['draft']);
        items = rows(shopping['items']);
        notices = rows(values[4]);
        error = null;
        loading = false;
      });
    } catch (failure) {
      if (!mounted || version != loadVersion) return;
      if (failure is ApiFailure && failure.status == 401) {
        await widget.onExpired();
        return;
      }
      setState(() {
        error = failure;
        loading = false;
      });
    }
  }

  Future<void> mutate(Future<dynamic> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (failure) {
      if (mounted) toast(context, failure);
    } finally {
      if (mounted) {
        await load();
        if (mounted) setState(() => busy = false);
      }
    }
  }

  Future<void> edit([Json? chore]) async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ChoreEditor(api: api, members: members, chore: chore),
      ),
    );
    if (mounted) await load();
  }

  void complete(Json chore) => mutate(
    () => api.send(
      'POST',
      '/chores/${chore['id']}/complete',
      retry: true,
      body: {'occurrence': chore['occurrence']},
    ),
  );

  Future<void> showCatalogs() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (context) => CatalogScreen(api: api)),
    );
    if (mounted) await load();
  }

  void publish() {
    final ids = draft.map((item) => item['id'] as String).toList()..sort();
    final currentDraft = ids.join(',');
    if (publishDraft != currentDraft || publishKey == null) {
      publishDraft = currentDraft;
      publishKey = uuid.v4();
    }
    mutate(() async {
      final result =
          await api.send(
                'POST',
                '/shopping/publish',
                retry: true,
                body: {'request_id': publishKey},
              )
              as Json;
      publishKey = null;
      if (mounted && (result['count'] as int) > 0) {
        toast(context, 'Корзина добавлена в общий список');
      }
    });
  }

  Future<void> invite() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await api.send('POST', '/family/invites') as Json;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Приглашение в семью'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Отправьте ссылку участнику. Она действует 24 часа и подходит для одного аккаунта.',
              ),
              const SizedBox(height: 10),
              SelectableText(result['link'] as String),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Закрыть'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: result['link'] as String),
                );
                if (dialog.mounted) Navigator.pop(dialog);
                if (mounted) toast(context, 'Ссылка скопирована');
              },
              icon: const Icon(Icons.copy),
              label: const Text('Копировать'),
            ),
          ],
        ),
      );
    } catch (failure) {
      if (mounted) toast(context, failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> openNotices() async {
    final target = await Navigator.push<int>(
      context,
      MaterialPageRoute(
        builder: (context) => NoticesScreen(api: api, initial: notices),
      ),
    );
    if (!mounted) return;
    if (target != null) setState(() => tab = target);
    await load();
  }

  @override
  Widget build(BuildContext context) {
    final unread = notices.where((notice) => notice['read'] == false).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[tab]),
        actions: [
          IconButton(
            onPressed: openNotices,
            tooltip: 'Уведомления',
            icon: Badge(
              label: Text('$unread'),
              isLabelVisible: unread > 0,
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
        ],
      ),
      body: activity == null && loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: ErrorNotice(error: error!, retry: load),
                  ),
                Expanded(
                  child: RefreshIndicator(onRefresh: load, child: page()),
                ),
              ],
            ),
      floatingActionButton: tab == 0 && activity != null
          ? FloatingActionButton.extended(
              onPressed: busy ? null : () => edit(),
              icon: const Icon(Icons.add),
              label: const Text('Добавить дело'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) {
          setState(() => tab = value);
          load();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.checklist_outlined),
            label: 'Дела',
          ),
          NavigationDestination(icon: Icon(Icons.grid_view), label: 'История'),
          NavigationDestination(
            icon: Icon(Icons.shopping_bag_outlined),
            label: 'Покупки',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            label: 'Семья',
          ),
        ],
      ),
    );
  }

  Widget page() => switch (tab) {
    0 => ChoresView(
      chores: chores,
      members: members,
      onComplete: complete,
      onEdit: edit,
      busy: busy,
    ),
    1 => activity == null ? ListView() : ActivityView(activity: activity!),
    2 => ShoppingView(
      items: items,
      draft: draft,
      busy: busy,
      onCatalogs: showCatalogs,
      onPublish: publish,
      onRemove: (item) => mutate(
        () => api.send('DELETE', '/shopping/draft/${item['id']}', retry: true),
      ),
      onBought: (item) => mutate(
        () => api.send(
          'PATCH',
          '/shopping/items/${item['id']}',
          retry: true,
          body: {'bought': item['bought'] != true},
        ),
      ),
    ),
    _ => familyPage(),
  };

  Widget familyPage() => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(18),
    children: [
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              family['name'] as String,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: ValueKey(family['city']),
              initialValue: family['city'] as String,
              decoration: const InputDecoration(labelText: 'Город покупок'),
              items: cityNames.entries
                  .map(
                    (city) => DropdownMenuItem(
                      value: city.key,
                      child: Text(city.value),
                    ),
                  )
                  .toList(),
              onChanged: profile['owner'] == true && !busy
                  ? (city) async {
                      if (city == null || city == family['city']) return;
                      await mutate(
                        () =>
                            api.send('PATCH', '/family', body: {'city': city}),
                      );
                    }
                  : null,
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Text('Участники', style: Theme.of(context).textTheme.titleLarge),
      for (final member in members)
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: Text(member['name'] as String),
          trailing: member['id'] == profile['user_id']
              ? const Text('Вы')
              : null,
        ),
      if (profile['owner'] == true)
        OutlinedButton.icon(
          onPressed: busy ? null : invite,
          icon: const Icon(Icons.person_add_outlined),
          label: const Text('Пригласить участника'),
        ),
      if (widget.pushEnabled)
        TextButton.icon(
          onPressed: () => registerPush(ask: true),
          icon: const Icon(Icons.notifications_outlined),
          label: const Text('Включить push-уведомления'),
        ),
      TextButton(
        onPressed: busy ? null : widget.signOut,
        child: const Text('Выйти из аккаунта'),
      ),
    ],
  );
}

class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key, required this.api, required this.initial});

  final FamilyApi api;
  final List<Json> initial;

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen> {
  late List<Json> notices;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    notices = widget.initial;
    load();
  }

  Future<void> load() async {
    try {
      final result = rows(await widget.api.get('/notifications'));
      if (mounted) setState(() => notices = result);
    } catch (error) {
      if (mounted) toast(context, error);
    }
  }

  Future<void> read(Json notice) async {
    if (busy) return;
    busy = true;
    try {
      if (notice['read'] != true) {
        await widget.api.send(
          'POST',
          '/notifications/${notice['id']}/read',
          retry: true,
        );
      }
      if (mounted) Navigator.pop(context, notice['kind'] == 'shopping' ? 2 : 0);
    } catch (error) {
      if (mounted) toast(context, error);
    } finally {
      busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Уведомления')),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(18),
        children: [
          if (notices.isEmpty)
            const EmptyMessage(
              icon: Icons.notifications_none,
              title: 'Пока тихо',
              detail: 'Здесь появятся напоминания и обновления списка покупок.',
            ),
          for (final notice in notices)
            ListTile(
              onTap: () => read(notice),
              leading: Icon(
                notice['kind'] == 'shopping'
                    ? Icons.shopping_bag_outlined
                    : Icons.schedule,
              ),
              trailing: notice['read'] == true
                  ? null
                  : const Icon(Icons.circle, size: 8, color: accent),
              title: Text(
                notice['kind'] == 'shopping'
                    ? 'Семья обновила список покупок'
                    : 'Пора выполнить домашнее дело',
              ),
              subtitle: Text(
                ruDate(moscowTime(notice['created_at'] as String)),
              ),
            ),
        ],
      ),
    ),
  );
}
