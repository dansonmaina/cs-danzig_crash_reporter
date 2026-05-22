import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crash_reporter_config.dart';
import 'developer_dao.dart';
import 'developer_model.dart';

class CrashReporter {
  CrashReporter._();

  static CrashReporterConfig? _config;
  static String _deviceInfo = 'Unknown';
  static String _deviceVersion = 'Unknown';
  static String _appVersion = 'Unknown';
  static String _packageId = '';
  static bool _initialized = false;

  static String? _lastErrorKey;
  static DateTime? _lastReportTime;

  static const _claudeSystemPrompt =
      'You are a senior Flutter/iOS developer. Analyze the crash summary provided and give:\n'
      'Priority: [Critical|High|Medium|Low]\n'
      '1. Root cause: what likely caused this crash (1-2 sentences)\n'
      '2. Suggested fix: how to resolve it (2-3 sentences)\n\n'
      'Priority definitions:\n'
      '- Critical: crash on a core flow (login, sync, payment) — app cannot recover\n'
      '- High: crash on a main feature but the app can restart\n'
      '- Medium: crash on a secondary or edge-case flow\n'
      '- Low: rare, minor crash unlikely to affect most users\n\n'
      "Always start your response with exactly 'Priority: X' on the very first line, "
      'where X is one of: Critical, High, Medium, Low.';

  // ── Public API ────────────────────────────────────────────────────────────

  static String get telegramBotToken => _config?.telegramBotToken ?? '';
  static CrashReporterConfig? get config => _config;

  static Future<void> initialize(CrashReporterConfig config) async {
    _config = config;
    await Future.wait([_loadDeviceInfo(), _loadAppVersion()]);
    _initialized = true;
    debugPrint('✅ CrashReporter initialized — device: $_deviceInfo | app: $_appVersion');
    if (config.telegramBotToken.isNotEmpty || config.telegramSyncEndpoint.isNotEmpty) {
      _fetchThenSync().ignore();
    }
  }

  static Future<void> _fetchThenSync() async {
    if (_config!.telegramBotToken.isNotEmpty) {
      await fetchTelegramUpdates();
    }
    if (_config!.telegramSyncEndpoint.isNotEmpty) {
      await syncTelegramIds();
    }
  }

  static Future<void> fetchTelegramUpdates() async {
    if (_config == null) return;
    final token = _config!.telegramBotToken;
    if (token.isEmpty) return;
    final url = 'https://api.telegram.org/bot$token/getUpdates';
    try {
      debugPrint('CrashReporter: Telegram getUpdates → GET $url');
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      request.headers.set('Accept', 'application/json');
      final response = await request.close().timeout(const Duration(seconds: 10));
      final responseBody = await response.transform(utf8.decoder).join();
      client.close(force: false);

      debugPrint('CrashReporter: Telegram getUpdates → response [${response.statusCode}]: $responseBody');

      final decoded = jsonDecode(responseBody) as Map<String, dynamic>?;
      if (decoded == null || decoded['ok'] != true) {
        debugPrint('CrashReporter: Telegram getUpdates failed — ${decoded?['description'] ?? 'unknown error'}');
        return;
      }

      final results = (decoded['result'] as List<dynamic>? ?? []);
      if (results.isEmpty) {
        debugPrint('CrashReporter: Telegram getUpdates — no messages yet. Make sure developers text the bot first.');
        return;
      }

      final seen = <String>{};
      final dao = CrashDeveloperDao();
      final developers = await dao.getAll();

      for (final update in results) {
        final msg = (update as Map<String, dynamic>)['message'] as Map<String, dynamic>?;
        if (msg == null) continue;
        final from = msg['from'] as Map<String, dynamic>?;
        if (from == null) continue;
        final chatId = from['id']?.toString() ?? '';
        if (chatId.isEmpty || seen.contains(chatId)) continue;
        seen.add(chatId);

        final firstName = from['first_name'] as String? ?? '';
        final lastName = from['last_name'] as String? ?? '';
        final username = from['username'] as String? ?? '';
        final fullName = '$firstName $lastName'.trim();

        debugPrint(
          'CrashReporter: Telegram user found — '
          'chat_id: $chatId | name: $fullName | username: @$username',
        );

        // Auto-match a developer by name and update their chat ID if missing
        for (final dev in developers) {
          if (dev.telegramChatId.isNotEmpty) continue;
          final devName = dev.fullName.trim().toLowerCase();
          if (devName == fullName.toLowerCase() ||
              devName.contains(firstName.toLowerCase()) ||
              firstName.toLowerCase().contains(devName.split(' ').first)) {
            if (dev.id != null) {
              await dao.updateTelegramChatId(dev.id!, chatId);
              debugPrint(
                'CrashReporter: Telegram chat ID auto-assigned — '
                '${dev.fullName} → $chatId',
              );
            }
          }
        }
      }
    } catch (e) {
      debugPrint('CrashReporter: Telegram getUpdates failed — $e');
    }
  }

  static Future<void> syncTelegramIds() async {
    if (_config == null) return;
    final endpoint = _config!.telegramSyncEndpoint;
    if (endpoint.isEmpty) {
      debugPrint('CrashReporter: Telegram sync skipped — telegramSyncEndpoint not configured');
      return;
    }
    try {
      final dao = CrashDeveloperDao();
      final pending = await dao.getUnsyncedTelegramDevelopers();
      if (pending.isEmpty) {
        debugPrint('CrashReporter: Telegram sync — no pending records');
        return;
      }
      for (final dev in pending) {
        await _syncOneTelegramDeveloper(dao, dev, endpoint);
      }
    } catch (e) {
      debugPrint('CrashReporter: Telegram sync failed — $e');
    }
  }

  static Future<void> _syncOneTelegramDeveloper(
      CrashDeveloperDao dao, CrashDeveloper dev, String endpoint) async {
    try {
      final parts = dev.fullName.trim().split(RegExp(r'\s+'));
      final firstName = parts.isNotEmpty ? parts.first : dev.fullName;
      final lastName = parts.length > 1 ? parts.sublist(1).join(' ') : '';
      final chatIdValue = int.tryParse(dev.telegramChatId) ?? dev.telegramChatId;

      final body = jsonEncode({
        'telegramChatId': chatIdValue,
        'first_name': firstName,
        'last_name': lastName,
        'language_code': 'en',
      });

      debugPrint('CrashReporter: Telegram sync → POST $endpoint');
      debugPrint('CrashReporter: Telegram sync → request body: $body');

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final request = await client
          .postUrl(Uri.parse(endpoint))
          .timeout(const Duration(seconds: 10));
      request.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.headers.set('Accept', 'application/json');
      request.add(utf8.encode(body));
      final response = await request.close().timeout(const Duration(seconds: 10));
      final responseBody = await response.transform(utf8.decoder).join();
      client.close(force: false);

      debugPrint('CrashReporter: Telegram sync → response [${response.statusCode}]: $responseBody');

      final decoded = jsonDecode(responseBody) as Map<String, dynamic>?;
      if (decoded != null && decoded['IsOkay'] == true) {
        if (dev.id != null) await dao.markTelegramSynced(dev.id!);
        debugPrint('CrashReporter: Telegram sync succeeded for ${dev.fullName}');
      } else {
        debugPrint('CrashReporter: Telegram sync rejected for ${dev.fullName} — ${decoded?['Message'] ?? responseBody}');
      }
    } catch (e) {
      debugPrint('CrashReporter: Telegram sync failed for ${dev.fullName} — $e');
    }
  }

  static Future<void> onFlutterError(FlutterErrorDetails details) async {
    if (kDebugMode) FlutterError.presentError(details);
    await report(details.exception, details.stack ?? StackTrace.empty);
  }

  static Future<void> report(Object error, StackTrace? stackTrace) async {
    if (!_initialized || _config == null) return;

    final errorKey = error.toString();
    final now = DateTime.now();
    if (_lastErrorKey == errorKey &&
        _lastReportTime != null &&
        now.difference(_lastReportTime!).inMinutes < 5) {
      debugPrint('CrashReporter: duplicate suppressed — $errorKey');
      return;
    }
    _lastErrorKey = errorKey;
    _lastReportTime = now;

    try {
      final clientName = await _resolveClientName();
      final username = await _getUsername();
      final location = await _getLocation();
      final timestamp = DateFormat("yyyy-MM-dd'T'HH:mm:ss").format(DateTime.now());
      final stackStr = stackTrace?.toString() ?? 'No stack trace available';

      String? claudeAnalysis;
      String ticketPriority = 'Unknown';
      if (_config!.enableClaudeAnalysis && _config!.claudeApiKey.isNotEmpty) {
        final summary = _summarize(stackStr, error.toString());
        final rawAnalysis = await _fetchClaudeAnalysis(summary);
        if (rawAnalysis != null && rawAnalysis.isNotEmpty) {
          ticketPriority = _extractPriority(rawAnalysis);
          claudeAnalysis = _stripPriorityLine(rawAnalysis);
        }
      }

      final data = _CrashData(
        appName: _config!.appName,
        appCode: _config!.appCode,
        clientName: clientName,
        timestamp: timestamp,
        deviceVersion: _deviceVersion,
        appVersion: _appVersion,
        deviceInfo: _deviceInfo,
        crashReport: stackStr,
        errorMessage: error.toString(),
        username: username,
        lat: location?.lat,
        lon: location?.lon,
        claudeAnalysis: claudeAnalysis,
        ticketPriority: ticketPriority,
      );

      await Future.wait([
        if (_config!.enableCrashTicket) _sendToSupportCapture(data),
        if (_config!.enableTelegram) _sendToTelegram(data),
        if (_config!.enableMaytapi) _sendToMaytapi(data),
        if (_config!.enableWhatsAppCloud) _sendToWhatsAppCloud(data),
        if (_config!.enableEmail) _sendToEmail(data),
      ], eagerError: false);
    } catch (e) {
      debugPrint('CrashReporter: failed to dispatch report — $e');
    }
  }

  // ── Initialization helpers ────────────────────────────────────────────────

  static Future<void> _loadDeviceInfo() async {
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        _deviceInfo = '${info.manufacturer}_${info.model}';
        _deviceVersion = 'Android ${info.version.release}';
      } else if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        _deviceInfo = 'Apple_${info.utsname.machine}';
        _deviceVersion = '${info.systemName} ${info.systemVersion}';
      }
    } catch (e) {
      debugPrint('CrashReporter: device info unavailable — $e');
    }
  }

  static Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = 'v${info.version}';
      _packageId = info.packageName;
    } catch (e) {
      debugPrint('CrashReporter: package info unavailable — $e');
    }
  }

  static Future<String> _resolveClientName() async {
    try {
      if (_config!.clientNameProvider != null) {
        return await _config!.clientNameProvider!();
      }
    } catch (_) {}
    return _config!.clientName;
  }

  static Future<String> _getUsername() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_config!.usernamePrefsKey) ?? 'No user set';
    } catch (_) {
      return 'No user set';
    }
  }

  static Future<({double lat, double lon})?> _getLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null) return (lat: lastKnown.latitude, lon: lastKnown.longitude);
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      ).timeout(const Duration(seconds: 10));
      return (lat: pos.latitude, lon: pos.longitude);
    } catch (e) {
      debugPrint('CrashReporter: location failed — $e');
      return null;
    }
  }

  // ── Senders ───────────────────────────────────────────────────────────────

  static Future<void> _sendToSupportCapture(_CrashData data) async {
    if (_config!.crashTicketEndpoint.isEmpty) {
      debugPrint('CrashReporter: SupportCapture skipped — crashTicketEndpoint not configured');
      return;
    }
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final request = await client
          .postUrl(Uri.parse(_config!.crashTicketEndpoint))
          .timeout(const Duration(seconds: 10));
      request.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.headers.set('Accept', 'application/json');
      final body = jsonEncode({
        'app_code': data.appCode,
        'app_name': data.appName,
        'app_id': _packageId.isNotEmpty ? _packageId : data.appCode,
        'client_name': data.clientName,
        'timestamp': data.timestamp,
        'device_version': data.deviceVersion,
        'app_version': data.appVersion,
        'device_info': data.deviceInfo,
        'crash_report': data.crashReport,
        'ticket_priority': data.ticketPriority,
        if (data.lat != null && data.lon != null) ...{
          'latitude': data.lat,
          'longitude': data.lon,
          'location_url': 'https://maps.google.com/?q=${data.lat},${data.lon}',
        },
      });
      final bodyBytes = utf8.encode(body);
      request.headers.contentLength = bodyBytes.length;
      request.add(bodyBytes);
      final response = await request.close().timeout(const Duration(seconds: 10));
      final responseBody = await response.transform(utf8.decoder).join();
      client.close(force: false);
      final decoded = jsonDecode(responseBody) as Map<String, dynamic>?;
      if (decoded != null && decoded['IsOkay'] == true) {
        debugPrint('CrashReporter: SupportCapture ticket submitted');
      } else {
        debugPrint('CrashReporter: Error pushing to support capture. Check !! — ${decoded?['Message'] ?? responseBody}');
      }
    } catch (e) {
      debugPrint('CrashReporter: SupportCapture send failed — $e');
    }
  }

  static Future<void> _sendToTelegram(_CrashData data) async {
    final token = _config!.telegramBotToken;
    if (token.isEmpty) return;
    final developers = await _getDevelopers();
    final targets = developers.where((d) => d.telegramChatId.isNotEmpty).toList();
    if (targets.isEmpty) {
      debugPrint('CrashReporter: Telegram skipped — no developers with a chat ID in DB');
      return;
    }
    final message = _buildTelegramMessage(data);
    for (final dev in targets) {
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
        final request = await client
            .postUrl(Uri.parse('https://api.telegram.org/bot$token/sendMessage'))
            .timeout(const Duration(seconds: 10));
        request.headers.set('Content-Type', 'application/json; charset=utf-8');
        request.add(utf8.encode(jsonEncode({
          'chat_id': dev.telegramChatId,
          'text': message,
          'parse_mode': 'HTML',
        })));
        final response = await request.close().timeout(const Duration(seconds: 10));
        await response.drain<void>();
        client.close(force: false);
        debugPrint('CrashReporter: Telegram alert sent to ${dev.fullName}');
      } catch (e) {
        debugPrint('CrashReporter: Telegram send failed for ${dev.fullName} — $e');
      }
    }
  }

  static Future<void> _sendToMaytapi(_CrashData data) async {
    final productId = _config!.maytapiProductId;
    final phoneId = _config!.maytapiPhoneId;
    final apiKey = _config!.maytapiApiKey;
    if (productId.isEmpty || phoneId.isEmpty || apiKey.isEmpty) return;
    final developers = await _getDevelopers();
    final targets = developers.where((d) => d.phone.isNotEmpty).toList();
    if (targets.isEmpty) {
      debugPrint('CrashReporter: Maytapi skipped — no developers with a phone in DB');
      return;
    }
    final message = _buildWhatsAppMessage(data);
    final url = 'https://api.maytapi.com/api/$productId/$phoneId/sendMessage';
    for (final dev in targets) {
      try {
        final phone = dev.phone.startsWith('0') ? '254${dev.phone.substring(1)}' : dev.phone;
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
        final request = await client.postUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
        request.headers
          ..set('Content-Type', 'application/json; charset=utf-8')
          ..set('x-maytapi-key', apiKey);
        request.add(utf8.encode(jsonEncode({'to_number': phone, 'type': 'text', 'message': message})));
        final response = await request.close().timeout(const Duration(seconds: 10));
        await response.drain<void>();
        client.close(force: false);
        debugPrint('CrashReporter: Maytapi alert sent to ${dev.fullName}');
      } catch (e) {
        debugPrint('CrashReporter: Maytapi send failed for ${dev.fullName} — $e');
      }
    }
  }

  static Future<void> _sendToWhatsAppCloud(_CrashData data) async {
    final token = _config!.whatsappToken;
    final phoneNumberId = _config!.whatsappPhoneNumberId;
    if (token.isEmpty || phoneNumberId.isEmpty) return;
    final developers = await _getDevelopers();
    final targets = developers.where((d) => d.phone.isNotEmpty).toList();
    if (targets.isEmpty) return;
    final timestamp = DateFormat('dd-MM-yyyy HH:mm:ss').format(DateTime.parse(data.timestamp));
    final locationStr = data.lat != null && data.lon != null
        ? '$timestamp | Lat: ${data.lat}, Lon: ${data.lon}'
        : timestamp;
    final stackSanitized = _sanitizeTemplateParam(_trimStack(data.crashReport), maxLength: 700);
    final url = 'https://graph.facebook.com/v19.0/$phoneNumberId/messages';
    for (final dev in targets) {
      try {
        final phone = dev.phone.startsWith('0') ? '254${dev.phone.substring(1)}' : dev.phone;
        final parameters = [
          dev.fullName, data.appName, data.clientName, locationStr,
          data.deviceVersion, data.appVersion, data.deviceInfo, stackSanitized,
        ].map((v) => {'type': 'text', 'text': _sanitizeTemplateParam(v)}).toList();
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
        final request = await client.postUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
        request.headers
          ..set('Authorization', 'Bearer $token')
          ..set('Content-Type', 'application/json; charset=utf-8');
        request.add(utf8.encode(jsonEncode({
          'messaging_product': 'whatsapp',
          'to': phone,
          'type': 'template',
          'template': {
            'name': 'app_crash_report',
            'language': {'code': 'en'},
            'components': [{'type': 'body', 'parameters': parameters}],
          },
        })));
        final response = await request.close().timeout(const Duration(seconds: 10));
        await response.drain<void>();
        client.close(force: false);
        debugPrint('CrashReporter: WhatsApp Cloud sent to ${dev.fullName}');
      } catch (e) {
        debugPrint('CrashReporter: WhatsApp Cloud failed for ${dev.fullName} — $e');
      }
    }
  }

  static String _sanitizeTemplateParam(String value, {int maxLength = 0}) {
    final sanitized = value
        .replaceAll('\r\n', ' ').replaceAll('\n', ' ').replaceAll('\t', ' ')
        .replaceAll(RegExp(r' {4,}'), '   ').trim();
    if (maxLength > 0 && sanitized.length > maxLength) {
      return '${sanitized.substring(0, maxLength)}... [truncated]';
    }
    return sanitized.isEmpty ? 'N/A' : sanitized;
  }

  static Future<List<CrashDeveloper>> _getDevelopers() async {
    try {
      final dbDevs = await CrashDeveloperDao().getAll();
      if (dbDevs.isNotEmpty) return dbDevs;
    } catch (_) {}
    final fallback = _config!.developer;
    return [
      CrashDeveloper(
        fullName: fallback.name,
        phone: fallback.phone,
        email: fallback.email,
        appName: _config!.appName,
        appCode: _config!.appCode,
        clientName: _config!.clientName,
        telegramChatId: fallback.telegramChatId,
      ),
    ];
  }

  // ── Message builders ──────────────────────────────────────────────────────

  static String _esc(String s) => s
      .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  static String _buildTelegramMessage(_CrashData data) {
    final devName = _config!.developer.name;
    final org = _config!.organizationName.isEmpty ? 'CrashReporter' : _config!.organizationName;
    final trimmed = _trimStack(data.crashReport);
    final summary = _summarize(data.crashReport, data.errorMessage);
    var msg = '🚨 <b>Automatic Crash Alert — $org</b>\n\n'
        'Hi $devName, a crash was reported on your system.\n\n'
        '<b>📱 App</b>\n<code>${_esc(data.appName)}</code> — ${_esc(data.appVersion)}\n\n'
        '<b>👤 Client / User</b>\n${_esc(data.clientName)} / ${_esc(data.username)}\n\n'
        '<b>🕒 Time</b>\n${_esc(DateFormat('dd-MM-yyyy HH:mm:ss').format(DateTime.parse(data.timestamp)))}\n\n'
        '<b>📍 Location</b>\n${data.lat != null && data.lon != null ? '${data.lat}, ${data.lon}\nhttps://maps.google.com/?q=${data.lat},${data.lon}' : 'Check GPS!!'}\n\n'
        '<b>🔧 Device</b>\n${_esc(data.deviceInfo)} · ${_esc(data.deviceVersion)}\n\n'
        '<b>🐛 Where it crashed</b>\n${_esc(summary)}\n\n'
        '<b>Stack trace:</b>\n<pre>${_esc(trimmed)}</pre>';
    msg += '\n\n${_getPriorityEmoji(data.ticketPriority)} <b>Priority: ${data.ticketPriority.toUpperCase()}</b>';
    if (data.claudeAnalysis != null && data.claudeAnalysis!.isNotEmpty) {
      msg += '\n\n🤖 <b>Claude Analysis:</b>\n${_esc(data.claudeAnalysis!)}';
    }
    return msg;
  }

  static String _buildWhatsAppMessage(_CrashData data) {
    final devName = _config!.developer.name;
    final org = _config!.organizationName.isEmpty ? 'CrashReporter' : _config!.organizationName;
    final trimmed = _trimStack(data.crashReport);
    final summary = _summarize(data.crashReport, data.errorMessage);
    var msg = '🚨 Automatic Crash Alert — $org\n\n'
        'Hi $devName, a crash was reported on your system.\n\n'
        '📱 App\n${data.appName} — ${data.appVersion}\n\n'
        '👤 Client / User\n${data.clientName} / ${data.username}\n\n'
        '🕒 Time\n${DateFormat('dd-MM-yyyy HH:mm:ss').format(DateTime.parse(data.timestamp))}\n\n'
        '📍 Location\n${data.lat != null && data.lon != null ? '${data.lat}, ${data.lon}\nhttps://maps.google.com/?q=${data.lat},${data.lon}' : 'Check GPS!!'}\n\n'
        '🔧 Device\n${data.deviceInfo} · ${data.deviceVersion}\n\n'
        '🐛 Where it crashed\n$summary\n\n'
        'Stack trace:\n$trimmed';
    msg += '\n\n${_getPriorityEmoji(data.ticketPriority)} Priority: ${data.ticketPriority.toUpperCase()}';
    if (data.claudeAnalysis != null && data.claudeAnalysis!.isNotEmpty) {
      msg += '\n\n🤖 Claude Analysis:\n${data.claudeAnalysis}';
    }
    return msg;
  }

  static Future<void> _sendToEmail(_CrashData data) async {
    final cfg = _config!;
    if (cfg.smtpHost.isEmpty || cfg.smtpUsername.isEmpty || cfg.smtpPassword.isEmpty) {
      debugPrint('CrashReporter: Email skipped — SMTP credentials not configured');
      return;
    }
    try {
      final developers = await _getDevelopers();
      final targets = developers.where((d) => d.email.isNotEmpty).toList();
      if (targets.isEmpty) {
        debugPrint('CrashReporter: Email skipped — no developers with an email in DB');
        return;
      }
      final smtpServer = SmtpServer(cfg.smtpHost,
          port: cfg.smtpPort, username: cfg.smtpUsername, password: cfg.smtpPassword,
          ssl: false, ignoreBadCertificate: false);
      final org = cfg.organizationName.isEmpty ? 'Crash Reporter' : cfg.organizationName;
      final subject = 'Crash Report — ${data.appName} (${data.clientName})';
      final html = _buildEmailHtml(data, org);
      for (final dev in targets) {
        try {
          final message = Message()
            ..from = Address(cfg.smtpFromAddress.isEmpty ? cfg.smtpUsername : cfg.smtpFromAddress,
                cfg.smtpFromName.isEmpty ? org : cfg.smtpFromName)
            ..recipients.add(Address(dev.email, dev.fullName))
            ..subject = subject
            ..html = html;
          await send(message, smtpServer);
          debugPrint('CrashReporter: Email sent to ${dev.fullName} <${dev.email}>');
        } catch (e) {
          debugPrint('CrashReporter: Email failed for ${dev.fullName} — $e');
        }
      }
    } catch (e) {
      debugPrint('CrashReporter: Email send failed — $e');
    }
  }

  static String _buildEmailHtml(_CrashData data, String org) {
    final year = DateTime.now().year;
    final supportEmail = _config!.supportEmail;
    final summary = _summarize(data.crashReport, data.errorMessage);
    final trimmed = _trimStack(data.crashReport);
    final timestamp = DateFormat('dd-MM-yyyy HH:mm:ss').format(DateTime.parse(data.timestamp));
    final mapsUrl = data.lat != null && data.lon != null
        ? 'https://maps.google.com/?q=${data.lat},${data.lon}' : null;
    final safeStack = trimmed
        .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final priorityColor = _getPriorityColor(data.ticketPriority);
    final priorityBadge = '<span style="display:inline-block;padding:2px 10px;border-radius:12px;background:$priorityColor;color:#ffffff;font-size:12px;font-weight:700;">${data.ticketPriority}</span>';
    final claudeSection = (data.claudeAnalysis != null && data.claudeAnalysis!.isNotEmpty)
        ? '''<tr><td style="padding:16px 24px 16px;"><div style="border-radius:10px;overflow:hidden;"><div style="background:#064e3b;padding:12px 18px;font-size:13px;font-weight:700;color:#6ee7b7;letter-spacing:1px;text-transform:uppercase;">🤖 Claude Analysis</div><div style="background:#001f3f;padding:16px 18px;font-size:14px;color:#ffffff;line-height:22px;white-space:pre-wrap;">${data.claudeAnalysis}</div></div></td></tr>'''
        : '';
    return '''<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Crash Report</title></head><body style="margin:0;padding:0;background:#f4f6f8;font-family:Arial,Helvetica,sans-serif;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6f8;padding:24px 0;"><tr><td align="center"><table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:600px;max-width:600px;background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 6px 18px rgba(0,0,0,0.08);"><tr><td style="background:#cc0000;padding:20px 24px;"><div style="color:#ffffff;font-size:16px;font-weight:700;">${org.toUpperCase()}</div><div style="color:#ffd5d5;font-size:13px;margin-top:4px;">Crash Report Alert</div></td></tr><tr><td style="padding:24px 24px 0;"><div style="font-size:18px;font-weight:700;color:#111827;">🚨 A crash was detected</div><div style="font-size:14px;color:#374151;margin-top:10px;">System: <strong>${data.appName}</strong></div></td></tr><tr><td style="padding:16px 24px 0;"><div style="background:#f9fafb;border:1px solid #e5e7eb;border-radius:12px;padding:20px;"><div style="font-size:13px;color:#6b7280;text-transform:uppercase;margin-bottom:14px;font-weight:700;">Crash Details</div><table style="font-size:14px;color:#111827;line-height:24px;width:100%;" cellpadding="0" cellspacing="0"><tr><td style="color:#6b7280;padding-right:12px;white-space:nowrap;">📱 App</td><td>${_esc(data.appName)} — ${_esc(data.appVersion)}</td></tr><tr><td style="color:#6b7280;padding-right:12px;white-space:nowrap;">👤 Client / User</td><td>${_esc(data.clientName)} / ${_esc(data.username)}</td></tr><tr><td style="color:#6b7280;padding-right:12px;white-space:nowrap;">🕒 Time</td><td>${_esc(timestamp)}</td></tr><tr><td style="color:#6b7280;padding-right:12px;white-space:nowrap;">📍 Location</td><td>${mapsUrl != null ? '<a href="$mapsUrl" style="color:#cc0000;">${data.lat}, ${data.lon}</a>' : 'Check GPS!!'}</td></tr><tr><td style="color:#6b7280;padding-right:12px;white-space:nowrap;">🔧 Device</td><td>${_esc(data.deviceInfo)} · ${_esc(data.deviceVersion)}</td></tr><tr><td style="color:#6b7280;padding-right:12px;white-space:nowrap;">🎯 Priority</td><td>$priorityBadge</td></tr><tr><td colspan="2" style="padding:6px 0;"><hr style="border:none;border-top:1px solid #e5e7eb;margin:0;"></td></tr><tr><td style="color:#6b7280;padding-right:12px;white-space:nowrap;">🐛 Where it crashed:</td><td>${_esc(summary)}</td></tr></table></div></td></tr><tr><td style="padding:16px 24px 0;"><div style="border-radius:10px;overflow:hidden;"><div style="background:#001f3f;padding:12px 18px;font-size:13px;font-weight:700;color:#7eb8f7;text-transform:uppercase;">🐞 Stack Trace</div><pre style="margin:0;background:#001f3f;color:#e8f4ff;font-size:12px;line-height:20px;padding:16px 18px;white-space:pre-wrap;word-break:break-all;">$safeStack</pre></div></td></tr>$claudeSection<tr><td style="padding:16px 24px 0;"><div style="font-size:14px;color:#6b7280;">This report was automatically generated.</div><hr style="border:none;border-top:1px solid #e5e7eb;margin:16px 0;"><div style="font-size:12px;color:#6b7280;">Support: <a href="mailto:$supportEmail" style="color:#cc0000;">$supportEmail</a></div></td></tr><tr><td style="background:#f9fafb;padding:14px 24px;font-size:11px;color:#6b7280;">This is an automated message from $org.<br>&copy; $year $org. All rights reserved.</td></tr></table></td></tr></table></body></html>''';
  }

  static Future<String?> _fetchClaudeAnalysis(String crashSummary) async {
    final apiKey = _config!.claudeApiKey;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final request = await client
          .postUrl(Uri.parse('https://api.anthropic.com/v1/messages'))
          .timeout(const Duration(seconds: 20));
      request.headers
        ..set('x-api-key', apiKey)
        ..set('anthropic-version', '2023-06-01')
        ..set('anthropic-beta', 'prompt-caching-2024-07-31')
        ..set('content-type', 'application/json; charset=utf-8');
      final body = jsonEncode({
        'model': 'claude-haiku-4-5-20251001',
        'max_tokens': 512,
        'system': [
          {'type': 'text', 'text': _claudeSystemPrompt, 'cache_control': {'type': 'ephemeral'}}
        ],
        'messages': [
          {'role': 'user', 'content': 'Crash summary:\n\n$crashSummary'},
        ],
      });
      request.add(utf8.encode(body));
      final response = await request.close().timeout(const Duration(seconds: 20));
      final responseBody = await response.transform(utf8.decoder).join();
      client.close(force: false);
      if (response.statusCode == 200) {
        final json = jsonDecode(responseBody) as Map<String, dynamic>;
        final content = json['content'] as List<dynamic>;
        if (content.isNotEmpty) {
          final text = (content[0] as Map<String, dynamic>)['text'] as String;
          final usage = json['usage'] as Map<String, dynamic>?;
          debugPrint('CrashReporter: Claude analysis received. '
              'cache_read=${usage?['cache_read_input_tokens'] ?? 0} '
              'cache_write=${usage?['cache_creation_input_tokens'] ?? 0}');
          return text;
        }
      } else {
        debugPrint('CrashReporter: Claude API error — HTTP ${response.statusCode}: $responseBody');
      }
    } catch (e) {
      debugPrint('CrashReporter: Claude analysis failed — $e');
    }
    return null;
  }

  static String _extractPriority(String analysis) {
    for (final line in analysis.split('\n')) {
      final t = line.trim();
      if (t.toLowerCase().startsWith('priority:')) {
        final val = t.substring(9).trim().toLowerCase();
        if (val.contains('critical')) return 'Critical';
        if (val.contains('high'))     return 'High';
        if (val.contains('medium'))   return 'Medium';
        if (val.contains('low'))      return 'Low';
      }
    }
    return 'Unknown';
  }

  static String _stripPriorityLine(String analysis) {
    final parts = analysis.split('\n');
    if (parts.isNotEmpty && parts[0].trim().toLowerCase().startsWith('priority:')) {
      return parts.length > 1 ? parts.sublist(1).join('\n').trim() : '';
    }
    return analysis;
  }

  static String _getPriorityEmoji(String priority) {
    switch (priority.toLowerCase()) {
      case 'critical': return '🔴';
      case 'high':     return '🟠';
      case 'medium':   return '🟡';
      case 'low':      return '🟢';
      default:         return '⚪';
    }
  }

  static String _getPriorityColor(String priority) {
    switch (priority.toLowerCase()) {
      case 'critical': return '#dc2626';
      case 'high':     return '#ea580c';
      case 'medium':   return '#d97706';
      case 'low':      return '#16a34a';
      default:         return '#6b7280';
    }
  }

  static String _summarize(String stackTrace, String error) {
    final appCode = _config?.appCode ?? '';
    final lines = stackTrace.split('\n');
    for (final line in lines) {
      final t = line.trim();
      if (appCode.isNotEmpty && t.contains('package:$appCode')) return '$t — $error';
    }
    return lines.isNotEmpty ? '${lines[0].trim()} — $error' : error;
  }

  static String _trimStack(String stackTrace) {
    final lines = stackTrace.split('\n');
    const limit = 15;
    if (lines.length <= limit) return stackTrace;
    return '${lines.take(limit).join('\n')}\n... ${lines.length - limit} more lines';
  }
}

class _CrashData {
  final String appName, appCode, clientName, timestamp, deviceVersion,
      appVersion, deviceInfo, crashReport, errorMessage, username, ticketPriority;
  final double? lat, lon;
  final String? claudeAnalysis;

  const _CrashData({
    required this.appName, required this.appCode, required this.clientName,
    required this.timestamp, required this.deviceVersion, required this.appVersion,
    required this.deviceInfo, required this.crashReport, required this.errorMessage,
    required this.username, required this.ticketPriority,
    this.lat, this.lon, this.claudeAnalysis,
  });
}