#!/usr/bin/env bash
#
# dev-base ゴールデンイメージを構築する。
#
# 生成物: incus のローカルイメージ "dev-base"
#   - dev ユーザー（パスワードなし sudo、SSH 公開鍵配置済み）
#   - sshd 有効
#   - herdr / Claude Code / Codex インストール済み（いずれも最新版）
#   - エージェント CLI の自動更新タイマー
#
# 実行するたびにイメージを作り直す（冪等ではない）。
# Ansible からはイメージが存在しないとき、または -e force_image_rebuild=true のときだけ呼ばれる。
#
# 環境変数で挙動を変えられる:
#   IMAGE_SOURCE        ベースイメージ           (既定: images:ubuntu/26.04)
#   IMAGE_ALIAS         生成するイメージ名        (既定: dev-base)
#   BUILD_CONTAINER     ビルド用コンテナ名        (既定: base)
#   CONTAINER_USER      作成するユーザー          (既定: dev)
#   AUTHORIZED_KEYS     配置する公開鍵            (既定: /home/ubuntu/.ssh/authorized_keys)
#   AGENTS_AUTO_UPDATE  自動更新タイマーの有効化   (既定: true)
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STATUSLINE_SRC="${STATUSLINE_SRC:-$SCRIPT_DIR/files/statusline-command.sh}"

IMAGE_SOURCE="${IMAGE_SOURCE:-images:ubuntu/26.04}"
IMAGE_ALIAS="${IMAGE_ALIAS:-dev-base}"
BUILD_CONTAINER="${BUILD_CONTAINER:-base}"
CONTAINER_USER="${CONTAINER_USER:-dev}"
AUTHORIZED_KEYS="${AUTHORIZED_KEYS:-/home/ubuntu/.ssh/authorized_keys}"
AGENTS_AUTO_UPDATE="${AGENTS_AUTO_UPDATE:-true}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

[ -r "$AUTHORIZED_KEYS" ] || { echo "authorized_keys が読めません: $AUTHORIZED_KEYS" >&2; exit 1; }

log "既存のビルド用コンテナを掃除"
incus delete "$BUILD_CONTAINER" --force >/dev/null 2>&1 || true

log "ベースイメージから起動: $IMAGE_SOURCE"
incus launch "$IMAGE_SOURCE" "$BUILD_CONTAINER" >/dev/null

log "ネットワーク待ち"
ip=""
for _ in $(seq 60); do
  ip=$(incus list "$BUILD_CONTAINER" -c 4 -f csv 2>/dev/null | awk '{print $1}' || true)
  [ -n "$ip" ] && break
  sleep 2
done
if [ -z "$ip" ]; then
  echo "コンテナが IP を取得できませんでした。" >&2
  echo "ufw が incusbr0 を許可しているか確認してください（incus ロールが設定します）。" >&2
  exit 1
fi
echo "IP: $ip"

# ---------------------------------------------------------------------------
# パッケージと dev ユーザー
# ---------------------------------------------------------------------------
log "パッケージと ${CONTAINER_USER} ユーザー"
incus exec "$BUILD_CONTAINER" -- bash -s <<PROVISION
set -e
export DEBIAN_FRONTEND=noninteractive

# incusbr0 は IPv4 のみ。IPv6 経路への接続試行で apt が長時間待つのを防ぐ。
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

apt-get update -qq
# sudo は images: の最小イメージに入っていないことがあるため明示的に入れる。
# jq は Claude Code のステータスラインが依存している。
apt-get install -y -qq sudo openssh-server curl ca-certificates git jq

id ${CONTAINER_USER} >/dev/null 2>&1 || adduser --disabled-password --gecos "" ${CONTAINER_USER}
usermod -aG sudo ${CONTAINER_USER}
printf '${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/${CONTAINER_USER}
chmod 440 /etc/sudoers.d/${CONTAINER_USER}
install -d -o ${CONTAINER_USER} -g ${CONTAINER_USER} -m 700 /home/${CONTAINER_USER}/.ssh

systemctl enable --now ssh
PROVISION

log "SSH 公開鍵を配置"
incus file push -q "$AUTHORIZED_KEYS" \
  "${BUILD_CONTAINER}/home/${CONTAINER_USER}/.ssh/authorized_keys"
incus exec "$BUILD_CONTAINER" -- chown "${CONTAINER_USER}:${CONTAINER_USER}" \
  "/home/${CONTAINER_USER}/.ssh/authorized_keys"
incus exec "$BUILD_CONTAINER" -- chmod 600 \
  "/home/${CONTAINER_USER}/.ssh/authorized_keys"

# ---------------------------------------------------------------------------
# ツール類（すべて最新版を取得する）
# ---------------------------------------------------------------------------
log "herdr をインストール"
incus exec "$BUILD_CONTAINER" -- su - "$CONTAINER_USER" -c \
  'curl -fsSL https://herdr.dev/install.sh | sh'

log "Claude Code をインストール"
# ネイティブ版はバックグラウンドで自動更新する
incus exec "$BUILD_CONTAINER" -- su - "$CONTAINER_USER" -c \
  'curl -fsSL https://claude.ai/install.sh | bash'

log "Codex をインストール"
# CODEX_NON_INTERACTIVE=true で対話プロンプトを抑止する
incus exec "$BUILD_CONTAINER" -- su - "$CONTAINER_USER" -c \
  'export CODEX_NON_INTERACTIVE=true; curl -fsSL https://chatgpt.com/codex/install.sh | sh'

# ---------------------------------------------------------------------------
# Claude Code のステータスライン
# ---------------------------------------------------------------------------
log "ステータスラインを適用"
if [ -f "$STATUSLINE_SRC" ]; then
  incus exec "$BUILD_CONTAINER" -- install -d \
    -o "$CONTAINER_USER" -g "$CONTAINER_USER" -m 755 "/home/${CONTAINER_USER}/.claude"
  incus file push -q "$STATUSLINE_SRC" \
    "${BUILD_CONTAINER}/home/${CONTAINER_USER}/.claude/statusline-command.sh"

  incus exec "$BUILD_CONTAINER" -- bash -s <<STATUSLINE
set -e
S=/home/${CONTAINER_USER}/.claude/settings.json
chmod 755 /home/${CONTAINER_USER}/.claude/statusline-command.sh

cat > "\$S.new" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "sh /home/${CONTAINER_USER}/.claude/statusline-command.sh",
    "refreshInterval": 10
  }
}
JSON

# 既存の設定があれば statusLine だけを重ねる（インストーラが将来
# settings.json を置くようになっても他のキーを壊さないため）
if [ -s "\$S" ]; then
  jq -s '.[0] * .[1]' "\$S" "\$S.new" > "\$S.tmp" && mv "\$S.tmp" "\$S"
  rm -f "\$S.new"
else
  mv "\$S.new" "\$S"
fi

chown -R ${CONTAINER_USER}:${CONTAINER_USER} /home/${CONTAINER_USER}/.claude
jq -e '.statusLine.command' "\$S" >/dev/null
STATUSLINE
else
  echo "警告: \$STATUSLINE_SRC が無いためステータスラインをスキップします" >&2
fi

# ---------------------------------------------------------------------------
# 仕上げ
# ---------------------------------------------------------------------------
log "仕上げ"
incus exec "$BUILD_CONTAINER" -- bash -s <<FINALIZE
set -e

# herdr は --remote が非対話シェルで起動されるため、システム全体の PATH に置く。
# ~/.local/bin のままだと herdr --remote が command not found になる。
install -m 755 /home/${CONTAINER_USER}/.local/bin/herdr /usr/local/bin/herdr

# claude / codex も同じ理由でシステム PATH から見えるようにする。
# Ubuntu の ~/.bashrc は非対話シェルで早期 return するため、
# ssh <host> 'claude ...' のようなワンショット実行では ~/.local/bin に PATH が通らない。
# 実体をコピーせずシンボリックリンクにするのは、両者が自己更新でランチャーの
# 指す先を差し替えるため。リンク経由なら更新に追随する。
ln -sf /home/${CONTAINER_USER}/.local/bin/claude /usr/local/bin/claude
ln -sf /home/${CONTAINER_USER}/.local/bin/codex  /usr/local/bin/codex

# 対話シェル用の PATH（claude / codex は ~/.local/bin のまま使う）
for f in /home/${CONTAINER_USER}/.bashrc /home/${CONTAINER_USER}/.profile; do
  [ -f "\$f" ] || continue
  grep -q 'aether-infra PATH' "\$f" || cat >> "\$f" <<'PATHBLOCK'

# aether-infra PATH
export PATH="\$HOME/.local/bin:\$PATH"
PATHBLOCK
done

# 作業用ディレクトリ。エージェントにはここで作業させる。
install -d -o ${CONTAINER_USER} -g ${CONTAINER_USER} -m 755 /home/${CONTAINER_USER}/workspace

# ログイン時の初期ディレクトリを workspace にする。
# 対話シェルに限定しているのは、scp / rsync / ssh <host> '<command>' の
# 動作を変えないため（これらは非対話なので cd されない）。
grep -q 'aether-infra workspace' /home/${CONTAINER_USER}/.profile || \
  cat >> /home/${CONTAINER_USER}/.profile <<'WSBLOCK'

# aether-infra workspace
case \$- in
  *i*) [ -d "\$HOME/workspace" ] && cd "\$HOME/workspace" ;;
esac
WSBLOCK

chown ${CONTAINER_USER}:${CONTAINER_USER} /home/${CONTAINER_USER}/.bashrc /home/${CONTAINER_USER}/.profile

# --- エージェント CLI の更新スクリプト ---
cat > /usr/local/bin/agent-update <<'AGENTUPDATE'
#!/usr/bin/env bash
# Claude Code と Codex を最新版に更新する。
# どちらのインストーラも再実行が更新として機能する。
set -uo pipefail

rc=0

echo "==> Claude Code"
if curl -fsSL https://claude.ai/install.sh | bash; then
  claude --version 2>/dev/null || true
else
  echo "Claude Code の更新に失敗しました" >&2; rc=1
fi

echo "==> Codex"
export CODEX_NON_INTERACTIVE=true
if curl -fsSL https://chatgpt.com/codex/install.sh | sh; then
  codex --version 2>/dev/null || true
else
  echo "Codex の更新に失敗しました" >&2; rc=1
fi

exit \$rc
AGENTUPDATE
chmod 755 /usr/local/bin/agent-update

# --- 自動更新タイマー ---
cat > /etc/systemd/system/agent-update.service <<'AGENTSVC'
[Unit]
Description=Update AI agent CLIs (Claude Code / Codex)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${CONTAINER_USER}
Environment=HOME=/home/${CONTAINER_USER}
Environment=PATH=/home/${CONTAINER_USER}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/bin/agent-update
AGENTSVC

cat > /etc/systemd/system/agent-update.timer <<'AGENTTIMER'
[Unit]
Description=Daily update of AI agent CLIs

[Timer]
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
AGENTTIMER

if [ "${AGENTS_AUTO_UPDATE}" = "true" ]; then
  systemctl enable agent-update.timer
fi

# --- SSH ホスト鍵を初回起動時に再生成する ---
# これが無いと全クローンが同一のホスト鍵を持つ
rm -f /etc/ssh/ssh_host_*
cat > /etc/systemd/system/regen-sshd-keys.service <<'REGEN'
[Unit]
Description=Regenerate SSH host keys on first boot
Before=ssh.service
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
REGEN
systemctl enable regen-sshd-keys.service

# --- クローンごとに一意にする ---
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

apt-get clean
rm -rf /var/lib/apt/lists/*
FINALIZE

log "バージョン確認"
incus exec "$BUILD_CONTAINER" -- su - "$CONTAINER_USER" -c \
  'echo "herdr : $(herdr --version 2>/dev/null || echo NG)"
   echo "claude: $(claude --version 2>/dev/null || echo NG)"
   echo "codex : $(codex --version 2>/dev/null || echo NG)"'

# ---------------------------------------------------------------------------
# publish
# ---------------------------------------------------------------------------
log "イメージとして publish: $IMAGE_ALIAS"
incus stop "$BUILD_CONTAINER"
incus image delete "$IMAGE_ALIAS" >/dev/null 2>&1 || true
incus publish "$BUILD_CONTAINER" --alias "$IMAGE_ALIAS"

log "完了"
incus image list "$IMAGE_ALIAS"
echo
echo "ビルド用コンテナ '$BUILD_CONTAINER' は停止状態で残してあります（テンプレート更新用）。"
echo "不要なら: incus delete $BUILD_CONTAINER"
