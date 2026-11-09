import 'json.dart';

enum UserRole {
  student,
  driver,
  admin;

  static UserRole parse(String value) =>
      values.firstWhere((r) => r.name == value);
}

/// The bus linked to a driver (`GET /me` → `bus`).
class UserBus {
  const UserBus({
    required this.id,
    required this.label,
    required this.plate,
    required this.defaultRouteId,
  });

  factory UserBus.fromJson(Json json) => UserBus(
    id: json['id'] as String,
    label: json['label'] as String,
    plate: json['plate'] as String,
    defaultRouteId: json['default_route_id'] as String?,
  );

  final String id;
  final String label;
  final String plate;
  final String? defaultRouteId;
}

/// `GET /me` and the `user` in sign-in responses.
class AppUser {
  const AppUser({
    required this.id,
    required this.role,
    required this.name,
    required this.email,
    required this.phone,
    required this.createdAt,
    this.bus,
  });

  factory AppUser.fromJson(Json json) => AppUser(
    id: json['id'] as String,
    role: UserRole.parse(json['role'] as String),
    name: json['name'] as String,
    email: json['email'] as String?,
    phone: json['phone'] as String?,
    createdAt: parseTime(json['created_at']),
    bus: json['bus'] == null ? null : UserBus.fromJson(json['bus'] as Json),
  );

  final String id;
  final UserRole role;
  final String name;
  final String? email;
  final String? phone;
  final DateTime createdAt;

  /// Drivers only.
  final UserBus? bus;
}

/// `POST /auth/google` and `POST /auth/phone/verify`.
class AuthTokens {
  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  });

  factory AuthTokens.fromJson(Json json) => AuthTokens(
    accessToken: json['access_token'] as String,
    refreshToken: json['refresh_token'] as String,
    user: AppUser.fromJson(json['user'] as Json),
  );

  final String accessToken;
  final String refreshToken;
  final AppUser user;
}

/// `POST /auth/login` response: the tokens plus the temporary-password flag.
class LoginResult {
  const LoginResult({required this.tokens, required this.mustChangePassword});

  factory LoginResult.fromJson(Json json) => LoginResult(
    tokens: AuthTokens.fromJson(json),
    mustChangePassword: json['must_change_password'] as bool? ?? false,
  );

  final AuthTokens tokens;
  final bool mustChangePassword;
}
