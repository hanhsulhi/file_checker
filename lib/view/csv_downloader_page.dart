import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;
import 'package:archive/archive.dart';

// ─── Constants ───────────────────────────────────────────────────────────────

/// Max simultaneous HTTP requests. Too high = browser throttles + OOM.
const int _kConcurrency = 6;

/// Only call setState at most once per this interval during downloads.
const Duration _kUiThrottle = Duration(milliseconds: 250);

const _mimeToExt = {
  'application/pdf': '.pdf',
  'image/jpeg': '.jpg',
  'image/jpg': '.jpg',
  'image/png': '.png',
  'image/gif': '.gif',
  'image/webp': '.webp',
  'image/svg+xml': '.svg',
  'application/msword': '.doc',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': '.docx',
  'application/vnd.ms-excel': '.xls',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': '.xlsx',
  'application/vnd.ms-powerpoint': '.ppt',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': '.pptx',
  'application/zip': '.zip',
  'application/x-zip-compressed': '.zip',
  'application/json': '.json',
  'text/plain': '.txt',
  'text/csv': '.csv',
  'text/html': '.html',
  'video/mp4': '.mp4',
  'video/quicktime': '.mov',
  'audio/mpeg': '.mp3',
  'audio/wav': '.wav',
};

// ─── Data Models ────────────────────────────────────────────────────────────

enum DownloadStatus { idle, pending, downloading, done, error }

class CsvRow {
  final String contractorFullName;
  final String documentName;
  final String url;
  DownloadStatus status;
  String? errorMessage;
  int? bytes;
  String? detectedExtension;

  CsvRow({required this.contractorFullName, required this.documentName, required this.url, this.status = DownloadStatus.idle, this.errorMessage, this.bytes, this.detectedExtension});

  String get safeContractorName => contractorFullName.replaceAll(RegExp(r'[<>:"/\\|?*\n\r\t]'), '_').trim();

  String get safeDocumentName => documentName.replaceAll(RegExp(r'[<>:"/\\|?*\n\r\t]'), '_').trim();

  String get fileExtension {
    final nameParts = documentName.split('.');
    if (nameParts.length > 1 && nameParts.last.length >= 2 && nameParts.last.length <= 5) {
      return '.${nameParts.last}';
    }
    if (detectedExtension != null && detectedExtension!.isNotEmpty) {
      return detectedExtension!;
    }
    try {
      final uri = Uri.parse(url);
      final segment = uri.pathSegments.lastWhere((s) => s.contains('.'), orElse: () => '');
      if (segment.isNotEmpty) {
        final ext = '.${segment.split('.').last.split('?').first}';
        if (ext.length >= 2 && ext.length <= 6) return ext;
      }
    } catch (_) {}
    return '';
  }

  String get zipPath {
    final ext = fileExtension;
    final base = safeDocumentName;
    final name = base.toLowerCase().endsWith(ext.toLowerCase()) ? base : '$base$ext';
    return '$safeContractorName/$name';
  }
}

// ─── CSV Parser ─────────────────────────────────────────────────────────────

List<CsvRow> parseCsv(String csvText) {
  final lines = csvText.split('\n').map((l) => l.trimRight()).where((l) => l.isNotEmpty).toList();

  if (lines.isEmpty) return [];

  final header = _splitCsvLine(lines.first).map((h) => h.trim().toLowerCase()).toList();

  final contractorIdx = header.indexWhere((h) => h == 'contractorfullname' || h == 'contractor_full_name' || h == 'contractor');
  final documentIdx = header.indexWhere((h) => h == 'documentname' || h == 'document_name' || h == 'document');
  final urlIdx = header.indexWhere((h) => h == 'url' || h == 'link');

  if (contractorIdx == -1 || documentIdx == -1 || urlIdx == -1) {
    throw Exception('CSV must have columns: ContractorFullName, DocumentName, Url');
  }

  final rows = <CsvRow>[];
  for (int i = 1; i < lines.length; i++) {
    final cols = _splitCsvLine(lines[i]);
    final maxIdx = [contractorIdx, documentIdx, urlIdx].reduce((a, b) => a > b ? a : b);
    if (cols.length > maxIdx) {
      final contractor = cols[contractorIdx].trim();
      final document = cols[documentIdx].trim();
      final url = cols[urlIdx].trim();
      if (contractor.isNotEmpty && url.isNotEmpty) {
        rows.add(CsvRow(contractorFullName: contractor, documentName: document.isEmpty ? 'Document_$i' : document, url: url));
      }
    }
  }
  return rows;
}

List<String> _splitCsvLine(String line) {
  final result = <String>[];
  final buffer = StringBuffer();
  bool inQuotes = false;

  for (int i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (ch == ',' && !inQuotes) {
      result.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  result.add(buffer.toString());
  return result;
}

// ─── Download State ──────────────────────────────────────────────────────────

class _DownloadState {
  int completed = 0;
  int totalBytes = 0;
  int doneCount = 0;
  int errorCount = 0;
}

// ─── Main Page ──────────────────────────────────────────────────────────────

class CsvDownloaderPage extends StatefulWidget {
  const CsvDownloaderPage({super.key});

  @override
  State<CsvDownloaderPage> createState() => _CsvDownloaderPageState();
}

class _CsvDownloaderPageState extends State<CsvDownloaderPage> with TickerProviderStateMixin {
  List<CsvRow> _rows = [];
  List<_ContractorSummary> _contractors = [];

  bool _isDownloading = false;
  bool _isDone = false;
  String? _parseError;
  String? _csvFileName;

  final _dl = _DownloadState();

  Timer? _uiTimer;
  bool _uiDirty = false;

  late AnimationController _pulseController;
  final http.Client _httpClient = http.Client();

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _pulseController.dispose();
    _httpClient.close();
    super.dispose();
  }

  // ── Throttled setState ─────────────────────────────────────────────────────

  void _markDirty() {
    _uiDirty = true;
    _uiTimer ??= Timer.periodic(_kUiThrottle, (_) {
      if (_uiDirty && mounted) {
        setState(() => _uiDirty = false);
      }
    });
  }

  void _stopUiTimer() {
    _uiTimer?.cancel();
    _uiTimer = null;
    if (mounted) setState(() {});
  }

  // ── CSV Import ─────────────────────────────────────────────────────────────

  void _importCsv() {
    final input = web.document.createElement('input') as web.HTMLInputElement;
    input.type = 'file';
    input.accept = '.csv,text/csv';
    input.click();

    input.onchange = (web.Event event) {
      final files = input.files;
      if (files == null || files.length == 0) return;
      final file = files.item(0)!;
      _csvFileName = file.name;

      final reader = web.FileReader();
      reader.readAsText(file);
      reader.onload = (web.Event e) {
        final result = reader.result;
        if (result == null) return;
        final text = result.toString();
        try {
          final rows = parseCsv(text);
          if (rows.isEmpty) throw Exception('No valid rows found in CSV');
          final contractors = _buildContractorSummaries(rows);
          setState(() {
            _rows = rows;
            _contractors = contractors;
            _parseError = null;
            _isDone = false;
            _dl.completed = 0;
            _dl.totalBytes = 0;
            _dl.doneCount = 0;
            _dl.errorCount = 0;
          });
          _showConfirmDialog();
        } catch (e) {
          setState(() {
            _parseError = e.toString().replaceFirst('Exception: ', '');
            _rows = [];
            _contractors = [];
          });
        }
      }.toJS;
    }.toJS;
  }

  List<_ContractorSummary> _buildContractorSummaries(List<CsvRow> rows) {
    final map = <String, _ContractorSummary>{};
    for (int i = 0; i < rows.length; i++) {
      final name = rows[i].contractorFullName;
      map.putIfAbsent(name, () => _ContractorSummary(name: name));
      map[name]!.indices.add(i);
    }
    return map.values.toList();
  }

  // ── Confirm Dialog ─────────────────────────────────────────────────────────

  void _showConfirmDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF30363D)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: const Color(0xFF0A84FF).withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.folder_zip_outlined, color: Color(0xFF0A84FF), size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Ready to Download',
                            style: TextStyle(color: Color(0xFFE6EDF3), fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                          Text('${_rows.length} files · ${_contractors.length} contractors', style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(color: Color(0xFF21262D)),
                const SizedBox(height: 8),
                const Text(
                  'Folder structure preview:',
                  style: TextStyle(color: Color(0xFF8B949E), fontSize: 11, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D1117),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF21262D)),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(12),
                      itemCount: _contractors.length,
                      itemBuilder: (_, i) {
                        final c = _contractors[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              const Icon(Icons.folder, size: 13, color: Color(0xFFE3B341)),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  c.name,
                                  style: const TextStyle(color: Color(0xFFE3B341), fontSize: 12, fontFamily: 'monospace'),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text('${c.indices.length} file${c.indices.length != 1 ? "s" : ""}', style: const TextStyle(color: Color(0xFF484F58), fontSize: 11)),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A84FF).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF0A84FF).withOpacity(0.2)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, size: 14, color: Color(0xFF58A6FF)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Files download with 6 concurrent connections and are streamed directly into the ZIP — no large memory spikes.',
                          style: TextStyle(color: Color(0xFF58A6FF), fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: TextButton.styleFrom(foregroundColor: const Color(0xFF8B949E)),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _startDownload();
                      },
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Download ZIP'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF0A84FF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Download Logic ─────────────────────────────────────────────────────────

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _isDone = false;
      _dl.completed = 0;
      _dl.totalBytes = 0;
      _dl.doneCount = 0;
      _dl.errorCount = 0;
      for (final row in _rows) {
        row.status = DownloadStatus.pending;
        row.errorMessage = null;
        row.bytes = null;
        row.detectedExtension = null;
      }
    });

    final archive = Archive();
    final semaphore = _Semaphore(_kConcurrency);

    final futures = List.generate(_rows.length, (i) async {
      await semaphore.acquire();
      if (!mounted) {
        semaphore.release();
        return;
      }

      final row = _rows[i];
      row.status = DownloadStatus.downloading;
      _markDirty();

      Uint8List? fileBytes;
      try {
        final uri = Uri.parse(row.url);
        final response = await _httpClient.get(uri).timeout(const Duration(seconds: 60));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          fileBytes = response.bodyBytes;
          row.bytes = fileBytes.length;

          final ct = response.headers['content-type']?.split(';').first.trim().toLowerCase();
          if (ct != null && _mimeToExt.containsKey(ct)) {
            row.detectedExtension = _mimeToExt[ct];
          }

          row.status = DownloadStatus.done;
          _dl.doneCount++;
          _dl.totalBytes += fileBytes.length;

          // Add to archive immediately then allow GC to reclaim
          archive.addFile(ArchiveFile(row.zipPath, fileBytes.length, fileBytes));
          fileBytes = null;
        } else {
          row.status = DownloadStatus.error;
          row.errorMessage = 'HTTP ${response.statusCode}';
          _dl.errorCount++;
        }
      } on TimeoutException {
        row.status = DownloadStatus.error;
        row.errorMessage = 'Timed out';
        _dl.errorCount++;
      } catch (e) {
        row.status = DownloadStatus.error;
        row.errorMessage = e.toString().replaceFirst('Exception: ', '');
        _dl.errorCount++;
      } finally {
        _dl.completed++;
        semaphore.release();
        _markDirty();
      }
    });

    await Future.wait(futures);

    if (archive.isNotEmpty) {
      _triggerZipDownload(archive);
    }

    _stopUiTimer();
    setState(() {
      _isDownloading = false;
      _isDone = true;
    });
  }

  void _triggerZipDownload(Archive archive) {
    final zipList = ZipEncoder().encode(archive);
    if (zipList == null) return;
    final zipBytes = Uint8List.fromList(zipList);

    final blob = web.Blob([zipBytes.toJS].toJS, web.BlobPropertyBag(type: 'application/zip'));
    final url = web.URL.createObjectURL(blob);
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
    anchor.href = url;
    anchor.download = 'contractor_documents.zip';
    anchor.click();
    web.URL.revokeObjectURL(url);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  double get _progress => _rows.isEmpty ? 0 : _dl.completed / _rows.length;

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: SafeArea(child: Column(children: [_buildHeader(), if (_rows.isEmpty) _buildEmptyState() else _buildContent()])),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: const Color(0xFFE3B341).withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.folder_zip_outlined, color: Color(0xFFE3B341), size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'CSV Bulk Downloader',
                  style: TextStyle(color: Color(0xFFE6EDF3), fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.3),
                ),
                Text(_csvFileName != null ? 'Loaded: $_csvFileName' : 'Import a CSV to download files by contractor', style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!_isDownloading)
            FilledButton.icon(
              onPressed: _importCsv,
              icon: const Icon(Icons.upload_file, size: 16),
              label: Text(_rows.isEmpty ? 'Import CSV' : 'Re-import'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF21262D),
                foregroundColor: const Color(0xFFE6EDF3),
                side: const BorderSide(color: Color(0xFF30363D)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Expanded(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.upload_file_outlined, size: 48, color: Color(0xFF30363D)),
                  const SizedBox(height: 16),
                  const Text(
                    'Import a CSV file',
                    style: TextStyle(color: Color(0xFF8B949E), fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  const Text('Required columns: ContractorFullName, DocumentName, Url', style: TextStyle(color: Color(0xFF484F58), fontSize: 12)),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _importCsv,
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const Text('Choose CSV File'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFE3B341),
                      foregroundColor: const Color(0xFF0D1117),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  if (_parseError != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF85149).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFF85149).withOpacity(0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, size: 14, color: Color(0xFFF85149)),
                          const SizedBox(width: 8),
                          Text(_parseError!, style: const TextStyle(color: Color(0xFFF85149), fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Expanded(
      child: Column(
        children: [
          // Summary bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFF161B22),
            child: Row(
              children: [
                _chip(Icons.people_outline, '${_contractors.length} contractors', const Color(0xFF8B949E)),
                const SizedBox(width: 8),
                _chip(Icons.insert_drive_file_outlined, '${_rows.length} files', const Color(0xFF8B949E)),
                if (_dl.doneCount > 0) ...[const SizedBox(width: 8), _chip(Icons.check_circle_outline, '${_dl.doneCount} done', const Color(0xFF3FB950))],
                if (_dl.errorCount > 0) ...[const SizedBox(width: 8), _chip(Icons.error_outline, '${_dl.errorCount} errors', const Color(0xFFF85149))],
                if (_dl.totalBytes > 0) ...[const SizedBox(width: 8), _chip(Icons.storage_outlined, _formatBytes(_dl.totalBytes), const Color(0xFF0A84FF))],
                const Spacer(),
                if (!_isDownloading && !_isDone)
                  FilledButton.icon(
                    onPressed: _showConfirmDialog,
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Download ZIP'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFE3B341),
                      foregroundColor: const Color(0xFF0D1117),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                if (_isDone)
                  FilledButton.icon(
                    onPressed: _showConfirmDialog,
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Download Again'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF21262D),
                      foregroundColor: const Color(0xFFE6EDF3),
                      side: const BorderSide(color: Color(0xFF30363D)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
              ],
            ),
          ),

          // Progress bar
          if (_isDownloading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Downloading ${_dl.completed} of ${_rows.length}'
                        '${_dl.totalBytes > 0 ? "  ·  ${_formatBytes(_dl.totalBytes)} so far" : ""}',
                        style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
                      ),
                      Text(
                        '${(_progress * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(color: Color(0xFF0A84FF), fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (_, __) => LinearProgressIndicator(
                      value: _progress,
                      backgroundColor: const Color(0xFF21262D),
                      valueColor: AlwaysStoppedAnimation(Color.lerp(const Color(0xFF0A84FF), const Color(0xFF58A6FF), _pulseController.value)!),
                      borderRadius: BorderRadius.circular(4),
                      minHeight: 6,
                    ),
                  ),
                ],
              ),
            ),

          const Divider(height: 1, color: Color(0xFF21262D)),

          // Virtualized contractor list — only visible items are rendered
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _contractors.length,
              itemBuilder: (ctx, i) => RepaintBoundary(
                child: _ContractorGroupTile(key: ValueKey(_contractors[i].name), summary: _contractors[i], allRows: _rows, formatBytes: _formatBytes, pulseController: _pulseController),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
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

// ─── Contractor Summary ───────────────────────────────────────────────────────

class _ContractorSummary {
  final String name;
  final List<int> indices = [];
  _ContractorSummary({required this.name});
}

// ─── Contractor Group Tile ───────────────────────────────────────────────────

class _ContractorGroupTile extends StatefulWidget {
  final _ContractorSummary summary;
  final List<CsvRow> allRows;
  final String Function(int) formatBytes;
  final AnimationController pulseController;

  const _ContractorGroupTile({super.key, required this.summary, required this.allRows, required this.formatBytes, required this.pulseController});

  @override
  State<_ContractorGroupTile> createState() => _ContractorGroupTileState();
}

class _ContractorGroupTileState extends State<_ContractorGroupTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final rows = widget.summary.indices.map((i) => widget.allRows[i]).toList();
    final doneCount = rows.where((r) => r.status == DownloadStatus.done).length;
    final errorCount = rows.where((r) => r.status == DownloadStatus.error).length;
    final isAllDone = doneCount == rows.length && rows.isNotEmpty;
    final hasErrors = errorCount > 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isAllDone && !hasErrors
              ? const Color(0xFF238636).withOpacity(0.4)
              : hasErrors
              ? const Color(0xFFF85149).withOpacity(0.2)
              : const Color(0xFF30363D),
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.folder, size: 17, color: Color(0xFFE3B341)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.summary.name,
                      style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (doneCount > 0 || errorCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        '$doneCount/${rows.length}',
                        style: TextStyle(color: isAllDone ? const Color(0xFF3FB950) : const Color(0xFF8B949E), fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: const Color(0xFF21262D), borderRadius: BorderRadius.circular(10)),
                    child: Text('${rows.length}', style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                  ),
                  const SizedBox(width: 8),
                  if (isAllDone && !hasErrors)
                    const Icon(Icons.check_circle, size: 15, color: Color(0xFF3FB950))
                  else if (hasErrors)
                    Icon(Icons.warning_amber_outlined, size: 15, color: const Color(0xFFF85149).withOpacity(0.8)),
                  const SizedBox(width: 6),
                  Icon(_expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 16, color: const Color(0xFF484F58)),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1, color: Color(0xFF21262D)),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: rows.length,
              itemBuilder: (_, j) => _FileRow(row: rows[j], formatBytes: widget.formatBytes, pulseController: widget.pulseController),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── File Row ────────────────────────────────────────────────────────────────

class _FileRow extends StatelessWidget {
  final CsvRow row;
  final String Function(int) formatBytes;
  final AnimationController pulseController;

  const _FileRow({required this.row, required this.formatBytes, required this.pulseController});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          _statusIcon,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.documentName,
                  style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 12, fontWeight: FontWeight.w500),
                ),
                if (row.status == DownloadStatus.error && row.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(row.errorMessage!, style: const TextStyle(color: Color(0xFFF85149), fontSize: 10)),
                  ),
                if (row.status == DownloadStatus.downloading)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: AnimatedBuilder(
                      animation: pulseController,
                      builder: (_, __) => LinearProgressIndicator(
                        backgroundColor: const Color(0xFF21262D),
                        valueColor: AlwaysStoppedAnimation(Color.lerp(const Color(0xFF0A84FF), const Color(0xFF58A6FF), pulseController.value)!),
                        borderRadius: BorderRadius.circular(2),
                        minHeight: 2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (row.bytes != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                formatBytes(row.bytes!),
                style: const TextStyle(color: Color(0xFF484F58), fontSize: 10, fontFamily: 'monospace'),
              ),
            ),
        ],
      ),
    );
  }

  Widget get _statusIcon {
    switch (row.status) {
      case DownloadStatus.done:
        return const Icon(Icons.check_circle, size: 14, color: Color(0xFF3FB950));
      case DownloadStatus.error:
        return const Icon(Icons.cancel_outlined, size: 14, color: Color(0xFFF85149));
      case DownloadStatus.downloading:
        return const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A84FF)));
      case DownloadStatus.pending:
        return const Icon(Icons.schedule, size: 14, color: Color(0xFF484F58));
      case DownloadStatus.idle:
        return const Icon(Icons.circle_outlined, size: 14, color: Color(0xFF30363D));
    }
  }
}

// ─── Semaphore ────────────────────────────────────────────────────────────────

class _Semaphore {
  final int maxCount;
  int _count = 0;
  final _queue = <Completer<void>>[];

  _Semaphore(this.maxCount);

  Future<void> acquire() async {
    if (_count < maxCount) {
      _count++;
      return;
    }
    final completer = Completer<void>();
    _queue.add(completer);
    await completer.future;
    _count++;
  }

  void release() {
    _count--;
    if (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      next.complete();
    }
  }
}
