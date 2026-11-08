import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'ui.dart';

String? inviteCode(String value) {
  final text = value.trim();
  final uri = Uri.tryParse(text);
  final candidate =
      uri?.scheme == 'familyboard' &&
          uri?.host == 'invite' &&
          uri?.pathSegments.length == 1
      ? uri!.pathSegments.single
      : text;
  return RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(candidate) ? candidate : null;
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.submit, required this.hasInvite});

  final Future<void> Function(bool register, Json data) submit;
  final bool hasInvite;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  bool register = false;
  bool busy = false;
  bool showPassword = false;

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      await widget.submit(register, {
        'email': email.text.trim(),
        'password': password.text,
        if (register) 'name': name.text.trim(),
      });
    } catch (error) {
      if (mounted) toast(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Panel(
                  child: Icon(Icons.home_outlined, color: accent, size: 30),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Домашние дела\nи покупки',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                widget.hasInvite
                    ? 'Войдите или зарегистрируйтесь, чтобы принять приглашение в семью.'
                    : 'Общие дела, напоминания и список покупок для вашей семьи.',
                style: const TextStyle(color: muted),
              ),
              const SizedBox(height: 24),
              AutofillGroup(
                child: Form(
                  key: form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (register) ...[
                        TextFormField(
                          controller: name,
                          enabled: !busy,
                          maxLength: 80,
                          decoration: const InputDecoration(
                            labelText: 'Ваше имя',
                            counterText: '',
                          ),
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.name],
                          validator: (value) =>
                              value!.trim().isEmpty ? 'Введите имя' : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: email,
                        enabled: !busy,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(labelText: 'Email'),
                        validator: (value) =>
                            value!.contains('@') ? null : 'Введите email',
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: password,
                        enabled: !busy,
                        obscureText: !showPassword,
                        autofillHints: [
                          register
                              ? AutofillHints.newPassword
                              : AutofillHints.password,
                        ],
                        onFieldSubmitted: (_) => submit(),
                        decoration: InputDecoration(
                          labelText: 'Пароль',
                          suffixIcon: IconButton(
                            tooltip: showPassword
                                ? 'Скрыть пароль'
                                : 'Показать пароль',
                            onPressed: () =>
                                setState(() => showPassword = !showPassword),
                            icon: Icon(
                              showPassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                          ),
                        ),
                        validator: (value) =>
                            value!.length >= 8 && value.length <= 128
                            ? null
                            : 'От 8 до 128 символов',
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: busy ? null : submit,
                        child: Text(
                          busy
                              ? 'Подождите…'
                              : (register ? 'Создать аккаунт' : 'Войти'),
                        ),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() => register = !register),
                        child: Text(
                          register
                              ? 'У меня есть аккаунт'
                              : 'Зарегистрироваться',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class FamilySetup extends StatefulWidget {
  const FamilySetup({
    super.key,
    required this.api,
    required this.onReady,
    required this.signOut,
    this.code,
  });

  final FamilyApi api;
  final ValueChanged<Json> onReady;
  final Future<void> Function() signOut;
  final String? code;

  @override
  State<FamilySetup> createState() => _FamilySetupState();
}

class _FamilySetupState extends State<FamilySetup> {
  final name = TextEditingController();
  final invitation = TextEditingController();
  String city = 'moscow';
  bool busy = false;

  @override
  void initState() {
    super.initState();
    invitation.text = widget.code ?? '';
  }

  @override
  void didUpdateWidget(covariant FamilySetup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.code != oldWidget.code && widget.code != null) {
      invitation.text = widget.code!;
    }
  }

  @override
  void dispose() {
    name.dispose();
    invitation.dispose();
    super.dispose();
  }

  Future<void> submit(bool join) async {
    final code = inviteCode(invitation.text);
    if (join && code == null) {
      toast(context, 'Вставьте ссылку или код приглашения');
      return;
    }
    if (!join && name.text.trim().isEmpty) {
      toast(context, 'Введите название семьи');
      return;
    }
    setState(() => busy = true);
    try {
      final result = await widget.api.send(
        'POST',
        join ? '/family/join' : '/family',
        body: join ? {'code': code} : {'name': name.text.trim(), 'city': city},
      );
      if (mounted) widget.onReady(result as Json);
    } catch (error) {
      if (mounted) toast(context, error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Семья'),
      actions: [
        IconButton(
          onPressed: busy ? null : widget.signOut,
          icon: const Icon(Icons.logout),
          tooltip: 'Выйти',
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Присоединиться', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        TextField(
          controller: invitation,
          enabled: !busy,
          decoration: InputDecoration(
            labelText: 'Ссылка или код',
            suffixIcon: IconButton(
              tooltip: 'Вставить',
              onPressed: busy
                  ? null
                  : () async {
                      final data = await Clipboard.getData(
                        Clipboard.kTextPlain,
                      );
                      if (mounted && data?.text != null) {
                        invitation.text = data!.text!;
                      }
                    },
              icon: const Icon(Icons.content_paste),
            ),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: busy ? null : () => submit(true),
          child: const Text('Вступить в семью'),
        ),
        const SizedBox(height: 28),
        Text('Создать семью', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        TextField(
          controller: name,
          enabled: !busy,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Название семьи',
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: city,
          decoration: const InputDecoration(labelText: 'Город покупок'),
          items: cityNames.entries
              .map(
                (city) =>
                    DropdownMenuItem(value: city.key, child: Text(city.value)),
              )
              .toList(),
          onChanged: busy ? null : (value) => setState(() => city = value!),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: busy ? null : () => submit(false),
          child: const Text('Создать семью'),
        ),
        if (busy) const LinearProgressIndicator(),
      ],
    ),
  );
}
