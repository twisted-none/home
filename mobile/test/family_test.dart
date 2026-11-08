import 'dart:async';

import 'package:family_board/api.dart';
import 'package:family_board/chores.dart';
import 'package:family_board/onboarding.dart';
import 'package:family_board/shopping.dart';
import 'package:family_board/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Поддерживаются приглашение по ссылке и код', () {
    const code = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    expect(inviteCode(code), code);
    expect(inviteCode('familyboard://invite/$code'), code);
    expect(inviteCode('https://elsewhere.test/invite/$code'), isNull);
  });

  test('Повтор POST сохраняет тело запроса и серверную версию API', () async {
    final requests = <http.Request>[];
    final api = FamilyApi(
      baseUrl: 'https://family.example.com',
      client: MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) throw TimeoutException('connection failed');
        return http.Response('{"count":2}', 200);
      }),
    )..token = 'token';
    addTearDown(api.close);
    expect(
      await api.send(
        'POST',
        '/shopping/publish',
        retry: true,
        body: {'request_id': 'same-id'},
      ),
      {'count': 2},
    );
    expect(requests.length, 2);
    expect(requests.first.url.path, '/api/v1/shopping/publish');
    expect(requests.first.headers['authorization'], 'Bearer token');
    expect(requests.first.body, requests.last.body);
  });

  testWidgets('Карта показывает дела и исполнителей за выбранный день', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: familyTheme(),
        home: const Scaffold(
          body: ActivityView(
            activity: {
              'start': '2025-11-09',
              'today': '2026-11-08',
              'days': {
                '2026-11-08': [
                  {'title': 'Поменять лоток', 'name': 'Саша'},
                ],
              },
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Последние 12 месяцев'), findsOneWidget);
    expect(find.text('Поменять лоток'), findsOneWidget);
    expect(find.text('Саша'), findsOneWidget);
    final day = find.bySemanticsLabel('07.11.2026, выполнено 0');
    expect(day, findsOneWidget);
    await tester.tap(day);
    await tester.pumpAndSettle();
    expect(find.text('За этот день отметок нет.'), findsOneWidget);
  });

  testWidgets('Общий список группирует товар по точке и отмечает покупку', (
    tester,
  ) async {
    Json? checked;
    await tester.pumpWidget(
      MaterialApp(
        theme: familyTheme(),
        home: Scaffold(
          body: ShoppingView(
            items: const [
              {
                'name': 'Молоко',
                'chain': 'magnit',
                'city': 'domodedovo',
                'store_name': 'Тестовая точка',
                'price_kopecks': 8950,
                'quantity_milliunits': 1500,
                'unit': 'л',
                'bought': false,
              },
            ],
            draft: const [],
            busy: false,
            onCatalogs: () {},
            onPublish: () {},
            onRemove: (_) {},
            onBought: (item) => checked = item,
          ),
        ),
      ),
    );
    expect(find.text('Магнит · Домодедово · Тестовая точка'), findsOneWidget);
    expect(find.text('1,5 л · 89,50 ₽ / л'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    expect(checked?['name'], 'Молоко');
  });
}
