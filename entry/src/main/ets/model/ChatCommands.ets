/** 命令候选由后端提供；本模块只负责输入框的提示匹配。 */
export interface ChatCommand {
  value: string;
  description: string;
}

export interface CommandCatalog {
  commands: ChatCommand[];
}

export function matchChatCommands(text: string, catalog: ChatCommand[]): ChatCommand[] {
  const query = text.trimStart().toLowerCase();
  if (!query.startsWith('/') || query.includes('\n')) {
    return [];
  }
  return catalog.filter((item: ChatCommand) => item.value.startsWith(query));
}
