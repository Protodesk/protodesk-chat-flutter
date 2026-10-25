import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:protodesk_chat/protodesk_chat.dart';

/// Native host adapter: one bounded in-memory file, no retained paths or copies.
Future<ChatAttachmentSource?> pickChatAttachment() async {
  try {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: 'Chat attachments',
          extensions: _mime.keys.toList(),
          uniformTypeIdentifiers: [
            'public.image',
            'public.audio',
            'public.movie',
            'com.adobe.pdf',
            'public.plain-text',
            'public.comma-separated-values-text',
          ],
        ),
      ],
    );
    if (file == null) return null;
    const maxBytes = 16 * 1024 * 1024;
    final size = await file.length();
    final mime = _mime[file.name.split('.').last.toLowerCase()];
    if (size <= 0 || size > maxBytes || mime == null) {
      throw const ProtodeskChatException('sdk.attachment_source_unavailable');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const ProtodeskChatException('sdk.attachment_source_unavailable');
      }
      bytes.add(chunk);
    }
    return ChatAttachmentSource(
      filename: file.name,
      contentType: mime,
      bytes: bytes.takeBytes(),
    );
  } on ProtodeskChatException {
    rethrow;
  } catch (_) {
    throw const ProtodeskChatException('sdk.attachment_source_unavailable');
  }
}

const _mime = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'mp3': 'audio/mpeg',
  'ogg': 'audio/ogg',
  'oga': 'audio/ogg',
  'wav': 'audio/wav',
  'm4a': 'audio/mp4',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'mov': 'video/quicktime',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'csv': 'text/csv',
};
