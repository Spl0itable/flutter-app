import 'dart:io';

import 'api_config.dart';

class NymHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..userAgent = ApiConfig.userAgent;
}
