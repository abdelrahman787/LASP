import 'package:firebase_auth/firebase_auth.dart';

/// Minimal user identity the app cares about.
class AppUser {
  final String uid;
  final String? email;
  const AppUser(this.uid, this.email);
}

/// Auth abstraction so the app gates on a stream and tests can inject a fake
/// without touching Firebase.
abstract class AuthService {
  Stream<AppUser?> authState();
  AppUser? get current;

  Future<void> signIn(String email, String password);
  Future<void> register(String email, String password);
  Future<void> signOut();

  /// Firebase ID token for the ASR Worker's `Authorization: Bearer` header.
  Future<String?> idToken();
}

/// Real Firebase Auth implementation (email/password).
class FirebaseAuthService implements AuthService {
  final FirebaseAuth _auth;
  FirebaseAuthService([FirebaseAuth? auth])
      : _auth = auth ?? FirebaseAuth.instance;

  AppUser? _map(User? u) => u == null ? null : AppUser(u.uid, u.email);

  @override
  Stream<AppUser?> authState() => _auth.authStateChanges().map(_map);

  @override
  AppUser? get current => _map(_auth.currentUser);

  @override
  Future<void> signIn(String email, String password) =>
      _auth.signInWithEmailAndPassword(email: email, password: password);

  @override
  Future<void> register(String email, String password) =>
      _auth.createUserWithEmailAndPassword(email: email, password: password);

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<String?> idToken() async => _auth.currentUser?.getIdToken();
}

/// In-memory auth for tests / offline dev. Starts signed-out unless [signedIn].
class FakeAuthService implements AuthService {
  AppUser? _user;
  FakeAuthService({bool signedIn = false})
      : _user = signedIn ? const AppUser('fake-uid', 'fake@test.dev') : null;

  @override
  Stream<AppUser?> authState() => Stream.value(_user);

  @override
  AppUser? get current => _user;

  @override
  Future<void> signIn(String email, String password) async {
    _user = AppUser('fake-uid', email);
  }

  @override
  Future<void> register(String email, String password) async {
    _user = AppUser('fake-uid', email);
  }

  @override
  Future<void> signOut() async => _user = null;

  @override
  Future<String?> idToken() async => _user == null ? null : 'fake-token';
}
