class CrashReporterDeveloper {
  final String name;
  final String phone;
  final String email;
  final String telegramChatId;

  const CrashReporterDeveloper({
    required this.name,
    required this.phone,
    required this.email,
    required this.telegramChatId,
  });
}

class CrashReporterConfig {
  final String appName;
  final String appCode;
  final String clientName;
  final Future<String> Function()? clientNameProvider;
  final CrashReporterDeveloper developer;
  final String usernamePrefsKey;

  // ── Channel flags ──────────────────────────────────────────────────────────
  final bool enableCrashTicket;
  final bool enableTelegram;
  final bool enableMaytapi;
  final bool enableWhatsAppCloud;
  final bool enableEmail;
  final bool enableClaudeAnalysis;

  // ── Endpoints & credentials ────────────────────────────────────────────────
  final String crashTicketEndpoint;
  final String telegramBotToken;
  final String maytapiProductId;
  final String maytapiPhoneId;
  final String maytapiApiKey;
  final String whatsappToken;
  final String whatsappPhoneNumberId;
  final String claudeApiKey;

  // ── SMTP ───────────────────────────────────────────────────────────────────
  final String smtpHost;
  final int smtpPort;
  final String smtpUsername;
  final String smtpPassword;
  final String smtpFromAddress;
  final String smtpFromName;
  final String organizationName;
  final String supportEmail;

  const CrashReporterConfig({
    required this.appName,
    required this.appCode,
    required this.clientName,
    required this.developer,
    required this.telegramBotToken,
    required this.maytapiProductId,
    required this.maytapiPhoneId,
    required this.maytapiApiKey,
    this.clientNameProvider,
    this.usernamePrefsKey = 'username',
    this.enableCrashTicket = true,
    this.enableTelegram = true,
    this.enableMaytapi = true,
    this.enableWhatsAppCloud = false,
    this.whatsappToken = '',
    this.whatsappPhoneNumberId = '',
    this.enableEmail = false,
    this.smtpHost = '',
    this.smtpPort = 587,
    this.smtpUsername = '',
    this.smtpPassword = '',
    this.smtpFromAddress = '',
    this.smtpFromName = '',
    this.organizationName = '',
    this.supportEmail = '',
    this.enableClaudeAnalysis = false,
    this.claudeApiKey = '',
    this.crashTicketEndpoint =""
  });
}