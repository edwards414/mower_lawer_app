class RemoteAccessConfig {
  const RemoteAccessConfig._();

  static const _cloudflareAccessClientId = String.fromEnvironment(
    'CF_ACCESS_CLIENT_ID',
  );
  static const _cloudflareAccessClientSecret = String.fromEnvironment(
    'CF_ACCESS_CLIENT_SECRET',
  );

  static Map<String, String> get cloudflareAccessHeaders {
    if (_cloudflareAccessClientId.isEmpty ||
        _cloudflareAccessClientSecret.isEmpty) {
      return const {};
    }
    return {
      'CF-Access-Client-Id': _cloudflareAccessClientId,
      'CF-Access-Client-Secret': _cloudflareAccessClientSecret,
    };
  }
}
