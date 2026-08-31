import 'package:http/http.dart' as http;

import 'whep_http_client_factory_default.dart'
    if (dart.library.js_interop) 'whep_http_client_factory_web.dart'
    as platform;

http.Client createWhepHttpClient() => platform.createWhepHttpClient();
