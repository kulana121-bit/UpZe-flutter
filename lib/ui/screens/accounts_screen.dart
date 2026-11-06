// Accounts & servers screen (Kotlin: ui/settings/SourcesPage.kt +
// ui/account/SignIn.kt).
//
// One form per service, all persisted through the injected
// [AccountsStore]:
//  * Subsonic / Navidrome — server URL + user + password, Save and a
//    Test button (the host's [AccountsScreen.testSubsonic] builds a
//    SubsonicSource from the saved account and pings it; the current
//    field values are saved before testing, so what you see is what is
//    tested).
//  * Jellyfin — server + user + password exchanged for an access token
//    through the host's [AccountsScreen.jellyfinLogin] (JellyfinSource
//    .login); only the resulting JellyfinConfig (server, userId, token)
//    is stored, never the password.
//  * Spotify — the sp_dc cookie (Spotify has no password login in UpZe;
//    without the cookie it stays signed out and simply never matches).
//  * Jamendo — the free developer client_id.
//
// Honest storage note, also shown in the UI: everything here is kept
// only in UpZe's private app folder on this phone (accounts.json) and
// is sent only to the server/service it belongs to.

import 'package:flutter/material.dart' hide ThemeMode;

import '../../data/accounts_store.dart';
import '../../sources/servers_source.dart';

class AccountsScreen extends StatefulWidget {
  const AccountsScreen({
    super.key,
    required this.accounts,
    required this.testSubsonic,
    required this.testJellyfin,
    required this.jellyfinLogin,
  });

  final AccountsStore accounts;

  /// Ping the saved Subsonic account; true = reachable + authorised.
  final Future<bool> Function() testSubsonic;

  /// Ping the saved Jellyfin account; true = reachable + authorised.
  final Future<bool> Function() testJellyfin;

  /// Exchange Jellyfin server/user/password for a stored config;
  /// null = login failed.
  final Future<JellyfinConfig?> Function(
      String server, String user, String password) jellyfinLogin;

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  AccountsStore get _accounts => widget.accounts;

  late final TextEditingController _subUrl;
  late final TextEditingController _subUser;
  late final TextEditingController _subPass;
  late final TextEditingController _jfServer;
  late final TextEditingController _jfUser;
  late final TextEditingController _jfPass;
  late final TextEditingController _spotify;
  late final TextEditingController _jamendo;

  String? _subStatus;
  String? _jfStatus;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _accounts.addListener(_onChange);
    final sub = _accounts.subsonic;
    _subUrl = TextEditingController(text: sub?.baseUrl ?? '');
    _subUser = TextEditingController(text: sub?.user ?? '');
    _subPass = TextEditingController(text: sub?.password ?? '');
    _jfServer = TextEditingController();
    _jfUser = TextEditingController();
    _jfPass = TextEditingController();
    _spotify = TextEditingController(text: _accounts.spotifyCookie ?? '');
    _jamendo = TextEditingController(text: _accounts.jamendoClientId ?? '');
  }

  @override
  void dispose() {
    _accounts.removeListener(_onChange);
    for (final c in [
      _subUrl,
      _subUser,
      _subPass,
      _jfServer,
      _jfUser,
      _jfPass,
      _spotify,
      _jamendo,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---- Subsonic -------------------------------------------------------------

  void _saveSubsonic() {
    final url = _subUrl.text.trim();
    final user = _subUser.text.trim();
    final pass = _subPass.text;
    if (url.isEmpty && user.isEmpty && pass.isEmpty) {
      _accounts.setSubsonic(null);
      setState(() => _subStatus = 'Removed.');
      return;
    }
    _accounts.setSubsonic(
        SubsonicConfig(baseUrl: url, user: user, password: pass));
    setState(() => _subStatus = 'Saved.');
  }

  Future<void> _testSubsonic() async {
    _saveSubsonic();
    if (_accounts.subsonic == null) {
      setState(() => _subStatus = 'Fill the server, user and password first.');
      return;
    }
    setState(() {
      _busy = true;
      _subStatus = 'Testing…';
    });
    final ok = await widget.testSubsonic();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _subStatus = ok ? 'Connected — server answered.' : 'Could not connect.';
    });
  }

  // ---- Jellyfin -------------------------------------------------------------

  Future<void> _loginJellyfin() async {
    final server = _jfServer.text.trim();
    final user = _jfUser.text.trim();
    final pass = _jfPass.text;
    if (server.isEmpty || user.isEmpty) {
      setState(() => _jfStatus = 'Fill the server and user first.');
      return;
    }
    setState(() {
      _busy = true;
      _jfStatus = 'Signing in…';
    });
    final config = await widget.jellyfinLogin(server, user, pass);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (config != null) {
        _accounts.setJellyfin(config);
        _jfPass.clear();
        _jfStatus = 'Signed in. The password was not stored.';
      } else {
        _jfStatus = 'Sign-in failed — check server, user and password.';
      }
    });
  }

  Future<void> _testJellyfin() async {
    setState(() {
      _busy = true;
      _jfStatus = 'Testing…';
    });
    final ok = await widget.testJellyfin();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _jfStatus = ok ? 'Connected — server answered.' : 'Could not connect.';
    });
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final jf = _accounts.jellyfin;
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts & servers')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'These details are stored only in UpZe\'s private app '
              'folder on this phone, and are sent only to the server '
              'or service they belong to.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const _SectionTitle('Subsonic / Navidrome'),
          _field(_subUrl, 'Server URL', 'https://music.example.com',
              keyboard: TextInputType.url),
          _field(_subUser, 'User', 'you'),
          _field(_subPass, 'Password', '', obscure: true),
          _buttons(
            status: _subStatus,
            children: [
              FilledButton(
                onPressed: _busy ? null : _saveSubsonic,
                child: const Text('Save'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _testSubsonic,
                child: const Text('Test connection'),
              ),
              if (_accounts.hasSubsonic)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          _accounts.setSubsonic(null);
                          _subUrl.clear();
                          _subUser.clear();
                          _subPass.clear();
                          setState(() => _subStatus = 'Removed.');
                        },
                  child: const Text('Remove'),
                ),
            ],
          ),
          const _SectionTitle('Jellyfin'),
          if (jf != null) ...[
            ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('Signed in'),
              subtitle: Text(jf.baseUrl),
            ),
            _buttons(
              status: _jfStatus,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : _testJellyfin,
                  child: const Text('Test connection'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          _accounts.setJellyfin(null);
                          setState(() => _jfStatus = 'Signed out.');
                        },
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ] else ...[
            _field(_jfServer, 'Server URL', 'https://jellyfin.example.com',
                keyboard: TextInputType.url),
            _field(_jfUser, 'User', 'you'),
            _field(_jfPass, 'Password', '', obscure: true),
            _buttons(
              status: _jfStatus,
              children: [
                FilledButton(
                  onPressed: _busy ? null : _loginJellyfin,
                  child: const Text('Sign in'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'UpZe stores only the access token from sign-in, '
                'never your Jellyfin password.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
          const _SectionTitle('Spotify'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              _accounts.hasSpotify
                  ? 'Cookie saved — Spotify matching is on.'
                  : 'Signed out. Spotify in UpZe works through the '
                      'sp_dc cookie from open.spotify.com in your '
                      'browser; without it, Spotify stays signed out.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          _field(_spotify, 'sp_dc cookie', 'Paste the sp_dc value',
              maxLines: 2),
          _buttons(
            status: null,
            children: [
              FilledButton(
                onPressed: () {
                  final v = _spotify.text.trim();
                  _accounts.setSpotifyCookie(v.isEmpty ? null : v);
                  _snack(v.isEmpty ? 'Spotify cookie removed.' : 'Saved.');
                },
                child: const Text('Save'),
              ),
            ],
          ),
          const _SectionTitle('Jamendo'),
          _field(_jamendo, 'Client ID',
              'From your free Jamendo developer account'),
          _buttons(
            status: null,
            children: [
              FilledButton(
                onPressed: () {
                  final v = _jamendo.text.trim();
                  _accounts.setJamendoClientId(v.isEmpty ? null : v);
                  _snack(v.isEmpty ? 'Jamendo client ID removed.' : 'Saved.');
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String hint, {
    bool obscure = false,
    int maxLines = 1,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        maxLines: obscure ? 1 : maxLines,
        keyboardType: keyboard,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buttons({
    required String? status,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: children),
          if (status != null) ...[
            const SizedBox(height: 6),
            Text(status),
          ],
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
