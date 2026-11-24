import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/queuecare_api.dart';
import '../../theme/app_theme.dart';
import '../../widgets/ui_kit.dart';
import '../../widgets/queue_widgets.dart';

class PatientMedicalRecordsPage extends StatefulWidget {
  const PatientMedicalRecordsPage({super.key});

  @override
  State<PatientMedicalRecordsPage> createState() =>
      _PatientMedicalRecordsPageState();
}

class _PatientMedicalRecordsPageState extends State<PatientMedicalRecordsPage> {
  List<Map<String, dynamic>> _records = [];
  List<Map<String, dynamic>> _visits = [];
  bool _loading = true;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait([
        QueueCareApi.getList('/api/v1/patient/medical-records'),
        QueueCareApi.getList('/api/v1/patient/appointments'),
      ]);
      if (!mounted) return;
      setState(() {
        _records = values[0];
        _visits = values[1]
            .where((visit) => visit['status'] == 'completed')
            .toList();
        _loading = false;
      });
    } on QueueCareApiException catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _notice(error.message);
    }
  }

  Future<void> _chooseAndUpload() async {
    final picker = ImagePicker();
    final picked = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    try {
      final photo = await picker.pickImage(
        source: picked,
        imageQuality: 90,
        maxWidth: 2400,
        maxHeight: 2400,
      );
      if (photo == null || !mounted) return;
      await _showUploadDetails(photo);
    } catch (_) {
      _notice(
        'Could not open the camera or gallery. Check the app permissions.',
      );
    }
  }

  Future<void> _showUploadDetails(XFile photo) async {
    final title = TextEditingController();
    String type = 'prescription';
    String? appointmentId;
    final shouldUpload = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('Add medical image'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  maxLength: 160,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    hintText: 'e.g. Medicine slip, blood test',
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'Image type'),
                  items: const [
                    DropdownMenuItem(
                      value: 'prescription',
                      child: Text('Prescription'),
                    ),
                    DropdownMenuItem(
                      value: 'report',
                      child: Text('Medical report'),
                    ),
                    DropdownMenuItem(value: 'other', child: Text('Other')),
                  ],
                  onChanged: (value) =>
                      refresh(() => type = value ?? 'prescription'),
                ),
                if (_visits.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    initialValue: appointmentId,
                    decoration: const InputDecoration(
                      labelText: 'Completed visit (optional)',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Not linked to a visit'),
                      ),
                      ..._visits.map(
                        (visit) => DropdownMenuItem<String?>(
                          value: '${visit['id']}',
                          child: Text(
                            'Token A-${visit['queue_number']} · ${visit['appointment_date']}',
                          ),
                        ),
                      ),
                    ],
                    onChanged: (value) => refresh(() => appointmentId = value),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  photo.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF71839B),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Upload'),
            ),
          ],
        ),
      ),
    );
    if (shouldUpload != true || !mounted) return;
    setState(() => _uploading = true);
    try {
      await QueueCareApi.uploadMedicalRecord(
        image: await photo.readAsBytes(),
        fileName: photo.name,
        recordType: type,
        title: title.text.trim(),
        appointmentId: appointmentId,
      );
      if (!mounted) return;
      _notice('Medical image saved securely.');
      await _load();
    } on QueueCareApiException catch (error) {
      _notice(error.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
      title.dispose();
    }
  }

  Future<void> _preview(Map<String, dynamic> record) async {
    try {
      final image = await QueueCareApi.getImage(
        '/api/v1/patient/medical-records/${record['id']}/image',
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${record['title']}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppTheme.navy,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: InteractiveViewer(
                  child: Image.memory(image, fit: BoxFit.contain),
                ),
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
      );
    } on QueueCareApiException catch (error) {
      _notice(error.message);
    }
  }

  Future<void> _delete(Map<String, dynamic> record) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete medical image?'),
        content: const Text(
          'This removes the image from your medical records.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await QueueCareApi.delete(
        '/api/v1/patient/medical-records/${record['id']}',
      );
      await _load();
    } on QueueCareApiException catch (error) {
      _notice(error.message);
    }
  }

  void _notice(String text) => AppFeedback.toast(
    context,
    text,
    type: RegExp(r'saved|deleted|removed', caseSensitive: false).hasMatch(text)
        ? FeedbackType.success
        : FeedbackType.error,
  );

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(18, 14, 18, 100),
    children: [
      const Text(
        'Medical records',
        style: TextStyle(
          color: AppTheme.navy,
          fontWeight: FontWeight.w800,
          fontSize: 25,
        ),
      ),
      const SizedBox(height: 6),
      const Text(
        'Keep prescriptions and report images together in your private record.',
        style: TextStyle(color: Color(0xFF71839B), fontSize: 12),
      ),
      const SizedBox(height: 18),
      PrimaryButton(
        label: _uploading ? 'Uploading…' : 'Upload prescription or report',
        icon: Icons.add_a_photo_outlined,
        onPressed: _uploading ? null : _chooseAndUpload,
      ),
      const SizedBox(height: 18),
      StateSwitcher(
        status: _loading ? LoadStatus.loading : LoadStatus.ready,
        isEmpty: _records.isEmpty,
        emptyIcon: Icons.folder_open_outlined,
        emptyTitle: 'No medical records yet',
        emptyMessage:
            'Upload a clear photo of a prescription or medical report.',
        loading: const SkeletonList(count: 3, header: false),
        child: Column(children: staggered(_records.map(_recordCard).toList())),
      ),
    ],
  );

  Widget _recordCard(Map<String, dynamic> record) => Card(
    margin: const EdgeInsets.only(bottom: 9),
    child: ListTile(
      onTap: () => _preview(record),
      leading: const CircleAvatar(
        backgroundColor: AppTheme.paleBlue,
        child: Icon(Icons.description_outlined, color: AppTheme.blue),
      ),
      title: Text(
        '${record['title']}',
        style: const TextStyle(
          color: AppTheme.navy,
          fontWeight: FontWeight.w800,
          fontSize: 13,
        ),
      ),
      subtitle: Text(
        '${_label('${record['record_type']}')} · ${_date('${record['created_at']}')} · ${_size(record['file_size_bytes'])}',
        style: const TextStyle(color: Color(0xFF71839B), fontSize: 10),
      ),
      trailing: IconButton(
        tooltip: 'Delete image',
        onPressed: () async {
          final ok = await AppFeedback.confirm(
            context,
            title: 'Delete this image?',
            message: 'It will be permanently removed from your record.',
            yesLabel: 'Yes, delete',
            noLabel: 'No',
            danger: true,
          );
          if (ok) _delete(record);
        },
        icon: const Icon(Icons.delete_outline, color: AppTheme.red),
      ),
    ),
  );

  String _label(String value) => switch (value) {
    'prescription' => 'Prescription',
    'report' => 'Medical report',
    _ => 'Other',
  };
  String _date(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    return date == null ? '' : '${date.day}/${date.month}/${date.year}';
  }

  String _size(dynamic value) {
    final bytes = int.tryParse('$value') ?? 0;
    return bytes < 1024 * 1024
        ? '${(bytes / 1024).ceil()} KB'
        : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
