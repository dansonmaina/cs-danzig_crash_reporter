class TelegramUser {
  final int? id;
  final String telegramChatId;
  final String firstName;
  final String lastName;
  final String username;
  final String languageCode;
  final String syncStatus;

  const TelegramUser({
    this.id,
    required this.telegramChatId,
    required this.firstName,
    this.lastName = '',
    this.username = '',
    this.languageCode = 'en',
    this.syncStatus = 'pending',
  });

  factory TelegramUser.fromMap(Map<String, dynamic> map) => TelegramUser(
        id: map['id'] as int?,
        telegramChatId: map['telegram_chat_id'] as String? ?? '',
        firstName: map['first_name'] as String? ?? '',
        lastName: map['last_name'] as String? ?? '',
        username: map['username'] as String? ?? '',
        languageCode: map['language_code'] as String? ?? 'en',
        syncStatus: map['sync_status'] as String? ?? 'pending',
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'telegram_chat_id': telegramChatId,
        'first_name': firstName,
        'last_name': lastName,
        'username': username,
        'language_code': languageCode,
        'sync_status': syncStatus,
      };
}