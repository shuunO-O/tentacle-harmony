import { Bubble, ChatRow, ChatStore, HistoryMessage, MsgGroup, MsgImage } from './Types';
import { visibleUserText } from './FileMarkers';

/** Parse completely before replacing the visible timeline. */
export function historyRows(messages: HistoryMessage[]): ChatRow[] {
  if (!Array.isArray(messages)) { throw new Error('invalid history'); }
  const store = new ChatStore();
  for (const message of messages) {
    if (typeof message.content !== 'string') { throw new Error('invalid history content'); }
    if (message.role === 'user') {
      if (message.platform === 'system') { store.addSystem(message.content); }
      else {
        const images: MsgImage[] = [];
        for (const file of message.images ?? []) {
          if (file !== null && typeof file.local_id === 'string' && file.local_id) {
            images.push({ local_id: file.local_id, filename: file.filename ?? '',
              mime: file.mime || 'application/octet-stream', path: file.path });
          }
        }
        store.addUser(visibleUserText(message.content, images.map((file: MsgImage) => file.path ?? '')),
          message.created_time, images, message.platform);
      }
    } else if (message.role === 'assistant') {
      if (!Array.isArray(message.segments)) { throw new Error('invalid history segments'); }
      const group = new MsgGroup();
      group.time = message.created_time; group.roundId = message.round_id ?? '';
      group.interrupted = message.interrupted === true;
      for (const segment of message.segments) {
        if (typeof segment !== 'string') { throw new Error('invalid segment'); }
        const bubble = new Bubble(); bubble.text = segment; bubble.platform = message.platform;
        group.bubbles.push(bubble);
      }
      const row = new ChatRow(); row.kind = 'group'; row.group = group; store.rows = store.rows.concat([row]);
    }
    if (store.rows.length) {
      const row = store.rows[store.rows.length - 1]; row.archiveId = message.id; row.roundId = message.round_id ?? '';
    }
  }
  return store.rows;
}
