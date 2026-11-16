import { MessagePart, attachmentName } from '../model/FileMarkers';
import { MarkdownBody } from './MarkdownBody';
import { FileDownload } from './FileDownload';

/** Observe the retained part itself instead of capturing a transient ForEach item. */
@Component
export struct MessagePartItem {
  @ObjectLink part: MessagePart;
  onContentChange: () => void = () => {};

  build() {
    if (this.part.kind === 'file') {
      FileDownload({ endpoint: '/api/files/download?path=' + encodeURIComponent(this.part.text),
        filename: attachmentName(this.part.text) })
    } else {
      MarkdownBody({ content: this.part.text, onContentChange: this.onContentChange })
    }
  }
}
