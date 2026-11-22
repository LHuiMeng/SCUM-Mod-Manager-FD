import {
  Fragment,
  useMemo,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
} from "react";
import type { ConflictGroup, ModEntry } from "../../types";
import { useI18n } from "../../i18n";
import { modTypeKey } from "../../lib/format";
import { Button } from "../ui/Button";
import { Icon } from "../ui/Icon";
import { Modal } from "../ui/Modal";

interface ConflictResolutionPanelProps {
  mod: ModEntry;
  groups: ConflictGroup[];
  onClose: () => void;
  onSave: (winners: Record<string, string>) => Promise<boolean>;
}

type ConflictOwner = ConflictGroup["owners"][number];

function orderedOwners(group: ConflictGroup): ConflictOwner[] {
  return [...group.owners].sort(
    (left, right) =>
      left.loadOrder - right.loadOrder ||
      left.name.localeCompare(right.name) ||
      left.id.localeCompare(right.id),
  );
}

function ownerExists(group: ConflictGroup, ownerId: string | null | undefined) {
  return Boolean(ownerId && group.owners.some((owner) => owner.id === ownerId));
}

function initialWinnerFor(group: ConflictGroup): string {
  const candidates = [group.selectedWinnerId, group.winnerId, group.defaultWinnerId];
  return (
    candidates.find((ownerId) => ownerExists(group, ownerId)) ??
    orderedOwners(group)[0]?.id ??
    group.defaultWinnerId
  );
}

function persistedWinnerFor(group: ConflictGroup): string {
  const candidates = [group.selectedWinnerId, group.winnerId, group.defaultWinnerId];
  return (
    candidates.find((ownerId) => ownerExists(group, ownerId)) ??
    orderedOwners(group)[0]?.id ??
    group.defaultWinnerId
  );
}

function groupAnchor(group: ConflictGroup): number {
  return Math.min(...group.owners.map((owner) => owner.loadOrder));
}

export function ConflictResolutionPanel({
  mod,
  groups,
  onClose,
  onSave,
}: ConflictResolutionPanelProps) {
  const { t } = useI18n();
  const participatingGroups = useMemo(
    () =>
      groups
        .filter((group) => group.owners.some((owner) => owner.id === mod.id))
        .sort((left, right) => groupAnchor(left) - groupAnchor(right)),
    [groups, mod.id],
  );
  const [draft, setDraft] = useState<Record<string, string>>(() =>
    Object.fromEntries(
      participatingGroups.map((group) => [group.key, initialWinnerFor(group)]),
    ),
  );
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const changedGroups = participatingGroups.filter(
    (group) => draft[group.key] !== group.defaultWinnerId,
  );

  function chooseWinner(groupKey: string, ownerId: string) {
    setDraft((current) => ({ ...current, [groupKey]: ownerId }));
    setSaveError(null);
  }

  function resetGroup(group: ConflictGroup) {
    chooseWinner(group.key, group.defaultWinnerId);
  }

  function resetAll() {
    setDraft(
      Object.fromEntries(
        participatingGroups.map((group) => [group.key, group.defaultWinnerId]),
      ),
    );
    setSaveError(null);
  }

  function handleChoiceKeyDown(
    event: ReactKeyboardEvent<HTMLButtonElement>,
    group: ConflictGroup,
    owners: ConflictOwner[],
    ownerIndex: number,
    groupIndex: number,
  ) {
    let nextIndex: number | null = null;
    if (event.key === "ArrowDown" || event.key === "ArrowRight") {
      nextIndex = (ownerIndex + 1) % owners.length;
    } else if (event.key === "ArrowUp" || event.key === "ArrowLeft") {
      nextIndex = (ownerIndex - 1 + owners.length) % owners.length;
    } else if (event.key === "Home") {
      nextIndex = 0;
    } else if (event.key === "End") {
      nextIndex = owners.length - 1;
    }
    if (nextIndex === null) return;

    event.preventDefault();
    chooseWinner(group.key, owners[nextIndex].id);
    window.requestAnimationFrame(() => {
      document.getElementById(`conflict-${groupIndex}-${nextIndex}`)?.focus();
    });
  }

  async function handleSave() {
    if (saving) return;
    // The backend replaces the whole winner map, so preserve custom choices
    // made for groups outside the currently selected mod.
    const winners: Record<string, string> = Object.fromEntries(
      groups.flatMap((group) =>
        group.selectedWinnerId && group.selectedWinnerId !== group.defaultWinnerId
          ? [[group.key, group.selectedWinnerId]]
          : [],
      ),
    );
    for (const group of participatingGroups) {
      const selected = draft[group.key];
      if (
        selected &&
        selected !== group.defaultWinnerId &&
        group.owners.some((owner) => owner.id === selected)
      ) {
        winners[group.key] = selected;
      } else {
        delete winners[group.key];
      }
    }

    setSaving(true);
    setSaveError(null);
    try {
      const saved = await onSave(winners);
      if (saved) {
        onClose();
        return;
      }
      setSaveError(t("conflict.saveFailed"));
    } catch {
      setSaveError(t("conflict.saveFailed"));
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal
      wide
      title={t("conflict.title")}
      description={t("conflict.description", {
        name: mod.name,
        count: participatingGroups.length,
      })}
      onClose={() => {
        if (!saving) onClose();
      }}
      footer={
        <>
          <Button
            disabled={saving}
            onClick={() => {
              if (!saving) onClose();
            }}
          >
            {t("common.cancel")}
          </Button>
          <Button
            variant="primary"
            disabled={saving || participatingGroups.length === 0}
            onClick={() => void handleSave()}
          >
            {saving ? t("conflict.saving") : t("conflict.save")}
          </Button>
        </>
      }
    >
      <div className="conflict-panel">
        {participatingGroups.length === 0 ? (
          <div className="conflict-empty" role="status">
            <Icon name="serverOff" size={22} />
            <b>{t("conflict.emptyTitle")}</b>
            <span>{t("conflict.emptyDescription")}</span>
          </div>
        ) : (
          <>
            <div className="conflict-panel-note">
              <span className="conflict-panel-note-icon" aria-hidden="true">
                <Icon name="serverOff" size={16} />
              </span>
              <div>
                <b>{t("conflict.panelTitle")}</b>
                <span>{t("conflict.panelDescription")}</span>
              </div>
              <button
                type="button"
                className="conflict-reset-all"
                onClick={resetAll}
                disabled={changedGroups.length === 0}
              >
                <Icon name="refresh" size={13} />
                {t("conflict.resetAll")}
              </button>
            </div>

            <div className="conflict-group-list">
              {participatingGroups.map((group, groupIndex) => {
                const owners = orderedOwners(group);
                const selectedId = draft[group.key] ?? initialWinnerFor(group);
                const currentWinnerId = persistedWinnerFor(group);
                const defaultOwner = group.owners.find(
                  (owner) => owner.id === group.defaultWinnerId,
                );
                const currentOwner = group.owners.find(
                  (owner) => owner.id === currentWinnerId,
                );
                const groupNumber = String(groupIndex + 1).padStart(2, "0");
                const pathsId = `conflict-paths-${groupIndex}`;

                return (
                  <article
                    className="conflict-group"
                    key={group.key}
                    aria-labelledby={`conflict-group-title-${groupIndex}`}
                  >
                    <header className="conflict-group-head">
                      <div>
                        <span className="conflict-group-kicker">
                          {t("conflict.groupTitle", { index: groupNumber })}
                        </span>
                        <h3 id={`conflict-group-title-${groupIndex}`}>
                          {t("conflict.pathCount", { count: group.paths.length })}
                        </h3>
                      </div>
                      <button
                        type="button"
                        className="conflict-reset-group"
                        onClick={() => resetGroup(group)}
                        disabled={selectedId === group.defaultWinnerId}
                      >
                        <Icon name="refresh" size={12} />
                        {t("conflict.resetGroup")}
                      </button>
                    </header>

                    <div
                      className="conflict-chain"
                      role="list"
                      aria-label={t("conflict.chainLabel", { count: owners.length })}
                    >
                      {owners.map((owner, ownerIndex) => (
                        <Fragment key={owner.id}>
                          {ownerIndex > 0 ? (
                            <span className="conflict-chain-arrow" aria-hidden="true">
                              →
                            </span>
                          ) : null}
                          <span
                            role="listitem"
                            className={[
                              "conflict-chain-owner",
                              owner.id === group.defaultWinnerId ? "is-default" : "",
                              owner.id === currentWinnerId ? "is-current" : "",
                              owner.id === mod.id ? "is-this-mod" : "",
                            ]
                              .filter(Boolean)
                              .join(" ")}
                          >
                            <small>{String(owner.loadOrder + 1).padStart(2, "0")}</small>
                            <b>{owner.name}</b>
                          </span>
                        </Fragment>
                      ))}
                    </div>

                    <dl className="conflict-winner-summary">
                      <div>
                        <dt>{t("conflict.defaultWinner")}</dt>
                        <dd>{defaultOwner?.name ?? t("conflict.unknownOwner")}</dd>
                      </div>
                      <div>
                        <dt>{t("conflict.currentWinner")}</dt>
                        <dd>{currentOwner?.name ?? t("conflict.unknownOwner")}</dd>
                      </div>
                    </dl>

                    <div className="conflict-path-block">
                      <span className="conflict-subhead">{t("conflict.files")}</span>
                      <ul className="conflict-paths" id={pathsId}>
                        {group.paths.map((path) => (
                          <li key={path}>
                            <code>{path}</code>
                          </li>
                        ))}
                      </ul>
                    </div>

                    <fieldset className="conflict-choice-fieldset">
                      <legend id={`conflict-choice-legend-${groupIndex}`}>
                        {t("conflict.keepOwner")}
                      </legend>
                      <div
                        className="conflict-choice-list"
                        role="radiogroup"
                        aria-labelledby={`conflict-choice-legend-${groupIndex}`}
                      >
                        {owners.map((owner, ownerIndex) => {
                          const radioId = `conflict-${groupIndex}-${ownerIndex}`;
                          const isDefault = owner.id === group.defaultWinnerId;
                          const isCurrent = owner.id === currentWinnerId;
                          return (
                            <button
                              type="button"
                              className={`conflict-choice ${
                                selectedId === owner.id ? "is-selected" : ""
                              }`}
                              id={radioId}
                              role="radio"
                              aria-checked={selectedId === owner.id}
                              aria-describedby={pathsId}
                              tabIndex={selectedId === owner.id ? 0 : -1}
                              key={owner.id}
                              onClick={() => chooseWinner(group.key, owner.id)}
                              onKeyDown={(event) =>
                                handleChoiceKeyDown(
                                  event,
                                  group,
                                  owners,
                                  ownerIndex,
                                  groupIndex,
                                )
                              }
                            >
                              <span
                                className="conflict-choice-radio"
                                aria-hidden="true"
                              />
                              <span className="conflict-choice-copy">
                                <b>{owner.name}</b>
                                <span>
                                  {t("conflict.choiceMeta", {
                                    order: String(owner.loadOrder + 1).padStart(2, "0"),
                                    type: t(modTypeKey(owner.type)),
                                  })}
                                </span>
                              </span>
                              <span className="conflict-choice-badges">
                                {owner.id === mod.id ? (
                                  <i>{t("conflict.thisMod")}</i>
                                ) : null}
                                {isDefault ? <i>{t("conflict.defaultBadge")}</i> : null}
                                {isCurrent ? <i>{t("conflict.currentBadge")}</i> : null}
                              </span>
                            </button>
                          );
                        })}
                      </div>
                    </fieldset>
                  </article>
                );
              })}
            </div>
          </>
        )}
        {saveError ? (
          <p className="conflict-save-error" role="alert">
            {saveError}
          </p>
        ) : null}
      </div>
    </Modal>
  );
}
