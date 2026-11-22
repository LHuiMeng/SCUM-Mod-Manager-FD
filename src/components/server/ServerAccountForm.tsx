import { useEffect, useState, type FormEvent } from "react";
import type { SftpAccount } from "../../types";
import { useI18n } from "../../i18n";
import {
  looksLikeConnectionString,
  parseConnectionString,
  parseHostPort,
} from "../../lib/sftpUrl";
import { Button } from "../ui/Button";

export interface SftpTrustPrompt {
  accountId: string;
  fingerprint: string;
  message: string;
}

export interface ServerAccountFormProps {
  accounts: SftpAccount[];
  editing: SftpAccount | null;
  connected: boolean;
  trustPrompt: SftpTrustPrompt | null;
  onDismissTrust: () => void;
  onTrustHost: () => void;
  onSaveAccount: (
    account: Omit<SftpAccount, "id" | "hasPassword">,
    password: string,
  ) => void;
}

/**
 * 账户编辑表单：URL 粘贴解析 + 字段 + trust prompt。
 * 不管理账户列表（那是 ServerAccountBar 的职责），也不做折叠态。
 * 未连接时整页内联使用；连接后由 ServerScreen 套 Modal 作为「管理账户」。
 */
export function ServerAccountForm({
  accounts,
  editing,
  connected,
  trustPrompt,
  onDismissTrust,
  onTrustHost,
  onSaveAccount,
}: ServerAccountFormProps) {
  const { t } = useI18n();

  const [name, setName] = useState(editing?.name ?? "");
  const [host, setHost] = useState(editing?.host ?? "");
  const [port, setPort] = useState(editing?.port ?? 22);
  const [username, setUsername] = useState(editing?.username ?? "");
  const [secretInput, setSecretInput] = useState("");
  const [modsPath, setModsPath] = useState(editing?.modsPath ?? "");
  const [ue4ssPath, setUe4ssPath] = useState(editing?.ue4ssPath ?? "");
  const [addressNote, setAddressNote] = useState<{
    text: string;
    error: boolean;
  } | null>(null);

  // 编辑目标切换时重新灌字段，密码永远清空。
  useEffect(() => {
    setName(editing?.name ?? "");
    setHost(editing?.host ?? "");
    setPort(editing?.port ?? 22);
    setUsername(editing?.username ?? "");
    setModsPath(editing?.modsPath ?? "");
    setUe4ssPath(editing?.ue4ssPath ?? "");
    setSecretInput("");
    setAddressNote(null);
  }, [editing?.id]);

  /**
   * 地址框里直接粘贴连接链接或 `主机:端口` 就自动拆分到各字段，不再额外占一个按钮控件。
   * 纯主机名原样保留，不改写。
   */
  function applyAddressInput(raw: string): boolean {
    const trimmed = raw.trim();
    if (!trimmed) return false;

    if (looksLikeConnectionString(trimmed)) {
      try {
        const parsed = parseConnectionString(trimmed);
        setHost(parsed.host);
        setPort(parsed.port);
        setUsername(parsed.username);
        if (parsed.password) setSecretInput(parsed.password);
        if (parsed.path) setModsPath(parsed.path);
        if (!name.trim()) setName(parsed.username);
        setAddressNote({
          text: t(
            parsed.protocol === "sftp"
              ? "server.parsedAddress"
              : "server.parsedAddressOther",
            { protocol: parsed.protocol },
          ),
          error: false,
        });
        return true;
      } catch (parseError) {
        setAddressNote({
          text:
            parseError instanceof Error
              ? parseError.message
              : String(parseError),
          error: true,
        });
        return false;
      }
    }

    const hostPort = parseHostPort(trimmed);
    if (hostPort) {
      setHost(hostPort.host);
      setPort(hostPort.port);
      setAddressNote({ text: t("server.parsedHostPort"), error: false });
      return true;
    }

    return false;
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    const finalName = name.trim() || host.trim() || t("server.defaultAccount");
    if (finalName !== name) setName(finalName);
    onSaveAccount(
      { name: finalName, host, port, username, modsPath, ue4ssPath },
      secretInput,
    );
  }

  return (
    <form className="server-form" onSubmit={submit}>
      <div className="section-title server-form-title">
        <span>{t("server.accounts")}</span>
        <div>
          {connected ? (
            <span className="sftp-connection-state">
              <i />
              {t("server.connectionReady")}
            </span>
          ) : (
            <b>
              {accounts.length > 0
                ? t("server.savedCount", { count: accounts.length })
                : t("server.notSaved")}
            </b>
          )}
        </div>
      </div>

      <div className="form-grid">
        <label>
          <span>{t("server.accountName")}</span>
          <input value={name} onChange={(event) => setName(event.target.value)} />
        </label>
        <label>
          <span>{t("server.host")}</span>
          <input
            value={host}
            onChange={(event) => {
              setHost(event.target.value);
              setAddressNote(null);
            }}
            onPaste={(event) => {
              const pasted = event.clipboardData.getData("text");
              if (!pasted.trim()) return;
              event.preventDefault();
              setHost(pasted.trim());
              applyAddressInput(pasted);
            }}
            onBlur={() => applyAddressInput(host)}
            onKeyDown={(event) => {
              if (event.nativeEvent.isComposing || event.keyCode === 229) return;
              if (event.key !== "Enter") return;
              event.preventDefault();
              applyAddressInput(host);
            }}
            placeholder={t("server.hostPlaceholder")}
            required
          />
          {addressNote ? (
            <small
              className={addressNote.error ? "field-note is-error" : "field-note"}
              role={addressNote.error ? "alert" : "status"}
            >
              {addressNote.text}
            </small>
          ) : null}
        </label>
        <label>
          <span>{t("server.port")}</span>
          <input
            type="number"
            value={port}
            min={1}
            max={65535}
            onChange={(event) => setPort(Number(event.target.value))}
          />
        </label>
        <label>
          <span>{t("server.username")}</span>
          <input
            value={username}
            onChange={(event) => setUsername(event.target.value)}
            autoComplete="username"
            required
          />
        </label>
        <label className="form-span-2">
          <span>
            {t("server.password")}
            {editing?.hasPassword ? t("server.passwordKeep") : ""}
          </span>
          <input
            type="password"
            value={secretInput}
            onChange={(event) => setSecretInput(event.target.value)}
            autoComplete="current-password"
            placeholder={t(
              editing?.hasPassword
                ? "server.passwordSaved"
                : "server.passwordPlaceholder",
            )}
          />
        </label>
        <label className="form-span-2">
          <span>{t("server.modsPath")}</span>
          <input
            value={modsPath}
            onChange={(event) => setModsPath(event.target.value)}
            placeholder="/srv/scum/SCUM/Content/Paks/~mods"
          />
        </label>
        <label className="form-span-2">
          <span>{t("server.ue4ssPath")}</span>
          <input
            value={ue4ssPath}
            onChange={(event) => setUe4ssPath(event.target.value)}
            placeholder="/srv/scum/SCUM/Binaries/Win64/ue4ss/Mods"
          />
        </label>
      </div>
      <div className="form-actions">
        <Button type="submit" variant="primary" icon="lock">
          {t("server.saveAccount")}
        </Button>
      </div>

      {trustPrompt &&
      (editing ? trustPrompt.accountId === editing.id : accounts.length === 0) ? (
        <div className="sftp-trust-prompt" role="alert">
          <div>
            <b>{t("server.trustTitle")}</b>
            <p>{trustPrompt.message}</p>
            <code>{trustPrompt.fingerprint}</code>
          </div>
          <div className="sftp-trust-actions">
            <Button size="sm" onClick={onDismissTrust}>
              {t("common.cancel")}
            </Button>
            <Button size="sm" icon="lock" onClick={onTrustHost}>
              {t("server.trust")}
            </Button>
          </div>
        </div>
      ) : null}
    </form>
  );
}
