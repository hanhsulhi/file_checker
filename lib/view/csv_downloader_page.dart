import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;
import 'package:archive/archive.dart';

// ─── Data Models ────────────────────────────────────────────────────────────

enum DownloadStatus { idle, pending, downloading, done, error }

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

class CsvRow {
  final String contractorFullName;
  final String documentName;
  final String url;
  DownloadStatus status;
  String? errorMessage;
  int? bytes;
  Uint8List? fileBytes;
  String? detectedExtension;

  CsvRow({required this.contractorFullName, required this.documentName, required this.url, this.status = DownloadStatus.idle, this.errorMessage, this.bytes, this.fileBytes, this.detectedExtension});

  String get safeContractorName => contractorFullName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();

  String get safeDocumentName => documentName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();

  /// Resolve extension with priority:
  /// 1. DocumentName already has an extension
  /// 2. Content-Type from actual HTTP response
  /// 3. URL path extension
  String get fileExtension {
    // 1. DocumentName already has a recognisable extension
    final nameParts = documentName.split('.');
    if (nameParts.length > 1 && nameParts.last.length >= 2 && nameParts.last.length <= 5) {
      return '.${nameParts.last}';
    }
    // 2. Content-Type detected during download
    if (detectedExtension != null && detectedExtension!.isNotEmpty) {
      return detectedExtension!;
    }
    // 3. URL path
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
  final lines = csvText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  if (lines.isEmpty) return [];

  // Parse header
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
    if (cols.length > contractorIdx && cols.length > documentIdx && cols.length > urlIdx) {
      final contractor = cols[contractorIdx].trim();
      final document = cols[documentIdx].trim();
      final url = cols[urlIdx].trim();
      if (contractor.isNotEmpty && url.isNotEmpty) {
        rows.add(CsvRow(contractorFullName: contractor, documentName: document.isEmpty ? 'Document_${i}' : document, url: url));
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

// ─── Main Page ──────────────────────────────────────────────────────────────

class CsvDownloaderPage extends StatefulWidget {
  const CsvDownloaderPage({super.key});

  @override
  State<CsvDownloaderPage> createState() => _CsvDownloaderPageState();
}

class _CsvDownloaderPageState extends State<CsvDownloaderPage> with TickerProviderStateMixin {
  List<CsvRow> _rows = [];
  bool _isDownloading = false;
  bool _isDone = false;
  String? _parseError;
  String? _csvFileName;
  int _completedCount = 0;
  int _totalDownloadedBytes = 0;
  DownloadStatus? _activeFilter; // null = show all, done = show done, error = show errors
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
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
          setState(() {
            _rows = rows;
            _parseError = null;
            _isDone = false;
            _completedCount = 0;
            _totalDownloadedBytes = 0;
            _activeFilter = null;
          });
          _showConfirmDialog();
        } catch (e) {
          setState(() {
            _parseError = e.toString().replaceFirst('Exception: ', '');
            _rows = [];
          });
        }
      }.toJS;
    }.toJS;
  }

  // ── Confirm Dialog ─────────────────────────────────────────────────────────

  void _showConfirmDialog() {
    // Group by contractor for preview
    final grouped = <String, List<CsvRow>>{};
    for (final row in _rows) {
      grouped.putIfAbsent(row.contractorFullName, () => []).add(row);
    }

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
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title
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
                          Text(
                            '${_rows.length} file${_rows.length != 1 ? "s" : ""} · ${grouped.length} contractor${grouped.length != 1 ? "s" : ""}',
                            style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(color: Color(0xFF21262D)),
                const SizedBox(height: 12),

                // Folder structure preview
                const Text(
                  'ZIP structure preview:',
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
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.all(12),
                      children: grouped.entries.map((e) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.folder, size: 14, color: Color(0xFFE3B341)),
                                const SizedBox(width: 6),
                                Text(
                                  e.key,
                                  style: const TextStyle(color: Color(0xFFE3B341), fontSize: 12, fontWeight: FontWeight.w600, fontFamily: 'monospace'),
                                ),
                              ],
                            ),
                            ...e.value.map(
                              (row) => Padding(
                                padding: const EdgeInsets.only(left: 20, top: 4),
                                child: Row(
                                  children: [
                                    const Text(
                                      '└ ',
                                      style: TextStyle(color: Color(0xFF484F58), fontSize: 11, fontFamily: 'monospace'),
                                    ),
                                    const Icon(Icons.insert_drive_file_outlined, size: 11, color: Color(0xFF8B949E)),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        row.safeDocumentName,
                                        style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11, fontFamily: 'monospace'),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Info note
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A84FF).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF0A84FF).withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 14, color: Color(0xFF58A6FF)),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Files will be downloaded as a ZIP with folders per contractor. Your browser will save it to your Downloads folder.',
                          style: TextStyle(color: Color(0xFF58A6FF), fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Buttons
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
      _completedCount = 0;
      _totalDownloadedBytes = 0;
      for (final row in _rows) {
        row.status = DownloadStatus.pending;
        row.errorMessage = null;
        row.fileBytes = null;
      }
    });

    // Download files one at a time to avoid overwhelming the browser
    for (int i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      setState(() => row.status = DownloadStatus.downloading);

      try {
        final uri = Uri.parse(row.url);
        final response = await http.get(uri).timeout(const Duration(seconds: 60));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          // Detect extension from Content-Type header
          final contentType = response.headers['content-type']?.split(';').first.trim().toLowerCase();
          if (contentType != null && _mimeToExt.containsKey(contentType)) {
            row.detectedExtension = _mimeToExt[contentType];
          }
          row.fileBytes = response.bodyBytes;
          row.bytes = response.bodyBytes.length;
          row.status = DownloadStatus.done;
        } else {
          row.status = DownloadStatus.error;
          row.errorMessage = 'HTTP ${response.statusCode}';
        }
      } on TimeoutException {
        row.status = DownloadStatus.error;
        row.errorMessage = 'Timed out';
      } catch (e) {
        row.status = DownloadStatus.error;
        row.errorMessage = e.toString().replaceFirst('Exception: ', '');
      }

      setState(() {
        _completedCount = i + 1;
        _totalDownloadedBytes = _rows.where((r) => r.bytes != null).fold(0, (sum, r) => sum + r.bytes!);
      });
    }

    // Build ZIP
    final successRows = _rows.where((r) => r.fileBytes != null).toList();
    if (successRows.isNotEmpty) {
      _buildAndTriggerZip(successRows);
    }

    setState(() {
      _isDownloading = false;
      _isDone = true;
    });
  }

  void _buildAndTriggerZip(List<CsvRow> rows) {
    final archive = Archive();

    for (final row in rows) {
      final bytes = row.fileBytes!;
      final file = ArchiveFile(row.zipPath, bytes.length, bytes);
      archive.addFile(file);
    }

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

  // ── Build ──────────────────────────────────────────────────────────────────

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Map<String, List<CsvRow>> get _groupedRows {
    final grouped = <String, List<CsvRow>>{};
    final source = _activeFilter == null ? _rows : _rows.where((r) => r.status == _activeFilter).toList();
    for (final row in source) {
      grouped.putIfAbsent(row.contractorFullName, () => []).add(row);
    }
    return grouped;
  }

  double get _progress => _rows.isEmpty ? 0 : _completedCount / _rows.length;

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
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF30363D), style: BorderStyle.solid),
              ),
              child: Column(
                children: [
                  const Icon(Icons.upload_file_outlined, size: 48, color: Color(0xFF30363D)),
                  const SizedBox(height: 16),
                  const Text(
                    'Import a CSV file',
                    style: TextStyle(color: Color(0xFF8B949E), fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
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
    final grouped = _groupedRows;
    final doneCount = _rows.where((r) => r.status == DownloadStatus.done).length;
    final errorCount = _rows.where((r) => r.status == DownloadStatus.error).length;

    return Expanded(
      child: Column(
        children: [
          // Progress / action bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFF161B22),
            child: Row(
              children: [
                _chip(Icons.people_outline, '${grouped.length} contractors', const Color(0xFF8B949E), null),
                const SizedBox(width: 8),
                _chip(Icons.insert_drive_file_outlined, '${_rows.length} files', const Color(0xFF8B949E), null),
                if (doneCount > 0) ...[const SizedBox(width: 8), _chip(Icons.check_circle_outline, '$doneCount done', const Color(0xFF3FB950), DownloadStatus.done)],
                if (errorCount > 0) ...[const SizedBox(width: 8), _chip(Icons.error_outline, '$errorCount errors', const Color(0xFFF85149), DownloadStatus.error)],
                if (_totalDownloadedBytes > 0) ...[const SizedBox(width: 8), _chip(Icons.storage_outlined, _formatBytes(_totalDownloadedBytes), const Color(0xFF0A84FF), null)],
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Downloading $_completedCount of ${_rows.length}...'
                        '${_totalDownloadedBytes > 0 ? '  ·  ${_formatBytes(_totalDownloadedBytes)} so far' : ''}',
                        style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
                      ),
                      Text(
                        '${(_progress * 100).toStringAsFixed(0)}%',
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

          // Grouped list
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: grouped.entries.map((entry) {
                return _ContractorGroup(contractorName: entry.key, rows: entry.value, formatBytes: _formatBytes, pulseController: _pulseController);
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, Color color, DownloadStatus? filter) {
    final isActive = _activeFilter == filter && filter != null;
    return GestureDetector(
      onTap: filter == null
          ? null
          : () => setState(() {
              _activeFilter = isActive ? null : filter;
            }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? color.withOpacity(0.25) : color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isActive ? color.withOpacity(0.8) : color.withOpacity(0.3), width: isActive ? 1.5 : 1),
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
            if (filter != null) ...[const SizedBox(width: 4), Icon(isActive ? Icons.close : Icons.filter_list, size: 11, color: color.withOpacity(0.7))],
          ],
        ),
      ),
    );
  }
}

// ─── Contractor Group Card ───────────────────────────────────────────────────

class _ContractorGroup extends StatefulWidget {
  final String contractorName;
  final List<CsvRow> rows;
  final String Function(int) formatBytes;
  final AnimationController pulseController;

  const _ContractorGroup({required this.contractorName, required this.rows, required this.formatBytes, required this.pulseController});

  @override
  State<_ContractorGroup> createState() => _ContractorGroupState();
}

class _ContractorGroupState extends State<_ContractorGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final doneCount = widget.rows.where((r) => r.status == DownloadStatus.done).length;
    final errorCount = widget.rows.where((r) => r.status == DownloadStatus.error).length;
    final isAllDone = doneCount == widget.rows.length;
    final hasErrors = errorCount > 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
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
          // Header
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.folder, size: 18, color: Color(0xFFE3B341)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.contractorName,
                      style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                  // File count badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: const Color(0xFF21262D), borderRadius: BorderRadius.circular(10)),
                    child: Text('${widget.rows.length} file${widget.rows.length != 1 ? "s" : ""}', style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
                  ),
                  if (isAllDone && !hasErrors) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.check_circle, size: 16, color: Color(0xFF3FB950)),
                  ] else if (hasErrors) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.warning_amber_outlined, size: 16, color: const Color(0xFFF85149).withOpacity(0.8)),
                  ],
                  const SizedBox(width: 8),
                  Icon(_expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 18, color: const Color(0xFF484F58)),
                ],
              ),
            ),
          ),

          // File rows
          if (_expanded) ...[
            const Divider(height: 1, color: Color(0xFF21262D)),
            ...widget.rows.map((row) => _FileRow(row: row, formatBytes: widget.formatBytes, pulseController: widget.pulseController)),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _statusIcon,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.documentName,
                  style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  row.url,
                  style: const TextStyle(color: Color(0xFF484F58), fontSize: 10, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                if (row.status == DownloadStatus.downloading) ...[
                  const SizedBox(height: 6),
                  AnimatedBuilder(
                    animation: pulseController,
                    builder: (_, __) => LinearProgressIndicator(
                      backgroundColor: const Color(0xFF21262D),
                      valueColor: AlwaysStoppedAnimation(Color.lerp(const Color(0xFF0A84FF), const Color(0xFF58A6FF), pulseController.value)!),
                      borderRadius: BorderRadius.circular(2),
                      minHeight: 2,
                    ),
                  ),
                ],
                if (row.status == DownloadStatus.error && row.errorMessage != null) ...[
                  const SizedBox(height: 4),
                  Text(row.errorMessage!, style: const TextStyle(color: Color(0xFFF85149), fontSize: 11)),
                ],
              ],
            ),
          ),
          if (row.bytes != null)
            Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Text(
                formatBytes(row.bytes!),
                style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
        ],
      ),
    );
  }

  Widget get _statusIcon {
    switch (row.status) {
      case DownloadStatus.done:
        return const Icon(Icons.check_circle, size: 16, color: Color(0xFF3FB950));
      case DownloadStatus.error:
        return const Icon(Icons.cancel_outlined, size: 16, color: Color(0xFFF85149));
      case DownloadStatus.downloading:
        return SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: const Color(0xFF0A84FF)));
      case DownloadStatus.pending:
        return const Icon(Icons.schedule, size: 16, color: Color(0xFF484F58));
      case DownloadStatus.idle:
        return const Icon(Icons.circle_outlined, size: 16, color: Color(0xFF30363D));
    }
  }
}
