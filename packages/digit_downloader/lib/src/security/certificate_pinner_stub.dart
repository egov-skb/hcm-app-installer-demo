import 'package:http/http.dart' as http;

import '../models/cert_pin.dart';

/// Web has no raw socket access, so TLS pinning is a documented no-op here —
/// the browser's own TLS validation is used as-is.
http.Client createPinnedClient(CertificatePinSet? pins) => http.Client();
