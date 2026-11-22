export interface RemoteBreadcrumb {
  name: string;
  path: string;
}

export function normalizeRemotePath(path: string): string {
  const trimmed = path.trim().replace(/\\/g, "/");
  if (!trimmed) return "/";
  const withLeadingSlash = trimmed.startsWith("/") ? trimmed : `/${trimmed}`;
  const segments: string[] = [];
  for (const segment of withLeadingSlash.split("/")) {
    if (!segment || segment === ".") continue;
    if (segment === "..") {
      segments.pop();
    } else {
      segments.push(segment);
    }
  }
  return segments.length > 0 ? `/${segments.join("/")}` : "/";
}

export function remoteParent(path: string): string {
  const normalized = normalizeRemotePath(path);
  if (normalized === "/") return "/";
  const lastSlash = normalized.lastIndexOf("/");
  return lastSlash <= 0 ? "/" : normalized.slice(0, lastSlash);
}

export function remoteBreadcrumbs(path: string): RemoteBreadcrumb[] {
  const normalized = normalizeRemotePath(path);
  const crumbs: RemoteBreadcrumb[] = [{ name: "/", path: "/" }];
  let current = "";
  for (const segment of normalized.split("/").filter(Boolean)) {
    current += `/${segment}`;
    crumbs.push({ name: segment, path: current });
  }
  return crumbs;
}

export function isRemotePathWithin(root: string, path: string): boolean {
  const normalizedRoot = normalizeRemotePath(root);
  const normalizedPath = normalizeRemotePath(path);
  if (normalizedRoot === "/") return normalizedPath.startsWith("/");
  return normalizedPath === normalizedRoot || normalizedPath.startsWith(`${normalizedRoot}/`);
}
