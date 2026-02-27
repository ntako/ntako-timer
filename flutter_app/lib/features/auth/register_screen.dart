import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'auth_notifier.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _emailCtrl       = TextEditingController();
  final _passCtrl        = TextEditingController();
  final _passConfirmCtrl = TextEditingController();
  bool   _obscure        = true;
  String? _localError;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _passConfirmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authAsync = ref.watch(authNotifierProvider);
    final isLoading = authAsync.isLoading;

    ref.listen(authNotifierProvider, (_, next) {
      if (next.valueOrNull?.status == AuthStatus.authenticated) {
        context.go('/timer');
      }
    });

    final errorText = _localError ?? (authAsync.hasError ? authAsync.error.toString() : null);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Registrati'),
        leading: BackButton(onPressed: () => context.go('/login')),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 32),
            TextField(
              controller: _emailCtrl,
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.email_outlined),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) => setState(() => _localError = null),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passCtrl,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Password (min 8 caratteri)',
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onChanged: (_) => setState(() => _localError = null),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passConfirmCtrl,
              obscureText: _obscure,
              decoration: const InputDecoration(
                labelText: 'Conferma password',
                prefixIcon: Icon(Icons.lock_outline),
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() => _localError = null),
            ),
            if (errorText != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  errorText,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: isLoading ? null : _register,
                child: isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Crea account'),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => context.go('/login'),
              child: const Text('Hai già un account? Accedi'),
            ),
          ],
        ),
      ),
    );
  }

  void _register() {
    final email = _emailCtrl.text.trim();
    final pass  = _passCtrl.text;
    final conf  = _passConfirmCtrl.text;

    if (email.isEmpty || pass.isEmpty || conf.isEmpty) return;

    if (pass.length < 8) {
      setState(() => _localError = 'La password deve essere di almeno 8 caratteri');
      return;
    }

    if (pass != conf) {
      setState(() => _localError = 'Le password non coincidono');
      return;
    }

    setState(() => _localError = null);
    ref.read(authNotifierProvider.notifier).register(email, pass);
  }
}
