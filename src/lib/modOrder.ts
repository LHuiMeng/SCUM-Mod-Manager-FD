export function reorderVisibleIds(
  allIds: readonly string[],
  visibleIds: ReadonlySet<string>,
  sourceId: string,
  targetVisibleIndex: number,
): string[] | null {
  const visibleOrder = allIds.filter((id) => visibleIds.has(id));
  const sourceIndex = visibleOrder.indexOf(sourceId);
  if (
    sourceIndex < 0 ||
    targetVisibleIndex < 0 ||
    targetVisibleIndex >= visibleOrder.length ||
    sourceIndex === targetVisibleIndex
  ) {
    return null;
  }

  const nextVisible = [...visibleOrder];
  nextVisible.splice(sourceIndex, 1);
  nextVisible.splice(targetVisibleIndex, 0, sourceId);

  let visibleIndex = 0;
  return allIds.map((id) =>
    visibleIds.has(id) ? nextVisible[visibleIndex++] : id,
  );
}
