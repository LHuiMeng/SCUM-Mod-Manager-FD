import type { NavSection } from "../types";

export interface FileDropPayload {
  type: "enter" | "over" | "drop" | "leave";
  paths?: string[];
}

export interface FileDropOutcome {
  active: boolean;
  paths: string[];
  requiresLibrary: boolean;
}

export function resolveFileDrop(
  section: NavSection,
  payload: FileDropPayload,
): FileDropOutcome {
  if (payload.type === "enter" || payload.type === "over") {
    return { active: section === "library", paths: [], requiresLibrary: false };
  }
  if (payload.type === "leave") {
    return { active: false, paths: [], requiresLibrary: false };
  }
  if (section !== "library") {
    return { active: false, paths: [], requiresLibrary: true };
  }
  return { active: false, paths: payload.paths ?? [], requiresLibrary: false };
}
