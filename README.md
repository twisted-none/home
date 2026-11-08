# Домашние дела и покупки

Приложение для Android с личными аккаунтами и общей семьёй. В нём можно вести повторяющиеся дела, смотреть историю выполнения, собирать корзину из разных магазинов и отмечать покупки в общем списке.

## Server Setup

На сервере нужны Docker и Docker Compose. Скопируйте `.env.example` в `.env` и задайте свой пароль PostgreSQL. Запустите из корня проекта.

```sh
docker compose up -d --build
docker compose ps
curl -fsS http://127.0.0.1:8000/health
```

Compose поднимает PostgreSQL, выполняет миграции Alembic и запускает FastAPI и фоновый процесс. Данные хранятся в томе `postgres-data`. По умолчанию API доступен только на сервере через `127.0.0.1:8000`. Направьте на него HTTPS-прокси и проверьте `/health` по публичному адресу. Этот же HTTPS-адрес нужен при сборке APK.

### Catalog Data

Настройте `catalog-config/sources.json` и выгрузки для Москвы и Домодедова. Формат, география цен и состояние проверки источников описаны в [инструкции по каталогам](docs/catalogs.md). До успешного импорта приложение показывает официальные ссылки сетей и сообщение о недоступности цен.

### Firebase

1. Добавьте в проект Firebase приложение Android с идентификатором `ru.familyboard.family_board`. Поместите его `google-services.json` в `mobile/android/app/`.
2. Поместите файл сервисного аккаунта Firebase в каталог `secrets/` на сервере. Выдайте пользователю контейнера с UID 10001 права на чтение файла. Задайте `GOOGLE_APPLICATION_CREDENTIALS=/run/family-secrets/firebase-service-account.json` в `.env`, если файл назван `firebase-service-account.json`.
3. Запустите `docker compose up -d worker`. В приложении откройте **Семья → Включить push-уведомления** и разрешите их на обоих телефонах. Push требует Google Play Services. Список уведомлений в приложении доступен без настройки Firebase.

## Android Build

Для установки на оба телефона соберите один APK с адресом вашего сервера. Используйте Flutter 3.38.5 или совместимую версию SDK и Android SDK, указанный в выводе `flutter doctor`.

```sh
cd mobile
flutter pub get
flutter build apk --release --dart-define=API_BASE_URL=https://family.example.com --dart-define=ENABLE_PUSH=true
```

Замените `https://family.example.com` своим HTTPS-адресом. Результат лежит в `mobile/build/app/outputs/flutter-apk/app-release.apk`. Для собственной подписи укажите `storeFile`, `storePassword`, `keyAlias` и `keyPassword` в `mobile/android/key.properties`. При отсутствии файла Gradle использует отладочную подпись для тестовой установки. Для обновлений на обоих телефонах используйте один ключ подписи.

Создайте семью с первого аккаунта и откройте **Семья → Пригласить участника**. Отправьте скопированную ссылку второму участнику. Если мессенджер показывает её как текст, второй участник может вставить её в поле **Ссылка или код** после входа.

## Verification

```sh
cd backend
python -m pip install -r requirements.txt pytest
python -m pytest -q
```

По умолчанию интеграционные тесты используют временную SQLite. С `TEST_DATABASE_URL` тесты запускаются в отдельных временных схемах PostgreSQL и дополнительно проверяют одновременные запросы. Для ручной приёмки установите APK на два телефона, проверьте вход и приглашение, выполните общее дело, отправьте корзину из двух сетей и отметьте покупку со второго телефона.

```sh
cd mobile
flutter analyze
flutter test
```

Отладочная Android-сборка по умолчанию обращается к `http://10.0.2.2:8000` через эмулятор. Для теста без контейнеров выполните `alembic upgrade head`, `uvicorn app.main:app` и `python -m app.worker` из `backend/`, используя одно и то же окружение и каталог запуска.
