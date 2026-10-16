import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../player/app_player.dart';
import '../player/mini_player.dart';
import '../ui/glass.dart';
import '../ui/theme.dart';

const pinMinLength = 4;
const pinMaxLength = 8;

/// The app-lock PIN lives in the OS credential store as a salted SHA-256
/// hash; the PIN itself is never stored.
class PinStore {
  PinStore([FlutterSecureStorage? s]) : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _key = 'app_lock_pin';

  Future<bool> isSet() async => (await _s.read(key: _key)) != null;

  Future<void> set(String pin) {
    final r = Random.secure();
    final salt = base64Encode(List.generate(16, (_) => r.nextInt(256)));
    return _s.write(key: _key, value: '$salt:${_hash(salt, pin)}');
  }

  Future<bool> verify(String pin) async {
    final stored = await _s.read(key: _key);
    if (stored == null) return false;
    final sep = stored.indexOf(':');
    if (sep <= 0) return false;
    return _hash(stored.substring(0, sep), pin) == stored.substring(sep + 1);
  }

  Future<void> clear() => _s.delete(key: _key);

  static String _hash(String salt, String pin) => sha256.convert(utf8.encode('$salt$pin')).toString();
}

final pinStoreProvider = Provider<PinStore>((_) => PinStore());

/// Overridden in main() with whether a PIN was set at start-up.
final initialPinSetProvider = Provider<bool>((_) => false);

class AppLockState {
  const AppLockState({required this.enabled, required this.locked, this.everUnlocked = false});
  final bool enabled;
  final bool locked;

  /// The app UI is only built after the first unlock, so nothing (autoplay,
  /// playlist refresh) runs behind the lock screen at start-up.
  final bool everUnlocked;
}

class AppLockController extends Notifier<AppLockState> {
  int _failures = 0;
  DateTime _blockedUntil = DateTime(0);

  @override
  AppLockState build() {
    final enabled = ref.read(initialPinSetProvider);
    return AppLockState(enabled: enabled, locked: enabled, everUnlocked: !enabled);
  }

  PinStore get _store => ref.read(pinStoreProvider);

  /// Time left before another attempt is allowed (after repeated failures).
  Duration get cooldown {
    final d = _blockedUntil.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  /// Checks [pin], counting failures: after 5 wrong tries every further
  /// attempt (here or in Settings) has to wait a growing cooldown.
  Future<bool> verify(String pin) async {
    if (cooldown > Duration.zero) return false;
    if (await _store.verify(pin)) {
      _failures = 0;
      return true;
    }
    if (++_failures >= 5) {
      _blockedUntil = DateTime.now().add(Duration(seconds: 30 * (_failures - 4)));
    }
    return false;
  }

  Future<bool> unlock(String pin) async {
    if (!await verify(pin)) return false;
    state = const AppLockState(enabled: true, locked: false, everUnlocked: true);
    return true;
  }

  Future<void> enable(String pin) async {
    await _store.set(pin);
    state = const AppLockState(enabled: true, locked: false, everUnlocked: true);
  }

  Future<void> disable() async {
    await _store.clear();
    state = const AppLockState(enabled: false, locked: false, everUnlocked: true);
  }

  Future<void> lockNow() async {
    if (!state.enabled) return;
    await ref.read(appPlayerProvider).player.pause();
    await MiniMode.exit();
    state = AppLockState(enabled: true, locked: true, everUnlocked: state.everUnlocked);
  }
}

final appLockProvider = NotifierProvider<AppLockController, AppLockState>(AppLockController.new);

/// Wraps the whole app and covers it with the PIN screen while locked.
class AppLockGate extends ConsumerWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appLockProvider);
    return Stack(fit: StackFit.expand, children: [
      if (s.everUnlocked)
        Offstage(offstage: s.locked, child: TickerMode(enabled: !s.locked, child: child)),
      if (s.locked) const _LockScreen(),
    ]);
  }
}

class _LockScreen extends ConsumerStatefulWidget {
  const _LockScreen();
  @override
  ConsumerState<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<_LockScreen> {
  final _focus = FocusNode(debugLabel: 'lock-screen');
  String _pin = '';
  String? _error;
  bool _checking = false;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _digit(String d) {
    if (_checking || _pin.length >= pinMaxLength) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == pinMaxLength) _submit();
  }

  void _backspace() {
    if (_checking || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_checking || _pin.length < pinMinLength) return;
    final lock = ref.read(appLockProvider.notifier);
    setState(() => _checking = true);
    final ok = await lock.unlock(_pin);
    if (!mounted || ok) return;
    setState(() {
      _checking = false;
      _pin = '';
      _error = 'Wrong PIN';
    });
    _showCooldown();
  }

  void _showCooldown() {
    final lock = ref.read(appLockProvider.notifier);
    if (lock.cooldown == Duration.zero) return;
    _cooldownTimer?.cancel();
    void tick() {
      final left = lock.cooldown;
      if (!mounted) return;
      setState(() => _error = left == Duration.zero ? null : 'Too many attempts. Try again in ${left.inSeconds + 1} s');
      if (left == Duration.zero) _cooldownTimer?.cancel();
    }

    tick();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final ch = e.character;
    if (ch != null && ch.length == 1 && '0123456789'.contains(ch)) {
      _digit(ch);
    } else if (k == LogicalKeyboardKey.backspace) {
      _backspace();
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _submit();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Material(
      type: MaterialType.transparency,
      child: AppBackdrop(
        hero: true,
          child: Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: GestureDetector(
            onTap: _focus.requestFocus,
            behavior: HitTestBehavior.opaque,
            child: SafeArea(
              child: Center(
              child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Image.asset('assets/brand/mark.png', width: 64, height: 64, filterQuality: FilterQuality.medium),
                const SizedBox(height: 20),
                Text('Enter PIN', style: t.headlineSmall),
                const SizedBox(height: 24),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  for (var i = 0; i < max(pinMinLength, _pin.length); i++)
                    Container(
                      width: 14,
                      height: 14,
                      margin: const EdgeInsets.symmetric(horizontal: 7),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _pin.length ? AppColors.accent : Colors.transparent,
                        border: Border.all(color: i < _pin.length ? AppColors.accent : AppColors.textDim),
                      ),
                    ),
                ]),
                SizedBox(
                  height: 40,
                  child: Center(
                    child: Text(_error ?? '', style: const TextStyle(color: AppColors.live)),
                  ),
                ),
                _Keypad(onDigit: _digit, onBackspace: _backspace, onSubmit: _submit),
              ].animate(interval: 50.ms).fadeIn(duration: 400.ms).slideY(begin: 0.1)),
              ),
              ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onBackspace, required this.onSubmit});
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onSubmit;

  Widget _key(Widget label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 72,
          height: 72,
          child: Material(
            color: AppColors.glass,
            shape: const CircleBorder(side: BorderSide(color: AppColors.glassBorder)),
            child: InkWell(
              customBorder: const CircleBorder(),
              canRequestFocus: false,
              onTap: onTap,
              child: Center(child: label),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    Widget digit(String d) => _key(Text(d, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w300)), () => onDigit(d));
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
        Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) digit(d)]),
      Row(mainAxisSize: MainAxisSize.min, children: [
        _key(const Icon(Icons.backspace_outlined, color: AppColors.textSoft), onBackspace),
        digit('0'),
        _key(const Icon(Icons.arrow_forward, color: AppColors.accent), onSubmit),
      ]),
    ]);
  }
}

/// Asks for a new PIN twice. Returns the PIN, or null if cancelled.
Future<String?> showSetPinDialog(BuildContext context, {String title = 'Set PIN'}) =>
    showDialog<String>(context: context, builder: (_) => _SetPinDialog(title: title));

/// Asks for the current PIN. Returns true if it was entered correctly.
Future<bool> showVerifyPinDialog(BuildContext context, {String title = 'Enter current PIN'}) async =>
    await showDialog<bool>(context: context, builder: (_) => _VerifyPinDialog(title: title)) ?? false;

class _PinField extends StatelessWidget {
  const _PinField({required this.controller, required this.label, this.autofocus = false, this.onSubmitted});
  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        autofocus: autofocus,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: pinMaxLength,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: label, counterText: ''),
        onSubmitted: onSubmitted,
      );
}

class _SetPinDialog extends StatefulWidget {
  const _SetPinDialog({required this.title});
  final String title;
  @override
  State<_SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<_SetPinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _save() {
    final pin = _pin.text;
    if (pin.length < pinMinLength) {
      setState(() => _error = 'PIN must be $pinMinLength–$pinMaxLength digits');
    } else if (pin != _confirm.text) {
      setState(() => _error = 'PINs do not match');
    } else {
      Navigator.pop(context, pin);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _PinField(controller: _pin, label: 'New PIN ($pinMinLength–$pinMaxLength digits)', autofocus: true),
            const SizedBox(height: 12),
            _PinField(controller: _confirm, label: 'Confirm PIN', onSubmitted: (_) => _save()),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: AppColors.live)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      );
}

class _VerifyPinDialog extends ConsumerStatefulWidget {
  const _VerifyPinDialog({required this.title});
  final String title;
  @override
  ConsumerState<_VerifyPinDialog> createState() => _VerifyPinDialogState();
}

class _VerifyPinDialogState extends ConsumerState<_VerifyPinDialog> {
  final _pin = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final ok = await ref.read(appLockProvider.notifier).verify(_pin.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
      return;
    }
    final wait = ref.read(appLockProvider.notifier).cooldown;
    setState(() => _error =
        wait > Duration.zero ? 'Too many attempts. Try again in ${wait.inSeconds + 1} s' : 'Wrong PIN');
    _pin.clear();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _PinField(controller: _pin, label: 'PIN', autofocus: true, onSubmitted: (_) => _check()),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: AppColors.live)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: _check, child: const Text('OK')),
        ],
      );
}
