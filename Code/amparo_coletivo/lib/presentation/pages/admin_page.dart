// admin_page.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  final supabase = Supabase.instance.client;

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController(); // short
  final _sobreController = TextEditingController(); // long
  String? _category;
  bool _highlighted = false;

  bool _loading = false;
  String? _editingId;

  // image bytes (works on web & mobile)
  Uint8List? _logoBytes;
  String? _logoUrl; // existing url from DB (when editing)

  final List<Uint8List?> _photoBytes = [null, null, null];
  final List<String?> _photoUrls = [null, null, null]; // existing urls from DB

  // categories list
  final List<String> _categories = [
    'Educação',
    'Saúde',
    'Meio Ambiente',
    'Animais',
    'Moradia',
    'Alimentação',
    'Outros',
  ];

  // list of ongs loaded
  List<Map<String, dynamic>> _ongs = [];

  @override
  void initState() {
    super.initState();
    _loadOngs();
  }

  Future<void> _loadOngs() async {
    try {
      final resp = await supabase
          .from('ongs')
          .select()
          .order('created_at', ascending: false);
      setState(() {
        _ongs = List<Map<String, dynamic>>.from(resp as List);
      });
    } catch (e) {
      debugPrint('Erro ao carregar ongs: $e');
    }
  }

  // ---- picking images (works on web & mobile) ----
  Future<Uint8List?> _pickSingleImage() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    if (result == null) return null;
    // prefer bytes (works on web). If no bytes (some mobile cases), read from path.
    final pf = result.files.single;
    if (pf.bytes != null) return pf.bytes;
    if (pf.path != null) {
      return await File(pf.path!).readAsBytes();
    }
    return null;
  }

  Future<void> _pickLogo() async {
    final bytes = await _pickSingleImage();
    if (bytes != null) setState(() => _logoBytes = bytes);
  }

  Future<void> _pickPhoto(int index) async {
    final bytes = await _pickSingleImage();
    if (bytes != null) setState(() => _photoBytes[index] = bytes);
  }

  // ---- helper to upload bytes to bucket ongsimages under folder ONG{id} ----
  Future<String?> _uploadBytesToBucket(Uint8List bytes, String path) async {
    try {
      final bucket = supabase.storage.from('ongsimages');
      // uploadBinary supports upsert
      await bucket.uploadBinary(path, bytes,
          fileOptions: const FileOptions(upsert: true));
      final url = bucket.getPublicUrl(path);
      return url;
    } catch (e) {
      debugPrint('Erro upload: $e');
      return null;
    }
  }

  // ---- Save (create or update) flow:
  // 1) If creating: insert minimal row to get id -> then upload images to ONG{id} -> then update record with URLs.
  // 2) If editing: use existing id -> upload any new images to same folder ONG{id} -> update record.
  Future<void> _saveOng() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);

    try {
      // Build data payload except image URLs (will fill after upload)
      final baseData = {
        'title': _titleController.text.trim(),
        'description': _descriptionController.text.trim(),
        'sobre_ong': _sobreController.text.trim(),
        'category': _category,
        'highlighted': _highlighted,
        'created_at': DateTime.now().toIso8601String(),
      };

      String id; // string or int acceptable for eq()

      if (_editingId == null) {
        // Insert minimal record to reserve id (so we can create folder ONG{id})
        final inserted =
            await supabase.from('ongs').insert(baseData).select('id').single();
        id = inserted['id'].toString();
      } else {
        id = _editingId!;
        // ensure baseData is applied (but we will update later with image urls too)
        await supabase.from('ongs').update(baseData).eq('id', id);
      }

      final folder = 'ONG$id';

      // Upload logo if chosen
      String? logoPublicUrl = _logoUrl; // existing url if not replaced
      if (_logoBytes != null) {
        final fileName = 'logo_${DateTime.now().millisecondsSinceEpoch}.png';
        final path = '$folder/$fileName';
        final uploaded = await _uploadBytesToBucket(_logoBytes!, path);
        if (uploaded != null) logoPublicUrl = uploaded;
      }

      // Upload gallery images if chosen (replace only those selected)
      final List<String?> galleryUrls =
          List<String?>.from(_photoUrls); // existing
      for (int i = 0; i < 3; i++) {
        if (_photoBytes[i] != null) {
          final fileName =
              'foto${i + 1}_${DateTime.now().millisecondsSinceEpoch}.png';
          final path = '$folder/$fileName';
          final uploaded = await _uploadBytesToBucket(_photoBytes[i]!, path);
          if (uploaded != null) galleryUrls[i] = uploaded;
        }
      }

      // Prepare final update data
      final updateData = {
        'image_url': logoPublicUrl,
        'foto_relevante1': galleryUrls[0],
        'foto_relevante2': galleryUrls[1],
        'foto_relevante3': galleryUrls[2],
      };

      // Update DB with image urls
      await supabase.from('ongs').update(updateData).eq('id', id);

      // reload list and reset form
      await _loadOngs();
      _clearForm();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ONG salva com sucesso!')),
      );
    } catch (e) {
      debugPrint('Erro salvar ONG: $e');
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Erro ao salvar: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  void _clearForm() {
    _formKey.currentState?.reset();
    _titleController.clear();
    _descriptionController.clear();
    _sobreController.clear();
    _category = null;
    _highlighted = false;
    _editingId = null;
    _logoBytes = null;
    _logoUrl = null;
    for (int i = 0; i < 3; i++) {
      _photoBytes[i] = null;
      _photoUrls[i] = null;
    }
    setState(() {});
  }

  // ---- edit existing ONG: load fields and existing image URLs (do not download bytes) ----
  void _startEdit(Map<String, dynamic> ong) {
    _editingId = ong['id'].toString();
    _titleController.text = ong['title'] ?? '';
    _descriptionController.text = ong['description'] ?? '';
    _sobreController.text = ong['sobre_ong'] ?? '';
    _category = ong['category'];
    _highlighted = ong['highlighted'] ?? false;

    // existing urls
    _logoUrl = ong['image_url'];
    _photoUrls[0] = ong['foto_relevante1'];
    _photoUrls[1] = ong['foto_relevante2'];
    _photoUrls[2] = ong['foto_relevante3'];

    // clear any selected bytes (user may replace)
    _logoBytes = null;
    for (int i = 0; i < 3; i++) _photoBytes[i] = null;

    setState(() {});
  }

  Future<void> _deleteOng(dynamic id) async {
    try {
      await supabase.from('ongs').delete().eq('id', id);
      await _loadOngs();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('ONG removida')));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Erro ao remover: $e')));
    }
  }

  // UI preview helper: show either selected bytes (memory) or existing url (network)
  Widget _imagePreview(
      {Uint8List? bytes, String? url, double width = 120, double height = 90}) {
    if (bytes != null) {
      return Image.memory(bytes,
          width: width, height: height, fit: BoxFit.cover);
    }
    if (url != null && url.isNotEmpty && url.startsWith('http')) {
      return Image.network(url, width: width, height: height, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) {
        return Container(
            width: width,
            height: height,
            color: Colors.grey[200],
            child: const Icon(Icons.broken_image));
      });
    }
    return Container(
        width: width,
        height: height,
        color: Colors.grey[200],
        child: const Icon(Icons.add_a_photo));
  }

  @override
  Widget build(BuildContext context) {
    // Material 3 style is typically enabled at MaterialApp level via useMaterial3: true
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Administração de ONGs')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Card(
            elevation: 2,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Form(
                key: _formKey,
                child: Column(children: [
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _titleController,
                        decoration:
                            const InputDecoration(labelText: 'Nome da ONG'),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Obrigatório'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(children: [
                      const Text('Favoritar'),
                      Switch(
                          value: _highlighted,
                          onChanged: (v) => setState(() => _highlighted = v)),
                    ])
                  ]),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _descriptionController,
                    decoration:
                        const InputDecoration(labelText: 'Descrição curta'),
                    maxLines: 2,
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Obrigatório' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _sobreController,
                    decoration: const InputDecoration(
                        labelText: 'Descrição longa (Sobre a ONG)'),
                    maxLines: 4,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _category,
                    decoration: const InputDecoration(labelText: 'Categoria'),
                    items: _categories
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                    onChanged: (v) => setState(() => _category = v),
                    validator: (v) => v == null ? 'Selecione categoria' : null,
                  ),
                  const SizedBox(height: 12),

                  // Logo picker & preview
                  Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Logo da ONG',
                          style: theme.textTheme.titleMedium)),
                  const SizedBox(height: 8),
                  Row(children: [
                    GestureDetector(
                      onTap: _pickLogo,
                      child: _imagePreview(
                          bytes: _logoBytes,
                          url: _logoUrl,
                          width: 150,
                          height: 110),
                    ),
                    const SizedBox(width: 12),
                    Column(children: [
                      FilledButton.icon(
                          onPressed: _pickLogo,
                          icon: const Icon(Icons.upload),
                          label: const Text('Selecionar')),
                      const SizedBox(height: 8),
                      if (_logoBytes != null ||
                          (_logoUrl != null && _logoUrl!.isNotEmpty))
                        OutlinedButton.icon(
                          onPressed: () {
                            setState(() {
                              _logoBytes = null;
                              _logoUrl = null;
                            });
                          },
                          icon: const Icon(Icons.delete_forever,
                              color: Colors.red),
                          label: const Text('Remover'),
                        )
                    ])
                  ]),

                  const SizedBox(height: 14),
                  Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Fotos relevantes',
                          style: theme.textTheme.titleMedium)),
                  const SizedBox(height: 8),
                  Wrap(
                      spacing: 10,
                      children: List.generate(3, (i) {
                        return Column(children: [
                          GestureDetector(
                              onTap: () => _pickPhoto(i),
                              child: _imagePreview(
                                  bytes: _photoBytes[i],
                                  url: _photoUrls[i],
                                  width: 120,
                                  height: 90)),
                          const SizedBox(height: 6),
                          if (_photoBytes[i] != null ||
                              (_photoUrls[i] != null &&
                                  _photoUrls[i]!.isNotEmpty))
                            OutlinedButton.icon(
                              onPressed: () {
                                setState(() {
                                  _photoBytes[i] = null;
                                  _photoUrls[i] = null;
                                });
                              },
                              icon: const Icon(Icons.delete, color: Colors.red),
                              label: const Text('Remover'),
                            )
                        ]);
                      })),

                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _loading ? null : _saveOng,
                        icon: const Icon(Icons.cloud_upload),
                        label: Text(_loading
                            ? 'Enviando...'
                            : (_editingId == null
                                ? 'Cadastrar ONG'
                                : 'Salvar alterações')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _clearForm,
                      child: const Text('Limpar'),
                    ),
                  ]),
                ]),
              ),
            ),
          ),

          const SizedBox(height: 18),
          Text('ONGs cadastradas', style: theme.textTheme.titleLarge),
          const SizedBox(height: 10),

          // list existing ongs
          for (final ong in _ongs)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: ListTile(
                leading: ong['image_url'] != null
                    ? Image.network(ong['image_url'],
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.image_not_supported))
                    : Container(
                        width: 56,
                        height: 56,
                        color: Colors.grey[200],
                        child: const Icon(Icons.image)),
                title: Text(ong['title'] ?? ''),
                subtitle: Text(
                    '${ong['category'] ?? ''} • ${ong['description'] ?? ''}'),
                trailing: Wrap(spacing: 6, children: [
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.blue),
                    onPressed: () => _startEditAndLoadImages(ong),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Confirmar'),
                          content: const Text('Remover essa ONG?'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.of(ctx).pop(false),
                                child: const Text('Cancelar')),
                            TextButton(
                                onPressed: () => Navigator.of(ctx).pop(true),
                                child: const Text('Remover')),
                          ],
                        ),
                      );
                      if (ok == true) await _deleteOngAndRefresh(ong['id']);
                    },
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }

  // helper: when edit button pressed, load Ong fields and image URLs into form
  void _startEditAndLoadImages(Map<String, dynamic> ong) {
    setState(() {
      _editingId = ong['id'].toString();
      _titleController.text = ong['title'] ?? '';
      _descriptionController.text = ong['description'] ?? '';
      _sobreController.text = ong['sobre_ong'] ?? '';
      _category = ong['category'];
      _highlighted = ong['highlighted'] ?? false;

      _logoBytes = null;
      _logoUrl = ong['image_url'];
      for (int i = 0; i < 3; i++) {
        _photoBytes[i] = null;
        _photoUrls[i] = ong['foto_relevante${i + 1}'];
      }
    });
  }

  Future<void> _deleteOngAndRefresh(dynamic id) async {
    try {
      await supabase.from('ongs').delete().eq('id', id);
      await _loadOngs();
      if (_editingId == id.toString()) _clearForm();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('ONG removida')));
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Erro ao remover: $e')));
    }
  }
}
