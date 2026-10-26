import 'dart:convert';

// Throwaway RSA key generated only for these tests. It was never registered
// with Google, so it grants access to nothing.
const testPrivateKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQDKltx9kZH/flVE
ePkYTh4qRZU9Mx/FdoS/xYQcuz1z8SB0g88Z751DXh4vr5m1U7PAIxAM4svQNuJe
lJu2V1/XBsGJlDbU7z24M6IBxXxiBOVXELRJzv8H/IxdSnA2fBedDJUXEBfb7Lqz
AuTJeCPi/AJdjkljWSqxsziBCvcPUYH9k7JpkSeI99EkixPH9ojaIFcFuE4aH+2Y
rLZaOfp4vN2qRwqWvpk3Fc+5C+jYJmF60aByDs/quBqlrJqxRCmgs5fOa6kufuF5
0aOiMj6shjZbcgwc3Xdc0zp3lI0OkmaYu51Nr9saw87NkQ5jlNTUcKKrgNYqBYvd
PfPWgE9fAgMBAAECggEAHY7HlRMv8SN5BFhUG5g2LXu2gQCHB6k5nWiPfx5Qd9c7
9tP5BkiKsja2rRrFOzVUT1muRfsHD+tvZADxpmJ2y2l4blQaGz+Gn+v58faNexhK
GnBc+ucrws9gRAeQJLA+mmgouSiHb/Zzl5pPUBe/wKZ9H9zv1yy+HmwkIoEQ4oKC
ylppuAhHgVkbGkkpM5p1eubP3Cj2Af/TMzAk3GisuQkViN1NvCgaxi/j7gpFqRKc
6GoB3vSXomb+jSQC2DDqe7Bsu5Q5yh1l6MvrYGzWfaNWVYgFvHTq3GHlQn/OX0TI
HCYwfAft5i6ULMrnTifK3WmnVEjR1fUdMikIl0by/QKBgQDywswGU7LPtTMQ/j6/
gL5T5VmNDHtoHoHr46ZVpPPwM8JFm6jmbwAdbjOEU8dM+UmzcthPcqG49RBZkXlh
lKsSkBAPz6IsIlkOuCw9oRsnLOeQKdN1KRv2z4dV7zGC3aiartSvF1JCYjjOSj7V
3fa5vKPbHCCvO3gUtYPlFYmkjQKBgQDVozmwIlO1/mbZhSA79zHlJRFAWOBP/fgD
NMEx2o8D/7jWXAg0ZzNdBymo2VZgWodT4YMbAZ44a/HBnqNASA/HkFugDiWi14rg
sg9O6F5QogqJYWwY6xc1L8DWmsmDSvIs4Plh7cOCoUzP2O0UCsDRDiyrfFO2dses
zRf62l/mmwKBgAm0d+uY1QEwwUXgpCmLwBAijx3wbc6Pyangg/nQimAD8bROsMXl
kh+bFDwqDUGqhaPC55rlfkmionCyPCQGiYBIehvntRgGl4DbJAmisy8xwGAnC+kX
J6MKUOLCmTweGGt2qdIGIKe+vX6hwTlTklWCkRplWXkn63kIeKlj3wjRAoGAXyj9
oT8pGn/fQDTUTuGlD/Sa4pa0E+2Ec6kkBRjda2KU6qbD4NO3RVDTdaqZlwG8Fdj1
lSn7WBZ88UnAXfm7TaE3ruueSBLKgZvOxc8rc686Ekea5t6Qz9gdhXodGKZhiSwM
6VoHJEDE/jAaKjs/997gduJCR5xRBN+2Nr7eyNECgYByp+MvFgKEBStaBlsLLZNC
F7CvSYPjsKX+eNSpbriVqahuPxLjvyz77aSbFQ6EKalWfML+Jrqujac2U1hLtEFN
lmW8HU9bcJOz/WeyVjO9c6k6/VsWz1nWIX4S/UM+jXlChP2M9W9AzOg2FhNU2+/n
pXxQzGJOxZQFRX4iKi19wg==
-----END PRIVATE KEY-----
''';


/// A service-account key file as downloaded from Google Cloud (fake values).
String credentialsJson({
  String email = 'mailer@proj-123.iam.gserviceaccount.com',
  Map<String, Object?> override = const {},
  List<String> without = const [],
}) {
  final m = <String, Object?>{
    'type': 'service_account',
    'project_id': 'proj-123',
    'private_key_id': 'abcdef0123456789',
    'private_key': testPrivateKeyPem,
    'client_email': email,
    'client_id': '123456789012345678901',
    'auth_uri': 'https://accounts.google.com/o/oauth2/auth',
    'token_uri': 'https://oauth2.googleapis.com/token',
    ...override,
  };
  for (final k in without) {
    m.remove(k);
  }
  return jsonEncode(m);
}
