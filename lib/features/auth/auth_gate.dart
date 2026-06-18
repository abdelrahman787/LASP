import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../shell/home_shell.dart';
import 'login_screen.dart';

/// Routes to the dashboard when signed in, the login screen otherwise.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authStateProvider);
    return auth.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('خطأ: $e'))),
      data: (user) =>
          user == null ? const LoginScreen() : const HomeShell(),
    );
  }
}
