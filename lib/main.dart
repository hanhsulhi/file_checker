import 'dart:async';
import 'package:file_checker/view/csv_downloader_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const FileCheckerApp());
}

class FileCheckerApp extends StatelessWidget {
  const FileCheckerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'File Tools',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF), brightness: Brightness.dark),
        useMaterial3: true,
        fontFamily: 'monospace',
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedTab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: Column(
        children: [
          // Top tab bar
          Container(
            color: const Color(0xFF161B22),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  _TabButton(icon: Icons.link, label: 'URL Checker', selected: _selectedTab == 0, onTap: () => setState(() => _selectedTab = 0)),
                  _TabButton(icon: Icons.folder_zip_outlined, label: 'CSV Downloader', selected: _selectedTab == 1, onTap: () => setState(() => _selectedTab = 1)),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Text(
                      'File Tools',
                      style: TextStyle(color: const Color(0xFF484F58), fontSize: 11, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFF21262D)),
          Expanded(
            child: IndexedStack(index: _selectedTab, children: const [FileCheckerHome(), CsvDownloaderPage()]),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: selected ? const Color(0xFF0A84FF) : Colors.transparent, width: 2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: selected ? const Color(0xFF0A84FF) : const Color(0xFF8B949E)),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(color: selected ? const Color(0xFF0A84FF) : const Color(0xFF8B949E), fontSize: 13, fontWeight: selected ? FontWeight.w600 : FontWeight.normal),
            ),
          ],
        ),
      ),
    );
  }
}

enum CheckStatus { idle, checking, done, error }

class UrlEntry {
  final String url;
  CheckStatus status;
  String? fileSize;
  String? fileName;
  String? contentType;
  String? errorMessage;
  int? bytes;

  UrlEntry({required this.url, this.status = CheckStatus.idle, this.fileSize, this.fileName, this.contentType, this.errorMessage, this.bytes});

  UrlEntry copyWith({CheckStatus? status, String? fileSize, String? fileName, String? contentType, String? errorMessage, int? bytes}) {
    return UrlEntry(
      url: url,
      status: status ?? this.status,
      fileSize: fileSize ?? this.fileSize,
      fileName: fileName ?? this.fileName,
      contentType: contentType ?? this.contentType,
      errorMessage: errorMessage ?? this.errorMessage,
      bytes: bytes ?? this.bytes,
    );
  }
}

class FileCheckerHome extends StatefulWidget {
  const FileCheckerHome({super.key});

  @override
  State<FileCheckerHome> createState() => _FileCheckerHomeState();
}

class _FileCheckerHomeState extends State<FileCheckerHome> with TickerProviderStateMixin {
  final TextEditingController _urlController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<UrlEntry> _entries = [];
  bool _isChecking = false;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _scrollController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _extractFileName(String url, Map<String, String> headers) {
    // Try Content-Disposition header first
    final disposition = headers['content-disposition'];
    if (disposition != null) {
      final filenameMatch = RegExp(
        r'filename[^;=\n]*=((["\\'
        ']).*?2|[^;\n]*)',
      ).firstMatch(disposition);
      if (filenameMatch != null) {
        return filenameMatch.group(1)?.replaceAll('"', '').trim() ?? 'Unknown';
      }
    }
    // Fall back to URL path
    try {
      final uri = Uri.parse(url);
      final pathSegments = uri.pathSegments;
      if (pathSegments.isNotEmpty && pathSegments.last.isNotEmpty) {
        return Uri.decodeComponent(pathSegments.last);
      }
    } catch (_) {}
    return 'Unknown';
  }

  Future<void> _checkUrls() async {
    final text = _urlController.text.trim();
    if (text.isEmpty) return;

    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

    if (lines.isEmpty) return;

    setState(() {
      _isChecking = true;
      _entries = lines.map((url) => UrlEntry(url: url)).toList();
    });

    // Check all URLs concurrently
    final futures = _entries.asMap().entries.map((entry) async {
      final index = entry.key;
      final urlEntry = entry.value;

      setState(() {
        _entries[index] = urlEntry.copyWith(status: CheckStatus.checking);
      });

      try {
        final uri = Uri.parse(urlEntry.url);
        final response = await http.head(uri).timeout(const Duration(seconds: 15));

        final headers = response.headers;
        int? contentLength;

        // Try content-length header
        final clHeader = headers['content-length'];
        if (clHeader != null) {
          contentLength = int.tryParse(clHeader);
        }

        // If HEAD didn't give content-length, try GET with byte range
        if (contentLength == null) {
          try {
            final getResponse = await http.get(uri, headers: {'Range': 'bytes=0-0'}).timeout(const Duration(seconds: 15));

            final crHeader = getResponse.headers['content-range'];
            if (crHeader != null) {
              final match = RegExp(r'/(\d+)$').firstMatch(crHeader);
              if (match != null) {
                contentLength = int.tryParse(match.group(1) ?? '');
              }
            }
          } catch (_) {}
        }

        final fileName = _extractFileName(urlEntry.url, headers);
        final contentType = headers['content-type']?.split(';').first.trim();

        setState(() {
          _entries[index] = _entries[index].copyWith(
            status: CheckStatus.done,
            bytes: contentLength,
            fileSize: contentLength != null ? _formatBytes(contentLength) : 'Unknown size',
            fileName: fileName,
            contentType: contentType,
          );
        });
      } on TimeoutException {
        setState(() {
          _entries[index] = _entries[index].copyWith(status: CheckStatus.error, errorMessage: 'Request timed out');
        });
      } catch (e) {
        setState(() {
          _entries[index] = _entries[index].copyWith(status: CheckStatus.error, errorMessage: e.toString().replaceFirst('Exception: ', ''));
        });
      }
    }).toList();

    await Future.wait(futures);

    setState(() {
      _isChecking = false;
    });
  }

  void _clearAll() {
    setState(() {
      _entries = [];
      _urlController.clear();
    });
  }

  void _copyResults() {
    final buffer = StringBuffer();
    for (final entry in _entries) {
      buffer.writeln('URL: ${entry.url}');
      if (entry.status == CheckStatus.done) {
        buffer.writeln('  File: ${entry.fileName ?? "Unknown"}');
        buffer.writeln('  Size: ${entry.fileSize ?? "Unknown"}');
        if (entry.bytes != null) buffer.writeln('  Bytes: ${entry.bytes}');
        buffer.writeln('  Type: ${entry.contentType ?? "Unknown"}');
      } else if (entry.status == CheckStatus.error) {
        buffer.writeln('  Error: ${entry.errorMessage}');
      }
      buffer.writeln();
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Results copied to clipboard'), duration: Duration(seconds: 2)));
  }

  int get _totalBytes {
    return _entries.where((e) => e.bytes != null).fold(0, (sum, e) => sum + e.bytes!);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                border: Border(bottom: BorderSide(color: const Color(0xFF30363D), width: 1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: const Color(0xFF0A84FF).withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.folder_zip_outlined, color: Color(0xFF0A84FF), size: 22),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'URL File Size Checker',
                            style: TextStyle(color: Color(0xFFE6EDF3), fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.3),
                          ),
                          Text('Paste URLs to check their file sizes', style: TextStyle(color: const Color(0xFF8B949E), fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // URL Input Area
            Container(
              padding: const EdgeInsets.all(16),
              color: const Color(0xFF161B22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D1117),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF30363D), width: 1),
                    ),
                    child: TextField(
                      controller: _urlController,
                      maxLines: 5,
                      minLines: 3,
                      style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13, fontFamily: 'monospace', height: 1.5),
                      decoration: const InputDecoration(
                        hintText: 'Paste one URL per line...\nhttps://example.com/file.zip\nhttps://example.com/document.pdf',
                        hintStyle: TextStyle(color: Color(0xFF484F58), fontSize: 13, fontFamily: 'monospace', height: 1.5),
                        contentPadding: EdgeInsets.all(14),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isChecking ? null : _checkUrls,
                          icon: _isChecking ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.search, size: 18),
                          label: Text(_isChecking ? 'Checking...' : 'Check File Sizes', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF0A84FF),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      if (_entries.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _copyResults,
                          icon: const Icon(Icons.copy_outlined, size: 18),
                          tooltip: 'Copy results',
                          style: IconButton.styleFrom(
                            foregroundColor: const Color(0xFF8B949E),
                            backgroundColor: const Color(0xFF21262D),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          onPressed: _clearAll,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: 'Clear all',
                          style: IconButton.styleFrom(
                            foregroundColor: const Color(0xFF8B949E),
                            backgroundColor: const Color(0xFF21262D),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // Summary bar
            if (_entries.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: const Color(0xFF161B22),
                child: Row(
                  children: [
                    _SummaryChip(icon: Icons.link, label: '${_entries.length} URL${_entries.length != 1 ? "s" : ""}', color: const Color(0xFF8B949E)),
                    const SizedBox(width: 8),
                    _SummaryChip(icon: Icons.check_circle_outline, label: '${_entries.where((e) => e.status == CheckStatus.done).length} done', color: const Color(0xFF3FB950)),
                    if (_entries.any((e) => e.status == CheckStatus.error)) ...[
                      const SizedBox(width: 8),
                      _SummaryChip(
                        icon: Icons.error_outline,
                        label: '${_entries.where((e) => e.status == CheckStatus.error).length} error${_entries.where((e) => e.status == CheckStatus.error).length != 1 ? "s" : ""}',
                        color: const Color(0xFFF85149),
                      ),
                    ],
                    const Spacer(),
                    if (_totalBytes > 0)
                      Text(
                        'Total: ${_formatBytes(_totalBytes)}',
                        style: const TextStyle(color: Color(0xFF0A84FF), fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                  ],
                ),
              ),

            // Divider
            if (_entries.isNotEmpty) const Divider(height: 1, color: Color(0xFF21262D)),

            // Results list
            Expanded(
              child: _entries.isEmpty
                  ? _buildEmptyState()
                  : ListView.separated(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: _entries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        return _UrlResultCard(entry: _entries[index], pulseController: _pulseController);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_download_outlined, size: 56, color: const Color(0xFF30363D)),
          const SizedBox(height: 16),
          const Text(
            'No URLs checked yet',
            style: TextStyle(color: Color(0xFF484F58), fontSize: 16, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          const Text('Paste download links above and tap Check', style: TextStyle(color: Color(0xFF30363D), fontSize: 13)),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _SummaryChip({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _UrlResultCard extends StatelessWidget {
  final UrlEntry entry;
  final AnimationController pulseController;

  const _UrlResultCard({required this.entry, required this.pulseController});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _borderColor, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // URL row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _statusIcon,
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.url,
                  style: const TextStyle(color: Color(0xFF79C0FF), fontSize: 12, fontFamily: 'monospace', decoration: TextDecoration.underline, decorationColor: Color(0xFF30363D)),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ),
              if (entry.status == CheckStatus.done && entry.bytes != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: const Color(0xFF0A84FF).withOpacity(0.15), borderRadius: BorderRadius.circular(20)),
                  child: Text(
                    entry.fileSize!,
                    style: const TextStyle(color: Color(0xFF0A84FF), fontSize: 13, fontWeight: FontWeight.w700, fontFamily: 'monospace'),
                  ),
                ),
            ],
          ),

          // Details
          if (entry.status == CheckStatus.done) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(0xFF21262D)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (entry.fileName != null && entry.fileName != 'Unknown') _DetailBadge(icon: Icons.insert_drive_file_outlined, label: entry.fileName!, color: const Color(0xFFE3B341)),
                if (entry.contentType != null) _DetailBadge(icon: Icons.label_outline, label: entry.contentType!, color: const Color(0xFF8B949E)),
                if (entry.bytes != null)
                  _DetailBadge(
                    icon: Icons.data_usage_outlined,
                    label: '${entry.bytes!.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')} bytes',
                    color: const Color(0xFF8B949E),
                  ),
                if (entry.fileSize == 'Unknown size') _DetailBadge(icon: Icons.help_outline, label: 'Size unavailable (server did not report)', color: const Color(0xFFF0883E)),
              ],
            ),
          ] else if (entry.status == CheckStatus.error) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.warning_amber_outlined, size: 13, color: Color(0xFFF85149)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    entry.errorMessage ?? 'Unknown error',
                    style: const TextStyle(color: Color(0xFFF85149), fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ] else if (entry.status == CheckStatus.checking) ...[
            const SizedBox(height: 8),
            AnimatedBuilder(
              animation: pulseController,
              builder: (context, _) {
                return LinearProgressIndicator(
                  backgroundColor: const Color(0xFF21262D),
                  valueColor: AlwaysStoppedAnimation<Color>(Color.lerp(const Color(0xFF0A84FF), const Color(0xFF58A6FF), pulseController.value)!),
                  borderRadius: BorderRadius.circular(4),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Color get _borderColor {
    switch (entry.status) {
      case CheckStatus.done:
        return entry.bytes != null ? const Color(0xFF238636).withOpacity(0.5) : const Color(0xFFF0883E).withOpacity(0.4);
      case CheckStatus.error:
        return const Color(0xFFF85149).withOpacity(0.4);
      case CheckStatus.checking:
        return const Color(0xFF0A84FF).withOpacity(0.3);
      case CheckStatus.idle:
        return const Color(0xFF30363D);
    }
  }

  Widget get _statusIcon {
    switch (entry.status) {
      case CheckStatus.done:
        return entry.bytes != null ? const Icon(Icons.check_circle, size: 16, color: Color(0xFF3FB950)) : const Icon(Icons.help_outline, size: 16, color: Color(0xFFF0883E));
      case CheckStatus.error:
        return const Icon(Icons.cancel_outlined, size: 16, color: Color(0xFFF85149));
      case CheckStatus.checking:
        return SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: const Color(0xFF0A84FF)));
      case CheckStatus.idle:
        return const Icon(Icons.circle_outlined, size: 16, color: Color(0xFF484F58));
    }
  }
}

class _DetailBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _DetailBadge({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.2), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              style: TextStyle(color: color, fontSize: 11, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
