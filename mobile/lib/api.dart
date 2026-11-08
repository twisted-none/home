import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

typedef Json = Map<String, dynamic>;

List<Json> rows(dynamic value) => (value as List).cast<Json>();

const cityNames = {'moscow': 'Москва', 'domodedovo': 'Домодедово'};
const chainNames = {
  'pyaterochka': 'Пятёрочка',
  'perekrestok': 'Перекрёсток',
  'chizhik': 'Чижик',
  'dixy': 'Дикси',
  'magnit': 'Магнит',
  'krasnoe-beloe': 'Красное&Белое',
  'aromatny-mir': 'Ароматный Мир',
};

DateTime moscowTime(String timestamp) =>
    DateTime.parse(timestamp).toUtc().add(const Duration(hours: 3));

String dateKey(DateTime date) => date.toIso8601String().substring(0, 10);

String ruDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';

String clockTime(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

String priceText(int kopecks) =>
    '${(kopecks / 100).toStringAsFixed(2).replaceFirst('.', ',')} ₽';

class ApiFailure implements Exception {
  const ApiFailure(this.message, [this.status]);
  final String message;
  final int? status;

  @override
  String toString() => message;
}

class FamilyApi {
  FamilyApi({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      _baseUrl =
          baseUrl ??
          const String.fromEnvironment(
            'API_BASE_URL',
            defaultValue: kDebugMode ? 'http://10.0.2.2:8000' : '',
          );

  final http.Client _client;
  final String _baseUrl;
  String? token;

  void close() => _client.close();

  Future<dynamic> get(String path) => send('GET', path);

  Future<dynamic> send(
    String method,
    String path, {
    Json? body,
    bool retry = false,
  }) async {
    final base = Uri.tryParse(_baseUrl);
    if (base == null ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        !(base.scheme == 'https' || (kDebugMode && base.scheme == 'http'))) {
      throw const ApiFailure('Для этой сборки нужен адрес сервера HTTPS.');
    }
    final uri = base.resolve('/api/v1$path');
    for (var attempt = 0; ; attempt++) {
      final request = http.Request(method, uri)
        ..followRedirects = false
        ..headers['Accept'] = 'application/json';
      if (token case final String value) {
        request.headers['Authorization'] = 'Bearer $value';
      }
      if (body != null) {
        request.headers['Content-Type'] = 'application/json; charset=utf-8';
        request.body = jsonEncode(body);
      }
      try {
        final response = await _client
            .send(request)
            .then(http.Response.fromStream)
            .timeout(const Duration(seconds: 12));
        if (response.statusCode == 204) return null;
        final dynamic result;
        try {
          result = jsonDecode(utf8.decode(response.bodyBytes));
        } on FormatException {
          throw ApiFailure(
            'Сервер вернул неожиданный ответ.',
            response.statusCode,
          );
        }
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return result;
        }
        final detail = result is Json ? result['detail'] : null;
        throw ApiFailure(
          detail is String
              ? detail
              : response.statusCode == 422
              ? 'Проверьте введённые данные.'
              : 'Запрос не выполнен. Попробуйте ещё раз.',
          response.statusCode,
        );
      } on TimeoutException {
        if (!retry || attempt > 0) {
          throw const ApiFailure(
            'Сервер долго не отвечает. Попробуйте ещё раз.',
          );
        }
      } on http.ClientException {
        if (!retry || attempt > 0) {
          throw const ApiFailure('Не удалось подключиться к серверу.');
        }
      }
    }
  }
}
