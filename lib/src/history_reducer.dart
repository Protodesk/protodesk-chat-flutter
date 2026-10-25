import 'dart:convert';

import 'models.dart';

/// Pure copy-on-write reduction: callers persist the result before publishing.
/// Resource timestamps, not the event envelope's time, version full projections.
Map<String, dynamic> reduceHistory(
  Map<String, dynamic> history,
  ChatServerEvent event,
) {
  try {
    if (event.data['schemaVersion'] != 1) {
      throw const ProtodeskChatException('chat.protocol_unsupported');
    }
    final next = jsonDecode(jsonEncode(history)) as Map<String, dynamic>;
    final data = event.data;
    switch (event.type) {
      case 'conversation.created':
      case 'conversation.updated':
      case 'conversation.resolved':
        final row = Map<String, dynamic>.from(data['conversation'] as Map);
        ChatConversation.fromJson(row);
        _validateRow(row);
        _upsert(next['conversations'] as Map<String, dynamic>, row);
      case 'message.created':
        final row = Map<String, dynamic>.from(data['message'] as Map);
        ChatMessage.fromJson(row);
        _validateRow(row);
        if (row['sender'] != 'endUser') {
          for (final conversation in next['conversations']['data'] as List) {
            if (conversation['id'] == row['conversationId']) {
              conversation['unreadCountIsStale'] = true;
            }
          }
        }
        if (row['conversationId'] == next['conversationId'] &&
            next['messages'] != null) {
          _upsert(next['messages'] as Map<String, dynamic>, row);
        }
      case 'message.delivered':
      case 'message.failed':
        final conversationId = data['conversationId'] as String;
        final messageId = data['messageId'] as String;
        final occurred = data['occurredAt'] as String;
        final time = DateTime.parse(occurred);
        final status = event.type == 'message.delivered'
            ? 'delivered'
            : 'failed';
        if (messageId.isEmpty ||
            conversationId.isEmpty ||
            data['status'] != status) {
          throw const FormatException();
        }
        if (conversationId == next['conversationId'] &&
            next['messages'] != null) {
          for (final row in (next['messages']['data'] as List)) {
            if (row['id'] == messageId && time.isAfter(_version(row))) {
              row['status'] = status;
              row['updatedAt'] = occurred;
            }
          }
        }
      default:
        // Read projections require a targeted refresh: readAt does not version
        // their computed unreadCount relative to a REST snapshot.
        throw const ProtodeskChatException('chat.protocol_unsupported');
    }
    return next;
  } on ProtodeskChatException {
    rethrow;
  } catch (_) {
    throw const ProtodeskChatException('chat.invalid_event');
  }
}

void _validateRow(Map<String, dynamic> row) {
  if ((row['id'] as String).isEmpty) throw const FormatException();
  DateTime.parse(row['createdAt'] as String);
  DateTime.parse(row['updatedAt'] as String);
}

DateTime _version(Map row) => DateTime.parse(row['updatedAt'] as String);
int _order(Map a, Map b) {
  final time = DateTime.parse(b['createdAt'] as String)
      .compareTo(DateTime.parse(a['createdAt'] as String));
  return time != 0 ? time : (b['id'] as String).compareTo(a['id'] as String);
}

void _upsert(Map<String, dynamic> page, Map<String, dynamic> incoming) {
  final rows = page['data'] as List;
  final index = rows.indexWhere((row) => row['id'] == incoming['id']);
  if (index >= 0) {
    // Equal versions retain the authoritative snapshot, including read counts.
    if (_version(incoming).isAfter(_version(rows[index])))
      rows[index] = incoming;
  } else {
    // Do not insert an isolated old row below an incomplete page's boundary.
    if (page['hasMore'] == true &&
        rows.isNotEmpty &&
        _order(incoming, rows.last) > 0)
      return;
    rows.add(incoming);
  }
  rows.sort((a, b) => _order(a as Map, b as Map));
  // Keep the original pagination boundary. Evicting its oldest rows would leave
  // a gap before nextCursor; the existing byte cap bounds checkpoint growth.
}
