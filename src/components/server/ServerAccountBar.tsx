import type { SftpAccount, SftpConnectionResult } from "../../types";
import { useI18n } from "../../i18n";
import { Button } from "../ui/Button";

export interface ServerAccountBarProps {
  accounts: SftpAccount[];
  active: SftpAccount;
  connected: boolean;
  scan: SftpConnectionResult | null;
  onSwitchAccount: (id: string) => void;
  onNewAccount: () => void;
  onManage: () => void;
}

/**
 * 连接后左列顶部的账户条：真实切换（改 activeSftpAccountId + 重新连接）、
 * 新建入口、管理弹窗入口。账户编辑统一走 ServerAccountForm（弹窗或整页）。
 */
export function ServerAccountBar({
  accounts,
  active,
  connected,
  scan,
  onSwitchAccount,
  onNewAccount,
  onManage,
}: ServerAccountBarProps) {
  const { t } = useI18n();

  return (
    <div className="server-account-bar">
      <div className="server-account-bar-head">
        <span className={`sftp-connection-state ${connected ? "" : "is-offline"}`}>
          <i />
          {t(connected ? "server.accountBar.statusOn" : "server.accountBar.statusOff")}
        </span>
        <div className="server-account-bar-actions">
          <Button size="sm" icon="plus" onClick={onNewAccount}>
            {t("server.new")}
          </Button>
          <Button size="sm" icon="settings" onClick={onManage}>
            {t("server.manageAccount")}
          </Button>
        </div>
      </div>
      <div className="server-account-bar-controls">
        <select
          aria-label={t("server.selectAccount")}
          value={active.id}
          onChange={(event) => onSwitchAccount(event.target.value)}
        >
          {accounts.map((account) => (
            <option key={account.id} value={account.id}>
              {account.name}
            </option>
          ))}
        </select>
      </div>
      <code className="server-account-bar-host">
        {active.username}@{active.host}:{active.port}
      </code>
      <dl className="server-account-bar-roots">
        <div>
          <dt>PAK</dt>
          <dd>{scan?.detectedModsPath || active.modsPath || t("server.scanNotLocated")}</dd>
        </div>
        <div>
          <dt>UE4SS</dt>
          <dd>{scan?.detectedUe4ssPath || active.ue4ssPath || t("server.scanNotLocated")}</dd>
        </div>
      </dl>
    </div>
  );
}
