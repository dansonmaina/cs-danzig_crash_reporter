class CrashDeveloper {
  final int? id;
  final String fullName;
  final String phone;
  final String email;
  final String appName;
  final String appCode;
  final String clientName;
  final String telegramChatId;
  final String syncStatus;

  const CrashDeveloper({
    this.id,
    required this.fullName,
    required this.phone,
    required this.email,
    required this.appName,
    required this.appCode,
    required this.clientName,
    this.telegramChatId = '',
    this.syncStatus = 'synced',
  });

  CrashDeveloper copyWith({String? telegramChatId}) => CrashDeveloper(
        id: id,
        fullName: fullName,
        phone: phone,
        email: email,
        appName: appName,
        appCode: appCode,
        clientName: clientName,
        telegramChatId: telegramChatId ?? this.telegramChatId,
        syncStatus: syncStatus,
      );

  factory CrashDeveloper.fromMap(Map<String, dynamic> map) => CrashDeveloper(
        id: map['id'] as int?,
        fullName: map['full_name'] as String? ?? '',
        phone: map['phone'] as String? ?? '',
        email: map['email'] as String? ?? '',
        appName: map['app_name'] as String? ?? '',
        appCode: map['app_code'] as String? ?? '',
        clientName: map['client_name'] as String? ?? '',
        telegramChatId: map['telegram_chat_id'] as String? ?? '',
        syncStatus: map['sync_status'] as String? ?? 'synced',
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'full_name': fullName,
        'phone': phone,
        'email': email,
        'app_name': appName,
        'app_code': appCode,
        'client_name': clientName,
        'telegram_chat_id': telegramChatId,
        'sync_status': syncStatus,
      };
}