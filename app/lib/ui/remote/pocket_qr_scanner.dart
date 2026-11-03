import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/l10n.dart';
import '../../remote/pocket/pocket_host_config.dart';
import '../common/brief_notice.dart';
import '../theme/app_icons.dart';

/// Full-screen camera scanner for dsh-pocket QR codes; pops with the first
/// code that is a pocket entry address. A photo of the code (taken before
/// leaving the computer) works too.
class PocketQrScannerPage extends StatefulWidget {
  const PocketQrScannerPage({super.key});

  static Future<PocketScan?> open(BuildContext context) =>
      Navigator.of(context).push<PocketScan>(MaterialPageRoute(builder: (_) => const PocketQrScannerPage()));

  @override
  State<PocketQrScannerPage> createState() => _PocketQrScannerPageState();
}

class _PocketQrScannerPageState extends State<PocketQrScannerPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  String? _lastRejected;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  /// True when one of [codes] was taken.
  bool _take(Iterable<Barcode> codes) {
    if (_done) return true;
    for (final code in codes) {
      final raw = code.rawValue;
      if (raw == null) continue;
      final scan = PocketScan.tryParse(raw);
      if (scan != null) {
        _done = true;
        Navigator.of(context).pop(scan);
        return true;
      }
      if (raw != _lastRejected) {
        _lastRejected = raw;
        ScaffoldMessenger.maybeOf(context)?.showBriefNotice(context.l10n.pocketScanNotPocket);
      }
    }
    return false;
  }

  Future<void> _fromGallery() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null || !mounted) return;
    BarcodeCapture? capture;
    try {
      capture = await _controller.analyzeImage(image.path, formats: const [BarcodeFormat.qrCode]);
    } catch (_) {
      capture = null;
    }
    if (!mounted) return;
    if (capture == null || capture.barcodes.isEmpty) {
      messenger?.showBriefNotice(l10n.pocketScanNoCode);
      return;
    }
    if (!_take(capture.barcodes)) messenger?.showBriefNotice(l10n.pocketScanNotPocket);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(l10n.pocketScanTitle),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: (capture) => _take(capture.barcodes)),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 32 + MediaQuery.paddingOf(context).bottom,
            child: FilledButton.tonalIcon(
              onPressed: _fromGallery,
              icon: const Icon(AppIcons.image, size: 19),
              label: Text(l10n.pocketScanFromGallery),
            ),
          ),
        ],
      ),
    );
  }
}
