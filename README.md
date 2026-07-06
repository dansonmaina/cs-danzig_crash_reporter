# danzig_crash_reporter

A Flutter crash reporting package that captures unhandled exceptions and delivers them across multiple channels simultaneously — Telegram, WhatsApp (Maytapi & Cloud API), SMTP Email, a Support Capture REST endpoint, and optional Claude AI root-cause analysis.

---

## Features

| Channel | Default |
|---|---|
| Telegram Bot | enabled |
| Maytapi WhatsApp | enabled |
| WhatsApp Cloud API (Meta) | disabled |
| SMTP Email | disabled |
| Support Capture ticket | enabled |
| Claude AI analysis | disabled |

Each channel can be toggled independently. Crashes within 5 minutes of each other are deduplicated automatically.

---

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  danzig_crash_reporter:
    git:
      url: https://github.com/dansonmaina/cs-danzig_crash_reporter.git
      ref: v1.1.1
```

Then run:

```bash
flutter pub get
```

---

## Quick Start

### 1. Initialize in `main.dart`

Call `CrashReporter.initialize()` **after** `dotenv.load()` (or however you load secrets), and **before** `runApp()`.

```dart
import 'package:danzig_crash_reporter/danzig_crash_reporter.dart';

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await dotenv.load();

      await CrashReporter.initialize(
        CrashReporterConfig(
          appName: 'MyApp',
          appCode: 'com.example.myapp',
          clientName: 'MY_CLIENT',
          developer: const CrashReporterDeveloper(
            name: 'Jane Dev',
            phone: '+254700000000',
            email: 'jane@example.com',
            telegramChatId: '123456789',  // fallback if DB sync not done yet
          ),
          telegramBotToken: dotenv.env['TELEGRAM_BOT_TOKEN'] ?? '',
          maytapiProductId: dotenv.env['MAYTAPI_PRODUCT_ID'] ?? '',
          maytapiPhoneId: dotenv.env['MAYTAPI_PHONE_ID'] ?? '',
          maytapiApiKey: dotenv.env['MAYTAPI_API_KEY'] ?? '',
          developerSyncEndpoint: dotenv.env['DEVELOPER_SYNC_ENDPOINT'] ?? '',
        ),
      );

      // Wire up Flutter error hooks
      FlutterError.onError = (details) async {
        if (kDebugMode) FlutterError.presentError(details);
        await CrashReporter.report(details.exception, details.stack);
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        CrashReporter.report(error, stack);
        return true;
      };

      runApp(const MyApp());
    },
    (error, stack) async {
      await CrashReporter.report(error, stack);
    },
  );
}
```

### 2. Sync developers after login (optional but recommended)

After a successful login, call `CrashReporter.syncDevelopers()` to fetch the assigned developer list from your backend (via `developerSyncEndpoint`) and store it in the package's local database. At crash time the package reads from that database.

```dart
// In your login repository, after a successful response:
unawaited(CrashReporter.syncDevelopers(baseUrl: 'https://yourserver.com/'));
```

> See the **Developer Sync** section below for the endpoint contract.

---

## Configuration Reference

### Required fields

| Field | Description |
|---|---|
| `appName` | Human-readable app name shown in reports |
| `appCode` | Package identifier (e.g. `com.example.myapp`) |
| `clientName` | Client/organisation tag shown in reports |
| `developer` | Fallback developer for crash notifications |
| `telegramBotToken` | Telegram bot token |
| `maytapiProductId` | Maytapi product ID |
| `maytapiPhoneId` | Maytapi phone ID |
| `maytapiApiKey` | Maytapi API key |

### Optional — dynamic client name

If your client name is stored in a local database (e.g. after a sync), provide an async callback instead of a static string:

```dart
clientNameProvider: () async {
  final names = await MyDao().getClientNames();
  return names.isNotEmpty ? names.first : 'DEFAULT';
},
```

### Optional — SMTP Email

```dart
enableEmail: true,
smtpHost: 'email-smtp.eu-west-2.amazonaws.com',
smtpPort: 587,
smtpUsername: 'AKIAXXXXXXXX',
smtpPassword: 'your-smtp-password',
smtpFromAddress: 'noreply@example.com',
smtpFromName: 'My App Notifications',
organizationName: 'My Organisation',
supportEmail: 'support@example.com',
```

### Optional — WhatsApp Cloud API (Meta)

```dart
enableWhatsAppCloud: true,
whatsappToken: 'your-meta-permanent-token',
whatsappPhoneNumberId: 'your-phone-number-id',
```

### Optional — Claude AI Analysis

Adds a root-cause analysis section to every crash report.

```dart
enableClaudeAnalysis: true,
claudeApiKey: 'sk-ant-api03-...',
```

### Optional — Support Capture ticket endpoint

```dart
enableCrashTicket: true,
crashTicketEndpoint: 'https://yourserver.com/api/crash',
```

Leave `crashTicketEndpoint` empty (`''`) to disable ticket submission even if `enableCrashTicket` is `true`.

### Optional — Telegram chat ID server sync

Syncs developer Telegram chat IDs to your server so the assignment is recorded online. Records are only posted once — once the server confirms (`IsOkay: true`) the record is marked `synced` locally and skipped on future syncs.

```dart
telegramSyncEndpoint: 'https://yourserver.com/Configuration/AddChatAssignment',
```

The sync runs automatically on `CrashReporter.initialize()`. You can also trigger it manually after populating the developer database:

```dart
await CrashReporter.syncTelegramIds();
```

### Optional — Developer list sync

Fetches the assigned developer list (name, phone, email) from your backend and stores it locally, replacing whatever was previously stored. Every other channel (Telegram, Maytapi, WhatsApp, Email) reads from this table when sending crash notifications, falling back to the single `developer` in config if the table is empty.

```dart
developerSyncEndpoint: 'https://yourserver.com/Support/mobile/AddClientApp',
```

Call it manually after login, once you know `baseUrl`:

```dart
unawaited(CrashReporter.syncDevelopers(baseUrl: 'https://yourserver.com/'));
```

`syncDevelopers` POSTs `{ client_domain, client_name, app_name, app_id, app_version, is_active }` and expects a response shaped as:

```json
{
  "IsOkay": true,
  "Result": {
    "client": { "client_name": "MY_CLIENT" },
    "app": { "app_id": "com.example.myapp", "app_code": "myapp" },
    "Result": {
      "assignedUsers": [
        { "full_name": "Jane Dev", "phone_number": "+254700000000", "email_address": "jane@example.com" }
      ]
    }
  }
}
```

Leave `developerSyncEndpoint` empty (`''`) to skip this and rely solely on the fallback `developer` in config.

### Disable a channel entirely

```dart
enableTelegram: false,
enableMaytapi: false,
```

---

## Developer Sync

The package owns developer sync end-to-end: `CrashReporter.syncDevelopers()` fetches the list from `developerSyncEndpoint` and persists it via `CrashDeveloperDao` (see the **Optional — Developer list sync** section above). Telegram chat IDs are resolved separately and automatically by `CrashReporter.initialize()` via `fetchTelegramUpdates()` / `syncTelegramIds()` — you don't need to wire that up yourself.

If your backend's response shape doesn't match the built-in contract, you can still populate the database yourself — `CrashDeveloperDao` and `CrashDeveloper` remain public:

```dart
await CrashDeveloperDao().replaceAll([
  CrashDeveloper(
    fullName: 'Jane Dev',
    phone: '+254700000000',
    email: 'jane@example.com',
    appName: 'MyApp',
    appCode: 'com.example.myapp',
    clientName: 'MY_CLIENT',
  ),
]);
```

---

## `.env` example

```
TELEGRAM_BOT_TOKEN=1234567890:ABCdef...
MAYTAPI_PRODUCT_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
MAYTAPI_PHONE_ID=12345
MAYTAPI_API_KEY=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Optional
CRASH_TICKET_ENDPOINT=https://yourserver.com/api/crash
DEVELOPER_SYNC_ENDPOINT=https://yourserver.com/Support/mobile/AddClientApp
SMTP_HOST=email-smtp.eu-west-2.amazonaws.com
SMTP_PORT=587
SMTP_USERNAME=AKIAXXXXXXXX
SMTP_PASSWORD=your-smtp-password
SMTP_FROM=noreply@example.com
SMTP_FROM_NAME=MyApp Notifications
ORG_NAME=My Organisation
SUPPORT_EMAIL=support@example.com
ANTHROPIC_API_KEY=sk-ant-api03-...
```

> **Important:** Do not indent `.env` values. `flutter_dotenv` treats leading spaces as part of the key name.

---

## Manually reporting an error

```dart
try {
  // risky code
} catch (e, stack) {
  await CrashReporter.report(e, stack);
}
```

---

## How it works

```
Unhandled exception
      │
      ▼
CrashReporter.report()
      │
      ├── Claude AI analysis (optional)
      │
      └── Future.wait([
            _sendToSupportCapture(),   // REST ticket
            _sendToTelegram(),         // Bot message
            _sendToMaytapi(),          // WhatsApp via Maytapi
            _sendToWhatsAppCloud(),    // WhatsApp via Meta API
            _sendEmail(),              // SMTP HTML email
          ])
```

Developers are read from the local SQLite database (`danzig_crash_reporter.db`) populated by your app's `DeveloperSyncService`. The fallback `developer` in `CrashReporterConfig` is used if the database is empty.

---

## Requirements

- Flutter ≥ 3.0.0
- Dart SDK ≥ 3.0.0
- Android / iOS