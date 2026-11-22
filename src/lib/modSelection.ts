export type ModSelectionMode = "replace" | "toggle" | "range";

export interface ModSelectionState {
  selected: string[];
  anchor: string | null;
  primary: string | null;
}

export function updateModSelection(
  current: ModSelectionState,
  clickedId: string,
  visibleIds: string[],
  mode: ModSelectionMode,
): ModSelectionState {
  if (!visibleIds.includes(clickedId)) return current;

  if (mode === "range") {
    const anchor = current.anchor && visibleIds.includes(current.anchor)
      ? current.anchor
      : current.primary && visibleIds.includes(current.primary)
        ? current.primary
        : clickedId;
    const anchorIndex = visibleIds.indexOf(anchor);
    const clickedIndex = visibleIds.indexOf(clickedId);
    const start = Math.min(anchorIndex, clickedIndex);
    const end = Math.max(anchorIndex, clickedIndex);
    return {
      selected: visibleIds.slice(start, end + 1),
      anchor,
      primary: clickedId,
    };
  }

  if (mode === "toggle") {
    const selected = current.selected.includes(clickedId)
      ? current.selected.filter((id) => id !== clickedId)
      : [...current.selected, clickedId];
    const primary = selected.includes(clickedId)
      ? clickedId
      : current.primary && selected.includes(current.primary)
        ? current.primary
        : [...selected].reverse().find((id) => visibleIds.includes(id)) ?? null;
    return { selected, anchor: clickedId, primary };
  }

  return { selected: [clickedId], anchor: clickedId, primary: clickedId };
}

export function pruneModSelection(
  selected: string[],
  visibleIds: string[],
): string[] {
  const visible = new Set(visibleIds);
  return selected.filter((id) => visible.has(id));
}
