import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/pocket/pocket_link.dart';
import '../../state/hosts_state.dart';
import '../common/brief_notice.dart';
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'link_progress.dart';
import 'pocket_qr_scanner.dart';

/// Add or edit a dsh-pocket host: one QR code (or link) per entry, the two
/// access PINs, and which entry to use.
class PocketHostFormPage extends ConsumerStatefulWidget {
  const PocketHostFormPage({super.key, this.existing, this.initialScan});

  /// Null to add a new host.
  final PocketHostConfig? existing;

  /// A code scanned before the form opened ("+ 扫码添加").
  final PocketScan? initialScan;

  @override
  ConsumerState<PocketHostFormPage> createState() => _PocketHostFormPageState();
}

class _PocketHostFormPageState extends ConsumerState<PocketHostFormPage> {
  late final String _id = widget.existing?.id ?? PocketHostConfig.newId();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _lan = TextEditingController(text: widget.existing?.lanUrl ?? '');
  late final _tailscale = TextEditingController(text: widget.existing?.tailscaleUrl ?? '');
  late final _public = TextEditingController(text: widget.existing?.publicUrl ?? '');
  final _lanPin = TextEditingController();
  final _publicPin = TextEditingController();
  late PocketRouteMode _mode = widget.existing?.mode ?? PocketRouteMode.auto;
  bool _obscure = true;
  bool _saving = false;
  String? _formError;
  HostLinkStatus? _testStatus;
  PocketHostLink? _test;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    if (widget.existing case final host?) {
      unawaited(
        ref.read(hostsProvider.notifier).loadPocketSecrets(host.id).then((s) {
          if (!mounted) return;
          setState(() {
            _lanPin.text = s.lanPin ?? '';
            _publicPin.text = s.publicPin ?? '';
          });
        }),
      );
    }
    if (widget.initialScan case final scan?) _apply(scan, notify: false);
  }

  @override
  void dispose() {
    unawaited(_test?.close());
    for (final c in [_name, _lan, _tailscale, _public, _lanPin, _publicPin]) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _urlField(PocketRoute route) => switch (route) {
    PocketRoute.lan => _lan,
    PocketRoute.tailscale => _tailscale,
    PocketRoute.public => _public,
  };

  void _apply(PocketScan scan, {bool notify = true}) {
    setState(() {
      _urlField(scan.route).text = scan.url;
      if (scan.pin case final pin?) {
        (scan.route == PocketRoute.public ? _publicPin : _lanPin).text = pin;
      }
      _formError = null;
    });
    if (notify) {
      ScaffoldMessenger.maybeOf(context)?.showBriefNotice(context.l10n.pocketScanFilled(pocketRouteLabel(scan.route)));
    }
  }

  Future<void> _scan() async {
    final scan = await PocketQrScannerPage.open(context);
    if (scan != null && mounted) _apply(scan);
  }

  Future<void> _paste() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted) return;
    final scan = text == null ? null : PocketScan.tryParse(text);
    if (scan == null) {
      messenger?.showBriefNotice(l10n.pocketScanNotPocket);
      return;
    }
    _apply(scan);
  }

  /// The config from the fields, or null with [_formError] set.
  PocketHostConfig? _build() {
    final l10n = context.l10n;
    String? read(TextEditingController c) => c.text.trim().isEmpty ? null : normalizePocketUrl(c.text);
    for (final c in [_lan, _tailscale, _public]) {
      if (c.text.trim().isNotEmpty && read(c) == null) {
        setState(() => _formError = l10n.pocketErrBadUrl);
        return null;
      }
    }
    final config = PocketHostConfig(
      id: _id,
      name: _name.text.trim().isEmpty ? l10n.pocketHost : _name.text.trim(),
      lanUrl: read(_lan),
      tailscaleUrl: read(_tailscale),
      publicUrl: read(_public),
      mode: _mode,
    );
    if (!config.hasAnyUrl) {
      setState(() => _formError = l10n.pocketErrNeedUrl);
      return null;
    }
    setState(() => _formError = null);
    return config;
  }

  PocketSecrets get _secrets => PocketSecrets(lanPin: _lanPin.text.trim(), publicPin: _publicPin.text.trim());

  Future<void> _runTest() async {
    final config = _build();
    if (config == null) return;
    await _test?.close();
    var current = config;
    final secrets = _secrets;
    final link = PocketHostLink(
      readConfig: () => current,
      loadSecrets: () async => secrets,
      // Show what the computer reports right away: the other two entries
      // and the public PIN land in the form before saving.
      onEntryInfo: (info) async {
        current = info.applyTo(current);
        if (!mounted) return;
        setState(() {
          _lan.text = current.lanUrl ?? '';
          _tailscale.text = current.tailscaleUrl ?? '';
          _public.text = current.publicUrl ?? '';
          if (info.publicPin case final pin?) _publicPin.text = pin;
        });
      },
      retryFirstOpen: false,
    );
    _test = link;
    final sub = link.statuses.listen((s) {
      if (mounted) setState(() => _testStatus = s);
    });
    try {
      await link.open();
      // Give entry.json a moment to arrive.
      await Future<void>.delayed(const Duration(seconds: 2));
    } catch (_) {
      // Shown by the progress card.
    } finally {
      await sub.cancel();
      if (identical(_test, link)) {
        _test = null;
        final last = link.status;
        await link.close();
        if (mounted) setState(() => _testStatus = last);
      }
    }
  }

  Future<void> _save() async {
    final config = _build();
    if (config == null) return;
    setState(() => _saving = true);
    await ref.read(hostsProvider.notifier).savePocket(config, secrets: _secrets);
    if (mounted) Navigator.of(context).pop(config);
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.remoteDeleteHost),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.remoteDeleteHost)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(hostsProvider.notifier).removePocket(_id);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _pinToggle() => IconButton(
    icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
    onPressed: () => setState(() => _obscure = !_obscure),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final mono = AppType.mono(size: 15, color: scheme.onSurface, height: 1.4);
    final testing = _test != null;

    Widget urlField(TextEditingController c, String label, String hint, {String? helper}) => FormFieldBlock(
      label: label,
      helper: helper,
      child: TextField(
        controller: c,
        keyboardType: TextInputType.url,
        autocorrect: false,
        style: mono,
        decoration: InputDecoration(hintText: hint),
      ),
    );

    Widget pinField(TextEditingController c, String label, String helper) => FormFieldBlock(
      label: label,
      helper: helper,
      child: TextField(
        controller: c,
        obscureText: _obscure,
        autocorrect: false,
        enableSuggestions: false,
        style: mono,
        decoration: InputDecoration(suffixIcon: _pinToggle()),
      ),
    );

    return AppPage.list(
      title: _editing ? l10n.pocketEditHost : l10n.pocketAddHost,
      subtitle: _editing ? null : Text(l10n.pocketHostIntro),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _scan,
                    icon: const Icon(AppIcons.qrCode, size: 19),
                    label: Text(l10n.pocketScanQr),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _paste,
                    icon: const Icon(AppIcons.paste, size: 19),
                    label: Text(l10n.pocketPasteLink),
                  ),
                ],
              ),
            ),
            SettingsSection(
              title: l10n.remoteHostBasicInfo,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.commonName,
                      child: TextField(
                        controller: _name,
                        decoration: InputDecoration(hintText: l10n.remoteHostNameHint),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: l10n.pocketAddresses,
              children: [
                FormFieldGroup(
                  children: [
                    urlField(_lan, l10n.pocketLanUrl, 'http://192.168.x.x:3081'),
                    pinField(_lanPin, l10n.pocketLanPin, l10n.pocketLanPinHelper),
                    urlField(
                      _tailscale,
                      l10n.pocketTailscaleUrl,
                      'http://100.x.x.x:3081',
                      helper: l10n.pocketTailscaleUrlHelper,
                    ),
                    urlField(
                      _public,
                      l10n.pocketPublicUrl,
                      'https://….trycloudflare.com',
                      helper: l10n.pocketPublicUrlHelper,
                    ),
                    pinField(_publicPin, l10n.pocketPublicPin, l10n.pocketPublicPinHelper),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: l10n.pocketRouteSection,
              footer: Text(l10n.pocketModeHint),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 12, SettingsMetrics.inset, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final m in PocketRouteMode.values)
                        ChoiceChip(
                          label: Text(m.pinned == null ? l10n.pocketModeAuto : pocketRouteLabel(m.pinned!)),
                          selected: _mode == m,
                          onSelected: (_) => setState(() => _mode = m),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (_testStatus case final status?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: LinkProgressCard(status: status, onRetry: testing ? null : _runTest),
              ),
            if (_formError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: testing || _saving ? null : _runTest,
                    icon: testing
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(AppIcons.testConnection, size: 19),
                    label: Text(testing ? l10n.remoteTesting : l10n.remoteTestConnection),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(onPressed: _saving ? null : _save, child: Text(l10n.commonSave)),
                ],
              ),
            ),
            if (_editing)
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: colors.danger),
                  onPressed: _delete,
                  icon: const Icon(AppIcons.delete, size: 19),
                  label: Text(l10n.remoteDeleteHost),
                ),
              ),
            const SizedBox(height: 24),
          ],
        ),
      ],
    );
  }
}
