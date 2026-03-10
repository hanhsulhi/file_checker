import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

// ─── Constants ───────────────────────────────────────────────────────────────

const int _kConcurrency = 6;
const Duration _kUiThrottle = Duration(milliseconds: 250);
const int _kPageSize = 30; // contractors per page

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

// ─── JS interop — File System Access API ─────────────────────────────────────
// Use dart:js_interop's JSPromise.toDart (no custom .then extension needed).

@JS('showSaveFilePicker')
external JSPromise<JSObject> _showSaveFilePicker(JSObject options);

@JS('Object.prototype.hasOwnProperty.call')
external JSBoolean _jsHas(JSObject obj, JSString key);

bool get _fsSaveSupported {
  try {
    return _jsHas(web.window as JSObject, 'showSaveFilePicker'.toJS).toDart;
  } catch (_) {
    return false;
  }
}

// Call a method by name on a JSObject and return its JSPromise result.
// We use js_interop's .toDart on JSPromise<T> for all async calls.
@JS('Reflect.get')
external JSAny? _jsGet(JSObject target, JSString prop);

// Call a JS method that returns a Promise<void> (write, close, etc.)
Future<void> _callVoid(JSObject obj, String method, [JSAny? arg]) {
  final fn = _jsGet(obj, method.toJS) as JSFunction;
  final JSAny? result = arg != null
      ? fn.callAsFunction(obj, arg)
      : fn.callAsFunction(obj);
  if (result == null) return Future.value();
  return (result as JSPromise<JSAny?>).toDart;
}

// Call a JS method that returns a Promise<JSObject> (createWritable, etc.)
Future<JSObject> _callObject(JSObject obj, String method, [JSAny? arg]) {
  final fn = _jsGet(obj, method.toJS) as JSFunction;
  final JSAny? result = arg != null
      ? fn.callAsFunction(obj, arg)
      : fn.callAsFunction(obj);
  return (result! as JSPromise<JSObject>).toDart;
}

// ─── Disk sink ────────────────────────────────────────────────────────────────

class _DiskZipSink {
  final JSObject _writer;
  _DiskZipSink._(this._writer);

  static Future<_DiskZipSink?> open(String suggestedName) async {
    try {
      final opts = {
        'suggestedName': suggestedName,
        'types': [
          {
            'description': 'ZIP archive',
            'accept': {'application/zip': ['.zip']},
          }
        ],
      }.jsify()! as JSObject;

      final fileHandle = await _showSaveFilePicker(opts).toDart;
      final writer = await _callObject(fileHandle, 'createWritable');
      return _DiskZipSink._(writer);
    } catch (_) {
      return null; // user cancelled or API unsupported
    }
  }

  Future<void> write(Uint8List data) => _callVoid(_writer, 'write', data.toJS);
  Future<void> close() => _callVoid(_writer, 'close');
}

// ─── Memory fallback sink ─────────────────────────────────────────────────────

class _MemoryZipSink {
  final _chunks = <Uint8List>[];
  int _total = 0;

  void write(Uint8List data) {
    _chunks.add(data);
    _total += data.length;
  }

  void triggerDownload(String filename) {
    final out = Uint8List(_total);
    int off = 0;
    for (final c in _chunks) {
      out.setRange(off, off + c.length, c);
      off += c.length;
    }
    _chunks.clear();

    final blob = web.Blob(
      [out.toJS].toJS,
      web.BlobPropertyBag(type: 'application/zip'),
    );
    final url = web.URL.createObjectURL(blob);
    final a = web.document.createElement('a') as web.HTMLAnchorElement;
    a.href = url;
    a.download = filename;
    a.click();
    web.URL.revokeObjectURL(url);
  }
}

// ─── ZIP writer (PKWARE spec, files stored uncompressed) ─────────────────────

class _ZipWriter {
  int offset = 0;
  final cdEntries = <Uint8List>[];

  static Uint8List buildLocalHeader(String path, Uint8List bytes) {
    final name = _utf8(path);
    final h = ByteData(30 + name.length);
    int o = 0;
    h.setUint32(o, 0x04034b50, Endian.little); o += 4;
    h.setUint16(o, 20, Endian.little); o += 2;
    h.setUint16(o, 0, Endian.little); o += 2;
    h.setUint16(o, 0, Endian.little); o += 2; // STORED
    h.setUint16(o, 0, Endian.little); o += 2;
    h.setUint16(o, 0, Endian.little); o += 2;
    h.setUint32(o, _crc32(bytes), Endian.little); o += 4;
    h.setUint32(o, bytes.length, Endian.little); o += 4;
    h.setUint32(o, bytes.length, Endian.little); o += 4;
    h.setUint16(o, name.length, Endian.little); o += 2;
    h.setUint16(o, 0, Endian.little);
    final buf = h.buffer.asUint8List();
    for (int i = 0; i < name.length; i++) buf[30 + i] = name[i];
    return buf;
  }

  Uint8List buildCdEntry(String path, Uint8List bytes, int localOffset) {
    final name = _utf8(path);
    final e = ByteData(46 + name.length);
    int o = 0;
    e.setUint32(o, 0x02014b50, Endian.little); o += 4;
    e.setUint16(o, 20, Endian.little); o += 2;
    e.setUint16(o, 20, Endian.little); o += 2;
    e.setUint16(o, 0, Endian.little); o += 2;
    e.setUint16(o, 0, Endian.little); o += 2;
    e.setUint16(o, 0, Endian.little); o += 2;
    e.setUint16(o, 0, Endian.little); o += 2;
    e.setUint32(o, _crc32(bytes), Endian.little); o += 4;
    e.setUint32(o, bytes.length, Endian.little); o += 4;
    e.setUint32(o, bytes.length, Endian.little); o += 4;
    e.setUint16(o, name.length, Endian.little); o += 2;
    e.setUint16(o, 0, Endian.little); o += 2;
    e.setUint16(o, 0, Endian.little); o += 2;
    e.setUint16(o, 0, Endian.little); o += 2;
    e.setUint16(o, 0, Endian.little); o += 2;
    e.setUint32(o, 0, Endian.little); o += 4;
    e.setUint32(o, localOffset, Endian.little);
    final buf = e.buffer.asUint8List();
    for (int i = 0; i < name.length; i++) buf[46 + i] = name[i];
    return buf;
  }

  Uint8List buildEocd(int cdOffset, int cdSize) {
    final e = ByteData(22);
    int o = 0;
    e.setUint32(o, 0x06054b50, Endian.little); o += 4;
    e.setUint16(o, 0, Endian.little); o += 2;
    e.setUint16(o, 0, Endian.little); o += 2;
    e.setUint16(o, cdEntries.length, Endian.little); o += 2;
    e.setUint16(o, cdEntries.length, Endian.little); o += 2;
    e.setUint32(o, cdSize, Endian.little); o += 4;
    e.setUint32(o, cdOffset, Endian.little); o += 4;
    e.setUint16(o, 0, Endian.little);
    return e.buffer.asUint8List();
  }

  static final _crcTable = () {
    final t = List<int>.filled(256, 0);
    for (int n = 0; n < 256; n++) {
      int c = n;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      t[n] = c;
    }
    return t;
  }();

  static int _crc32(Uint8List d) {
    int c = 0xFFFFFFFF;
    for (final b in d) c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFF;
  }

  static Uint8List _utf8(String s) {
    bool ascii = true;
    for (final c in s.codeUnits) {
      if (c > 127) { ascii = false; break; }
    }
    if (ascii) return Uint8List.fromList(s.codeUnits);
    final out = <int>[];
    for (final r in s.runes) {
      if (r < 0x80) {
        out.add(r);
      } else if (r < 0x800) {
        out.add(0xC0 | (r >> 6));
        out.add(0x80 | (r & 0x3F));
      } else {
        out.add(0xE0 | (r >> 12));
        out.add(0x80 | ((r >> 6) & 0x3F));
        out.add(0x80 | (r & 0x3F));
      }
    }
    return Uint8List.fromList(out);
  }
}

// Sync ZIP (memory fallback)
class _SyncZip {
  final void Function(Uint8List) sink;
  final _w = _ZipWriter();
  _SyncZip(this.sink);

  void addFile(String path, Uint8List bytes) {
    final localOff = _w.offset;
    final hdr = _ZipWriter.buildLocalHeader(path, bytes);
    sink(hdr);
    sink(bytes);
    _w.offset += hdr.length + bytes.length;
    _w.cdEntries.add(_w.buildCdEntry(path, bytes, localOff));
  }

  void close() {
    final cdOff = _w.offset;
    int cdSize = 0;
    for (final e in _w.cdEntries) { sink(e); cdSize += e.length; }
    sink(_w.buildEocd(cdOff, cdSize));
  }
}

// Async ZIP (disk streaming) — mutex keeps entries ordered.
// CRC, size, header, and CD entry are computed synchronously from `bytes`
// BEFORE any await, so the caller zeroing `b` afterwards is safe.
class _AsyncZip {
  final Future<void> Function(Uint8List) sink;
  final _w = _ZipWriter();
  final _mutex = _Semaphore(1);
  _AsyncZip(this.sink);

  Future<void> addFile(String path, Uint8List bytes) async {
    // Compute & copy synchronously before any await
    final hdr = _ZipWriter.buildLocalHeader(path, bytes);
    final bodyCopy = Uint8List.fromList(bytes); // caller may zero `bytes` after await
    final size = bytes.length;

    await _mutex.acquire();
    try {
      final localOff = _w.offset;
      _w.cdEntries.add(_w.buildCdEntry(path, bodyCopy, localOff));
      await sink(hdr);
      await sink(bodyCopy);
      _w.offset += hdr.length + size;
    } finally {
      _mutex.release();
    }
  }

  Future<void> close() async {
    final cdOff = _w.offset;
    int cdSize = 0;
    for (final e in _w.cdEntries) { await sink(e); cdSize += e.length; }
    await sink(_w.buildEocd(cdOff, cdSize));
  }
}

// ─── Semaphore ────────────────────────────────────────────────────────────────

class _Semaphore {
  final int _max;
  int _count = 0;
  final _q = <Completer<void>>[];
  _Semaphore(this._max);

  Future<void> acquire() async {
    if (_count < _max) { _count++; return; }
    final c = Completer<void>();
    _q.add(c);
    await c.future;
    _count++;
  }

  void release() {
    _count--;
    if (_q.isNotEmpty) _q.removeAt(0).complete();
  }
}

// ─── Data Models ─────────────────────────────────────────────────────────────

enum DownloadStatus { idle, pending, downloading, done, error }

class CsvRow {
  final String contractorFullName;
  final String documentName;
  final String url;
  DownloadStatus status;
  String? errorMessage;
  int? bytes;
  String? detectedExtension;

  CsvRow({
    required this.contractorFullName,
    required this.documentName,
    required this.url,
    this.status = DownloadStatus.idle,
    this.errorMessage,
    this.bytes,
    this.detectedExtension,
  });

  String get safeContractorName =>
      contractorFullName.replaceAll(RegExp(r'[<>:"/\\|?*\n\r\t]'), '_').trim();
  String get safeDocumentName =>
      documentName.replaceAll(RegExp(r'[<>:"/\\|?*\n\r\t]'), '_').trim();

  String get fileExtension {
    final p = documentName.split('.');
    if (p.length > 1 && p.last.length >= 2 && p.last.length <= 5) return '.${p.last}';
    if (detectedExtension != null && detectedExtension!.isNotEmpty) return detectedExtension!;
    try {
      final uri = Uri.parse(url);
      final seg = uri.pathSegments.lastWhere((s) => s.contains('.'), orElse: () => '');
      if (seg.isNotEmpty) {
        final ext = '.${seg.split('.').last.split('?').first}';
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

class _ContractorSummary {
  final String name;
  final List<int> indices = [];
  _ContractorSummary({required this.name});
}

class _DownloadState {
  int completed = 0;
  int totalBytes = 0;
  int doneCount = 0;
  int errorCount = 0;
}

// ─── CSV Parser ───────────────────────────────────────────────────────────────

List<CsvRow> parseCsv(String csvText) {
  final lines = csvText.split('\n').map((l) => l.trimRight()).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty) return [];

  final header = _splitCsvLine(lines.first).map((h) => h.trim().toLowerCase()).toList();
  final ci = header.indexWhere((h) => h == 'contractorfullname' || h == 'contractor_full_name' || h == 'contractor');
  final di = header.indexWhere((h) => h == 'documentname' || h == 'document_name' || h == 'document');
  final ui = header.indexWhere((h) => h == 'url' || h == 'link');

  if (ci == -1 || di == -1 || ui == -1) {
    throw Exception('CSV must have columns: ContractorFullName, DocumentName, Url');
  }

  final rows = <CsvRow>[];
  for (int i = 1; i < lines.length; i++) {
    final cols = _splitCsvLine(lines[i]);
    final maxIdx = [ci, di, ui].reduce((a, b) => a > b ? a : b);
    if (cols.length > maxIdx) {
      final contractor = cols[ci].trim();
      final document = cols[di].trim();
      final url = cols[ui].trim();
      if (contractor.isNotEmpty && url.isNotEmpty) {
        rows.add(CsvRow(
          contractorFullName: contractor,
          documentName: document.isEmpty ? 'Document_$i' : document,
          url: url,
        ));
      }
    }
  }
  return rows;
}

List<String> _splitCsvLine(String line) {
  final result = <String>[];
  final buf = StringBuffer();
  bool inQ = false;
  for (int i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (inQ && i + 1 < line.length && line[i + 1] == '"') { buf.write('"'); i++; }
      else { inQ = !inQ; }
    } else if (ch == ',' && !inQ) {
      result.add(buf.toString()); buf.clear();
    } else {
      buf.write(ch);
    }
  }
  result.add(buf.toString());
  return result;
}

// ─── Main Page ────────────────────────────────────────────────────────────────

class CsvDownloaderPage extends StatefulWidget {
  const CsvDownloaderPage({super.key});

  @override
  State<CsvDownloaderPage> createState() => _CsvDownloaderPageState();
}

class _CsvDownloaderPageState extends State<CsvDownloaderPage>
    with TickerProviderStateMixin {
  List<CsvRow> _rows = [];
  List<_ContractorSummary> _contractors = [];

  bool _isDownloading = false;
  bool _isDone = false;
  bool _isRetrying = false;
  String? _parseError;
  String? _csvFileName;
  String? _statusMessage;
  DownloadStatus? _statusFilter; // null = show all

  // Pagination
  int _currentPage = 0;

  // Filtered contractors (respects _statusFilter)
  List<_ContractorSummary> get _filteredContractors {
    if (_statusFilter == null) return _contractors;
    return _contractors.where((c) =>
      c.indices.any((i) => _rows[i].status == _statusFilter)).toList();
  }

  int get _totalPages => (_filteredContractors.length / _kPageSize).ceil();
  List<_ContractorSummary> get _pageContractors {
    final start = _currentPage * _kPageSize;
    final end = (start + _kPageSize).clamp(0, _filteredContractors.length);
    return _filteredContractors.sublist(start, end);
  }

  List<CsvRow> get _failedRows =>
      _rows.where((r) => r.status == DownloadStatus.error).toList();

  final _dl = _DownloadState();
  Timer? _uiTimer;
  bool _uiDirty = false;

  late AnimationController _pulseController;
  final _httpClient = http.Client();

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _pulseController.dispose();
    _httpClient.close();
    super.dispose();
  }

  void _markDirty() {
    _uiDirty = true;
    _uiTimer ??= Timer.periodic(_kUiThrottle, (_) {
      if (_uiDirty && mounted) setState(() => _uiDirty = false);
    });
  }

  void _stopUiTimer() {
    _uiTimer?.cancel();
    _uiTimer = null;
    if (mounted) setState(() {});
  }

  // ── CSV Import ────────────────────────────────────────────────────────────

  void _importCsv() {
    final input = web.document.createElement('input') as web.HTMLInputElement;
    input.type = 'file';
    input.accept = '.csv,text/csv';
    input.click();
    input.onchange = (web.Event _) {
      final files = input.files;
      if (files == null || files.length == 0) return;
      final file = files.item(0)!;
      _csvFileName = file.name;
      final reader = web.FileReader();
      reader.readAsText(file);
      reader.onload = (web.Event _) {
        final result = reader.result;
        if (result == null) return;
        try {
          final rows = parseCsv(result.toString());
          if (rows.isEmpty) throw Exception('No valid rows found in CSV');
          final contractors = _buildSummaries(rows);
          setState(() {
            _rows = rows;
            _contractors = contractors;
            _parseError = null;
            _isDone = false;
            _statusMessage = null;
            _currentPage = 0;
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

  List<_ContractorSummary> _buildSummaries(List<CsvRow> rows) {
    final map = <String, _ContractorSummary>{};
    for (int i = 0; i < rows.length; i++) {
      final n = rows[i].contractorFullName;
      map.putIfAbsent(n, () => _ContractorSummary(name: n));
      map[n]!.indices.add(i);
    }
    return map.values.toList();
  }

  // ── Confirm Dialog ────────────────────────────────────────────────────────

  void _showConfirmDialog() {
    final fsSave = _fsSaveSupported;
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
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 580),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A84FF).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.folder_zip_outlined, color: Color(0xFF0A84FF), size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Ready to Download',
                          style: TextStyle(color: Color(0xFFE6EDF3), fontSize: 16, fontWeight: FontWeight.w600)),
                      Text('${_rows.length} files · ${_contractors.length} contractors',
                          style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
                    ],
                  )),
                ]),
                const SizedBox(height: 14),
                const Divider(color: Color(0xFF21262D)),
                const SizedBox(height: 8),
                const Text('Contractor folders:',
                    style: TextStyle(color: Color(0xFF8B949E), fontSize: 11, fontWeight: FontWeight.w500)),
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
                      padding: const EdgeInsets.all(10),
                      itemCount: _contractors.length,
                      itemBuilder: (_, i) {
                        final c = _contractors[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(children: [
                            const Icon(Icons.folder, size: 13, color: Color(0xFFE3B341)),
                            const SizedBox(width: 6),
                            Expanded(child: Text(c.name,
                                style: const TextStyle(color: Color(0xFFE3B341), fontSize: 12, fontFamily: 'monospace'),
                                overflow: TextOverflow.ellipsis)),
                            Text('${c.indices.length}',
                                style: const TextStyle(color: Color(0xFF484F58), fontSize: 11)),
                          ]),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Storage mode indicator
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (fsSave ? const Color(0xFF3FB950) : const Color(0xFFF0883E)).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: (fsSave ? const Color(0xFF3FB950) : const Color(0xFFF0883E)).withOpacity(0.25)),
                  ),
                  child: Row(children: [
                    Icon(fsSave ? Icons.save_outlined : Icons.memory_outlined,
                        size: 14,
                        color: fsSave ? const Color(0xFF3FB950) : const Color(0xFFF0883E)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(
                      fsSave
                          ? 'Disk streaming mode — writes directly to disk. RAM stays near zero.'
                          : 'In-memory mode — ZIP is built in browser memory. Use Chrome for disk streaming.',
                      style: TextStyle(
                          color: fsSave ? const Color(0xFF3FB950) : const Color(0xFFF0883E),
                          fontSize: 11),
                    )),
                  ]),
                ),
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFF8B949E)),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () { Navigator.pop(ctx); _startDownload(); },
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Download ZIP'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0A84FF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Download ──────────────────────────────────────────────────────────────

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _isDone = false;
      _statusMessage = null;
      _dl.completed = 0;
      _dl.totalBytes = 0;
      _dl.doneCount = 0;
      _dl.errorCount = 0;
      for (final r in _rows) {
        r.status = DownloadStatus.pending;
        r.errorMessage = null;
        r.bytes = null;
        r.detectedExtension = null;
      }
    });

    if (_fsSaveSupported) {
      await _runDiskStreaming();
    } else {
      await _runMemoryFallback();
    }

    _stopUiTimer();
    setState(() { _isDownloading = false; _isDone = true; _statusMessage = null; });
  }

  Future<void> _startRetry() async {
    final failed = _failedRows;
    if (failed.isEmpty) return;

    // Show confirm dialog
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF30363D)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF85149).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.refresh, color: Color(0xFFF85149), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Retry Failed Files',
                      style: TextStyle(color: Color(0xFFE6EDF3), fontSize: 16, fontWeight: FontWeight.w600)),
                  Text('\${failed.length} files failed — will generate a separate ZIP',
                      style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
                ])),
              ]),
              const SizedBox(height: 14),
              const Divider(color: Color(0xFF21262D)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A84FF).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF0A84FF).withOpacity(0.25)),
                ),
                child: Row(children: [
                  const Icon(Icons.info_outline, size: 14, color: Color(0xFF0A84FF)),
                  const SizedBox(width: 8),
                  const Expanded(child: Text(
                    'The original ZIP is unchanged. Failed files will be saved to a new ZIP named contractor_documents_retry.zip',
                    style: TextStyle(color: Color(0xFF0A84FF), fontSize: 11),
                  )),
                ]),
              ),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: TextButton.styleFrom(foregroundColor: const Color(0xFF8B949E)),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text('Retry \${failed.length} files'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF85149),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isRetrying = true;
      _isDownloading = true;
      _isDone = false;
      _statusMessage = null;
      // Reset only failed rows
      for (final r in failed) {
        r.status = DownloadStatus.pending;
        r.errorMessage = null;
        r.bytes = null;
        r.detectedExtension = null;
      }
      _dl.errorCount = 0;
      _dl.completed = 0;
    });

    if (_fsSaveSupported) {
      await _runDiskStreamingRows(failed, 'contractor_documents_retry.zip');
    } else {
      await _runMemoryFallbackRows(failed, 'contractor_documents_retry.zip');
    }

    _stopUiTimer();
    setState(() { _isDownloading = false; _isDone = true; _isRetrying = false; _statusMessage = null; });
  }

  Future<void> _runDiskStreaming() async {
    await _runDiskStreamingRows(_rows, 'contractor_documents.zip');
  }

  Future<void> _runDiskStreamingRows(List<CsvRow> rows, String filename) async {
    setState(() => _statusMessage = 'Choose where to save the ZIP...');
    final sink = await _DiskZipSink.open(filename);
    if (sink == null) {
      // User cancelled — mark all pending rows back to idle
      for (final r in _rows) {
        if (r.status == DownloadStatus.pending) r.status = DownloadStatus.idle;
      }
      _stopUiTimer();
      setState(() { _isDownloading = false; _isDone = false; _statusMessage = null; });
      return;
    }
    setState(() => _statusMessage = 'Downloading...');
    final zip = _AsyncZip(sink.write);
    final sem = _Semaphore(_kConcurrency);

    await Future.wait(List.generate(rows.length, (i) async {
      await sem.acquire();
      if (!mounted) { sem.release(); return; }
      final row = rows[i];
      row.status = DownloadStatus.downloading;
      _markDirty();
      try {
        final res = await _httpClient.get(Uri.parse(row.url)).timeout(const Duration(seconds: 60));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          Uint8List b = res.bodyBytes;
          row.bytes = b.length;
          final ct = res.headers['content-type']?.split(';').first.trim().toLowerCase();
          if (ct != null && _mimeToExt.containsKey(ct)) row.detectedExtension = _mimeToExt[ct];
          await zip.addFile(row.zipPath, b);
          b = Uint8List(0);
          row.status = DownloadStatus.done;
          _dl.doneCount++;
          _dl.totalBytes += row.bytes!;
        } else {
          row.status = DownloadStatus.error;
          row.errorMessage = 'HTTP ${res.statusCode}';
          _dl.errorCount++;
        }
      } on TimeoutException {
        row.status = DownloadStatus.error; row.errorMessage = 'Timed out'; _dl.errorCount++;
      } catch (e) {
        row.status = DownloadStatus.error;
        row.errorMessage = e.toString().replaceFirst('Exception: ', '');
        _dl.errorCount++;
      } finally {
        _dl.completed++;
        sem.release();
        _markDirty();
      }
    }));

    setState(() => _statusMessage = 'Finalising ZIP on disk...');
    await zip.close();
    await sink.close();
  }

  Future<void> _runMemoryFallback() async {
    await _runMemoryFallbackRows(_rows, 'contractor_documents.zip');
  }

  Future<void> _runMemoryFallbackRows(List<CsvRow> rows, String filename) async {
    setState(() => _statusMessage = 'Downloading...');
    final memorySink = _MemoryZipSink();
    final zip = _SyncZip(memorySink.write);
    final sem = _Semaphore(_kConcurrency);
    final zipMutex = _Semaphore(1);

    await Future.wait(List.generate(rows.length, (i) async {
      await sem.acquire();
      if (!mounted) { sem.release(); return; }
      final row = rows[i];
      row.status = DownloadStatus.downloading;
      _markDirty();
      try {
        final res = await _httpClient.get(Uri.parse(row.url)).timeout(const Duration(seconds: 60));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          Uint8List b = res.bodyBytes;
          row.bytes = b.length;
          final ct = res.headers['content-type']?.split(';').first.trim().toLowerCase();
          if (ct != null && _mimeToExt.containsKey(ct)) row.detectedExtension = _mimeToExt[ct];
          await zipMutex.acquire();
          try { zip.addFile(row.zipPath, b); } finally { zipMutex.release(); }
          b = Uint8List(0);
          row.status = DownloadStatus.done;
          _dl.doneCount++;
          _dl.totalBytes += row.bytes!;
        } else {
          row.status = DownloadStatus.error;
          row.errorMessage = 'HTTP ${res.statusCode}';
          _dl.errorCount++;
        }
      } on TimeoutException {
        row.status = DownloadStatus.error; row.errorMessage = 'Timed out'; _dl.errorCount++;
      } catch (e) {
        row.status = DownloadStatus.error;
        row.errorMessage = e.toString().replaceFirst('Exception: ', '');
        _dl.errorCount++;
      } finally {
        _dl.completed++;
        sem.release();
        _markDirty();
      }
    }));

    setState(() => _statusMessage = 'Saving ZIP...');
    zip.close();
    memorySink.triggerDownload(filename);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  double get _progress {
    if (_rows.isEmpty) return 0;
    if (_isRetrying) {
      final total = _failedRows.length + _dl.completed;
      return total == 0 ? 0 : _dl.completed / total;
    }
    return _dl.completed / _rows.length;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: SafeArea(
        child: Column(children: [
          _buildHeader(),
          if (_rows.isEmpty) _buildEmptyState() else _buildContent(),
        ]),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFE3B341).withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.folder_zip_outlined, color: Color(0xFFE3B341), size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('CSV Bulk Downloader',
                style: TextStyle(color: Color(0xFFE6EDF3), fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.3)),
            Text(
              _csvFileName != null ? 'Loaded: $_csvFileName' : 'Import a CSV to download files by contractor',
              style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
            ),
          ],
        )),
        if (!_isDownloading)
          FilledButton.icon(
            onPressed: _importCsv,
            icon: const Icon(Icons.upload_file, size: 15),
            label: Text(_rows.isEmpty ? 'Import CSV' : 'Re-import'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF21262D),
              foregroundColor: const Color(0xFFE6EDF3),
              side: const BorderSide(color: Color(0xFF30363D)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
      ]),
    );
  }

  Widget _buildEmptyState() {
    return Expanded(
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF30363D)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.upload_file_outlined, size: 48, color: Color(0xFF30363D)),
            const SizedBox(height: 16),
            const Text('Import a CSV file',
                style: TextStyle(color: Color(0xFF8B949E), fontSize: 15, fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            const Text('Required columns: ContractorFullName, DocumentName, Url',
                style: TextStyle(color: Color(0xFF484F58), fontSize: 12)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _importCsv,
              icon: const Icon(Icons.upload_file, size: 17),
              label: const Text('Choose CSV File'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE3B341),
                foregroundColor: const Color(0xFF0D1117),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            if (_parseError != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF85149).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFF85149).withOpacity(0.3)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.error_outline, size: 14, color: Color(0xFFF85149)),
                  const SizedBox(width: 8),
                  Text(_parseError!, style: const TextStyle(color: Color(0xFFF85149), fontSize: 12)),
                ]),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Expanded(
      child: Column(children: [
        // ── Summary / action bar ───────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          color: const Color(0xFF161B22),
          child: Row(children: [
            _chip(Icons.people_outline, '${_contractors.length} contractors', const Color(0xFF8B949E)),
            const SizedBox(width: 6),
            _chip(Icons.insert_drive_file_outlined, '${_rows.length} files', const Color(0xFF8B949E)),
            if (_dl.doneCount > 0) ...[
              const SizedBox(width: 6),
              _filterChip(Icons.check_circle_outline, '${_dl.doneCount} done',
                  const Color(0xFF3FB950), DownloadStatus.done),
            ],
            if (_dl.errorCount > 0) ...[
              const SizedBox(width: 6),
              _filterChip(Icons.error_outline, '${_dl.errorCount} errors',
                  const Color(0xFFF85149), DownloadStatus.error),
            ],
            if (_dl.totalBytes > 0) ...[
              const SizedBox(width: 6),
              _chip(Icons.storage_outlined, _fmt(_dl.totalBytes), const Color(0xFF0A84FF)),
            ],
            const Spacer(),
            if (!_isDownloading && !_isDone)
              FilledButton.icon(
                onPressed: _showConfirmDialog,
                icon: const Icon(Icons.download, size: 15),
                label: const Text('Download ZIP'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE3B341),
                  foregroundColor: const Color(0xFF0D1117),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            if (_isDone) ...[
              FilledButton.icon(
                onPressed: _showConfirmDialog,
                icon: const Icon(Icons.download, size: 15),
                label: const Text('Download Again'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF21262D),
                  foregroundColor: const Color(0xFFE6EDF3),
                  side: const BorderSide(color: Color(0xFF30363D)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              if (_failedRows.isNotEmpty) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _startRetry,
                  icon: const Icon(Icons.refresh, size: 15),
                  label: Text('Retry \${_failedRows.length} failed'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF85149),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ],
          ]),
        ),

        // ── Progress bar ──────────────────────────────────────────────────
        if (_isDownloading)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(
                  _statusMessage ??
                      '${_isRetrying ? "Retrying" : "Downloading"} ${_dl.completed} of ${_isRetrying ? _failedRows.length + _dl.completed : _rows.length}'
                      '${_dl.totalBytes > 0 ? "  ·  ${_fmt(_dl.totalBytes)} so far" : ""}',
                  style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11),
                ),
                Text('${(_progress * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(
                        color: Color(0xFF0A84FF), fontSize: 11, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 5),
              AnimatedBuilder(
                animation: _pulseController,
                builder: (_, __) => LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: const Color(0xFF21262D),
                  valueColor: AlwaysStoppedAnimation(
                    Color.lerp(const Color(0xFF0A84FF), const Color(0xFF58A6FF), _pulseController.value)!,
                  ),
                  borderRadius: BorderRadius.circular(4),
                  minHeight: 6,
                ),
              ),
            ]),
          ),

        const Divider(height: 1, color: Color(0xFF21262D)),

        // ── Filter banner ─────────────────────────────────────────────────
        if (_statusFilter != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            color: const Color(0xFF0A84FF).withOpacity(0.07),
            child: Row(children: [
              const Icon(Icons.filter_list, size: 13, color: Color(0xFF0A84FF)),
              const SizedBox(width: 6),
              Text(
                'Showing ${_statusFilter == DownloadStatus.done ? "completed" : "failed"} files only'
                ' · ${_filteredContractors.length} contractor${_filteredContractors.length == 1 ? "" : "s"}',
                style: const TextStyle(color: Color(0xFF0A84FF), fontSize: 11),
              ),
              const Spacer(),
              InkWell(
                onTap: () => setState(() { _statusFilter = null; _currentPage = 0; }),
                borderRadius: BorderRadius.circular(4),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text('Clear filter', style: TextStyle(color: Color(0xFF0A84FF), fontSize: 11,
                      decoration: TextDecoration.underline, decorationColor: Color(0xFF0A84FF))),
                ),
              ),
            ]),
          ),

        // ── Paginated contractor list ─────────────────────────────────────
        Expanded(
          child: Column(children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: _pageContractors.length,
                itemBuilder: (ctx, i) => RepaintBoundary(
                  child: _ContractorGroupTile(
                    key: ValueKey('${_currentPage}_${_pageContractors[i].name}_${_statusFilter?.name}'),
                    summary: _pageContractors[i],
                    allRows: _rows,
                    formatBytes: _fmt,
                    pulseController: _pulseController,
                    statusFilter: _statusFilter,
                  ),
                ),
              ),
            ),
            if (_totalPages > 1) _buildPaginator(),
          ]),
        ),
      ]),
    );
  }

  Widget _buildPaginator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(top: BorderSide(color: Color(0xFF21262D))),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        // Prev
        _pageBtn(Icons.chevron_left, _currentPage > 0, () {
          setState(() => _currentPage--);
        }),
        const SizedBox(width: 8),
        // Page number buttons (show up to 7 around current)
        ..._pageNumbers().map((p) {
          if (p == -1) {
            return const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text('…', style: TextStyle(color: Color(0xFF484F58), fontSize: 13)),
            );
          }
          final selected = p == _currentPage;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              onTap: () => setState(() => _currentPage = p),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFF0A84FF) : const Color(0xFF21262D),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: selected ? const Color(0xFF0A84FF) : const Color(0xFF30363D),
                  ),
                ),
                child: Text(
                  '${p + 1}',
                  style: TextStyle(
                    color: selected ? Colors.white : const Color(0xFF8B949E),
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          );
        }),
        const SizedBox(width: 8),
        // Next
        _pageBtn(Icons.chevron_right, _currentPage < _totalPages - 1, () {
          setState(() => _currentPage++);
        }),
        const SizedBox(width: 12),
        Text(
          'Page ${_currentPage + 1} of $_totalPages  ·  ${_filteredContractors.length}${_statusFilter != null ? " filtered" : ""} contractors',
          style: const TextStyle(color: Color(0xFF484F58), fontSize: 11),
        ),
      ]),
    );
  }

  Widget _pageBtn(IconData icon, bool enabled, VoidCallback onTap) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF21262D),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF30363D)),
        ),
        child: Icon(icon, size: 18,
            color: enabled ? const Color(0xFF8B949E) : const Color(0xFF30363D)),
      ),
    );
  }

  // Returns page indices to display, using -1 for ellipsis
  List<int> _pageNumbers() {
    final total = _totalPages;
    if (total <= 7) return List.generate(total, (i) => i);
    final cur = _currentPage;
    final pages = <int>[];
    pages.add(0);
    if (cur > 2) pages.add(-1); // left ellipsis
    for (int p = (cur - 1).clamp(1, total - 2); p <= (cur + 1).clamp(1, total - 2); p++) {
      pages.add(p);
    }
    if (cur < total - 3) pages.add(-1); // right ellipsis
    pages.add(total - 1);
    return pages;
  }

  Widget _chip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  Widget _filterChip(IconData icon, String label, Color color, DownloadStatus filter) {
    final active = _statusFilter == filter;
    return Tooltip(
      message: active ? 'Clear filter' : 'Show only these',
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: () => setState(() {
          _statusFilter = active ? null : filter;
          _currentPage = 0;
        }),
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: active ? color.withOpacity(0.25) : color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? color.withOpacity(0.9) : color.withOpacity(0.3),
              width: active ? 1.5 : 1,
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500)),
            if (active) ...[
              const SizedBox(width: 4),
              Icon(Icons.close, size: 10, color: color),
            ],
          ]),
        ),
      ),
    );
  }
}

// ─── Contractor Group Tile ────────────────────────────────────────────────────

class _ContractorGroupTile extends StatefulWidget {
  final _ContractorSummary summary;
  final List<CsvRow> allRows;
  final String Function(int) formatBytes;
  final AnimationController pulseController;
  final DownloadStatus? statusFilter;

  const _ContractorGroupTile({
    super.key,
    required this.summary,
    required this.allRows,
    required this.formatBytes,
    required this.pulseController,
    this.statusFilter,
  });

  @override
  State<_ContractorGroupTile> createState() => _ContractorGroupTileState();
}

class _ContractorGroupTileState extends State<_ContractorGroupTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final allRows = widget.summary.indices.map((i) => widget.allRows[i]).toList();
    // When filter active, only show matching rows in expanded view
    final visibleRows = widget.statusFilter != null
        ? allRows.where((r) => r.status == widget.statusFilter).toList()
        : allRows;
    // Auto-expand when filter is active
    final isExpanded = widget.statusFilter != null ? true : _expanded;

    final doneCount = allRows.where((r) => r.status == DownloadStatus.done).length;
    final errorCount = allRows.where((r) => r.status == DownloadStatus.error).length;
    final isAllDone = doneCount == allRows.length && allRows.isNotEmpty;
    final hasErrors = errorCount > 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
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
      child: Column(children: [
        InkWell(
          onTap: widget.statusFilter != null ? null : () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              const Icon(Icons.folder, size: 16, color: Color(0xFFE3B341)),
              const SizedBox(width: 10),
              Expanded(child: Text(widget.summary.name,
                  style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 13, fontWeight: FontWeight.w600))),
              if (doneCount > 0 || errorCount > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    widget.statusFilter != null
                        ? '${visibleRows.length} shown'
                        : '$doneCount/${allRows.length}',
                    style: TextStyle(
                      color: isAllDone ? const Color(0xFF3FB950) : const Color(0xFF8B949E),
                      fontSize: 11, fontFamily: 'monospace',
                    )),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF21262D),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('${allRows.length}',
                    style: const TextStyle(color: Color(0xFF8B949E), fontSize: 11)),
              ),
              const SizedBox(width: 8),
              if (isAllDone && !hasErrors)
                const Icon(Icons.check_circle, size: 14, color: Color(0xFF3FB950))
              else if (hasErrors)
                Icon(Icons.warning_amber_outlined, size: 14, color: const Color(0xFFF85149).withOpacity(0.8)),
              const SizedBox(width: 6),
              Icon(isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  size: 15, color: const Color(0xFF484F58)),
            ]),
          ),
        ),
        if (isExpanded) ...[
          const Divider(height: 1, color: Color(0xFF21262D)),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: visibleRows.length,
            itemBuilder: (_, j) => _FileRow(
              row: visibleRows[j],
              formatBytes: widget.formatBytes,
              pulseController: widget.pulseController,
            ),
          ),
        ],
      ]),
    );
  }
}

// ─── File Row ─────────────────────────────────────────────────────────────────

class _FileRow extends StatelessWidget {
  final CsvRow row;
  final String Function(int) formatBytes;
  final AnimationController pulseController;

  const _FileRow({required this.row, required this.formatBytes, required this.pulseController});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(children: [
        _icon,
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(row.documentName,
              style: const TextStyle(color: Color(0xFFE6EDF3), fontSize: 12, fontWeight: FontWeight.w500)),
          if (row.status == DownloadStatus.error && row.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(row.errorMessage!,
                  style: const TextStyle(color: Color(0xFFF85149), fontSize: 10)),
            ),
          if (row.status == DownloadStatus.downloading)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: AnimatedBuilder(
                animation: pulseController,
                builder: (_, __) => LinearProgressIndicator(
                  backgroundColor: const Color(0xFF21262D),
                  valueColor: AlwaysStoppedAnimation(
                    Color.lerp(const Color(0xFF0A84FF), const Color(0xFF58A6FF), pulseController.value)!,
                  ),
                  borderRadius: BorderRadius.circular(2),
                  minHeight: 2,
                ),
              ),
            ),
        ])),
        if (row.bytes != null)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(formatBytes(row.bytes!),
                style: const TextStyle(color: Color(0xFF484F58), fontSize: 10, fontFamily: 'monospace')),
          ),
      ]),
    );
  }

  Widget get _icon {
    switch (row.status) {
      case DownloadStatus.done:
        return const Icon(Icons.check_circle, size: 14, color: Color(0xFF3FB950));
      case DownloadStatus.error:
        return const Icon(Icons.cancel_outlined, size: 14, color: Color(0xFFF85149));
      case DownloadStatus.downloading:
        return const SizedBox(
          width: 14, height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A84FF)),
        );
      case DownloadStatus.pending:
        return const Icon(Icons.schedule, size: 14, color: Color(0xFF484F58));
      case DownloadStatus.idle:
        return const Icon(Icons.circle_outlined, size: 14, color: Color(0xFF30363D));
    }
  }
}