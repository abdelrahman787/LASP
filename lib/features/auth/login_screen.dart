import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/widgets/glass.dart';

/// Email/password register + login (Backend Phase 1). The [AuthGate] swaps to
/// the dashboard automatically once `authStateChanges` emits a user.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _isRegister = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = ref.read(authServiceProvider);
      final email = _email.text.trim();
      final pass = _password.text;
      if (_isRegister) {
        await auth.register(email, pass);
      } else {
        await auth.signIn(email, pass);
      }
      // AuthGate reacts to the auth-state stream; nothing else to do.
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _friendly(e.code));
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'البريد مُستخدم بالفعل.';
      case 'invalid-email':
        return 'بريد إلكتروني غير صالح.';
      case 'weak-password':
        return 'كلمة المرور ضعيفة (٦ أحرف على الأقل).';
      case 'wrong-password':
      case 'invalid-credential':
        return 'بيانات الدخول غير صحيحة.';
      case 'user-not-found':
        return 'لا يوجد حساب بهذا البريد.';
      default:
        return 'تعذّر إتمام العملية ($code).';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('قرآن تسميع')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: GlassCard(
              padding: const EdgeInsets.all(24),
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.menu_book_rounded,
                    size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(_isRegister ? 'إنشاء حساب' : 'تسجيل الدخول',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center),
                const SizedBox(height: 24),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'البريد الإلكتروني',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: TextStyle(color: theme.colorScheme.error),
                      textAlign: TextAlign.center),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_isRegister ? 'إنشاء حساب' : 'دخول'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _isRegister = !_isRegister),
                  child: Text(_isRegister
                      ? 'لديك حساب؟ سجّل الدخول'
                      : 'ليس لديك حساب؟ أنشئ واحدًا'),
                ),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }
}
