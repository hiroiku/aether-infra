# aether-infra

Incus をハイパーバイザーとして使い、**プロジェクト単位でコンテナを切って AI エージェントを走らせる**ためのサーバー構成。ConoHa VPS (Ubuntu) を対象に、まっさらな状態から同じ環境を再現できる。

## 何ができるか

```bash
# ホストで
newproj blog                    # プロジェクト作成 → コンテナ起動まで 1 コマンド

# 手元で（SSH config の編集は不要）
herdr --remote blog.incus       # エージェントを多重化して実行
ssh blog.incus                  # 素のシェル
```

各コンテナには **herdr / Claude Code / Codex** が最新版で入った状態で起動する。

## 構成

| 層 | 実体 | 変化頻度 |
|---|---|---|
| ホストのブートストラップ | `ansible/` | ほぼ不変 |
| ゴールデンイメージ | `image/build-dev-base.sh` | 時々 |
| プロジェクト | `newproj`（実行時コマンド） | 毎日 |
| クライアント設定 | `client/ssh_config.incus` | ほぼ不変 |

プロジェクトは使い捨てなので、あえて IaC の管理対象にしていない。state を持たせるより 1 コマンドで作り直せる方が実態に合う。

```
aether (ホスト) ── Incus 以外は動かさない
├── project: blog   → container: blog   (10.10.0.x, blog.incus)
├── project: api    → container: api
└── project: ...
```

コンテナ名とプロジェクト名を一致させることで `<名前>.incus` で名前解決でき、固定 IP の採番も SSH config の追記も不要にしている。

## 前提

- 対象ホスト: Ubuntu 24.04 以降（Incus 6.x が apt にあること）
- 対象ホストに SSH 公開鍵でログインでき、パスワードなし sudo が使えること
- 手元に Ansible

```bash
brew install ansible
```

## 使い方

```bash
make check     # 差分だけ確認（変更しない）
make apply     # 構築・収束
make image     # ゴールデンイメージを作り直す（CLI を最新化したいとき）
make ping      # 疎通確認
```

新しいサーバーを足すときは `ansible/inventory.ini` に 1 行追加して `make apply` するだけ。

初回は `dev-base` イメージのビルドに **10〜20 分**かかる。btrfs のループバックプール越しに apt を回すため I/O が支配的で、これは正常。

構築後、`client/ssh_config.incus` の内容を手元の `~/.ssh/config`（または Include 先）に反映する。

## エージェント CLI の更新

| CLI | インストール | 更新 |
|---|---|---|
| Claude Code | ネイティブインストーラ | **バックグラウンドで自動更新** |
| Codex | 公式インストーラ | `agent-update.timer`（毎日） |
| herdr | 公式インストーラ | イメージ再作成時 |

コンテナ内で手動更新する場合:

```bash
agent-update
```

タイマーを止めたい場合は `group_vars/all.yml` の `agents_auto_update: false` にしてイメージを作り直す。

**認証情報はイメージに焼いていない。** コンテナごとに `claude` / `codex` を一度起動してログインする。エージェントに渡す資格情報はスコープを絞ったものにすること。

## このリポジトリの本体は「ハマりどころ」

パッケージのインストール手順そのものより、**動かして初めて分かった落とし穴**がコードとコメントとして残っていることに価値がある。新しいサーバーではこれらを踏まずに済む。

| 問題 | 対処 | 場所 |
|---|---|---|
| コンテナ内 systemd がクラッシュループする | `security.nesting=true` | `roles/incus` |
| DHCP も NAT も通らない | `ufw allow in on incusbr0` + `route allow` | `roles/incus` |
| `.incus` 名が解決できない | `incus-dns.service` | `roles/incus` |
| `/proc/cpuinfo` の CPU 数が絞れない | `lxcfs --enable-cfs` | `roles/incus` |
| CPU 制限が効かない / コアに固定される | `limits.cpu.allowance` を時間スライス形式で | `roles/tooling/newproj` |
| apt が異常に遅い | `Acquire::ForceIPv4` | `image/build-dev-base.sh` |
| 全クローンが同じ SSH ホスト鍵になる | 初回起動時に再生成 | `image/build-dev-base.sh` |
| `herdr --remote` が command not found | `/usr/local/bin` に置く | `image/build-dev-base.sh` |

詳細は各ファイルのコメントを参照。

## 設計判断

- **コンテナ中心、VM は例外** — メモリ 4GB では VM を常駐させると 2〜3 台が限界。コンテナなら 8〜10。ネステッド仮想化は有効なので、信頼できないコードを流すプロジェクトだけ `--vm` で立てられる
- **CPU はピン留めせずクォータ** — 空きコアを使えるようにするため。`lxcfs --enable-cfs` と組み合わせて、ゲストには N CPU に見せつつ実体は CFS クォータ
- **Terraform を使わない** — Incus プロバイダは Incus 自体をインストールできず、二重管理になる。またプロジェクトは使い捨てなので state 管理が重荷になる
- **NixOS ではない** — ホストごと入れ替えるなら最有力だが、ConoHa は Ubuntu イメージのみ。現状の延長では採らない

## 日常運用

`docs/runbook.md` を参照。
