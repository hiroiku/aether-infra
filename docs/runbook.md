# Runbook

日常運用の早見表。構築手順は [README](../README.md) を参照。

## プロジェクト

| やること | コマンド（ホスト） |
|---|---|
| 作成 | `newproj <名前> [mem] [cpu] [disk]` |
| 削除 | `rmproj <名前>` |
| 一覧 | `incus list --all-projects -c ns4mM` |

```bash
newproj blog                    # 既定 (1GiB / 2コア相当)
newproj api 768MiB 1            # 軽量
newproj build 2GiB 4 30GiB      # ディスク上限つき
```

## 入る

### ホストから

```bash
pj blog                         # dev のログインシェル
pj blog 'cd ~/work && git status'  # ワンショット
incus shell blog --project blog # root で入る
```

`incus exec` 系は sshd やネットワークが壊れていても入れる。復旧時の最終手段。

### クライアントから

```bash
herdr --remote blog.incus       # エージェント作業の本命
ssh blog.incus                  # 素のシェル
ssh blog.incus 'df -h'          # ワンショット
scp ./config.yml blog.incus:~/
rsync -avz ./src/ blog.incus:~/work/
```

herdr は 1 クライアント : 1 サーバーのため、複数プロジェクトを同時に見るならターミナルのタブを分ける。

```
タブ1 ── herdr --remote blog.incus
タブ2 ── herdr --remote api.incus
```

> 複数リモートの同時接続は upstream で最優先の計画中（未実装）。
> 実装されればこの構成のまま横断ビューが手に入る。

## エージェントを走らせる前に

スナップショットが安全網の中心。壊されたら数秒で戻せる。

```bash
incus snapshot create blog pre-agent --project blog
incus snapshot restore blog pre-agent --project blog
incus snapshot list blog --project blog
```

## 初回ログイン（コンテナごとに必要）

認証情報はイメージに焼いていないため、コンテナごとに一度ログインする。

```bash
ssh blog.incus
claude          # ブラウザで認証
codex           # 同上
```

## リソース

```bash
incus list --all-projects -c ns4mM   # プロジェクト横断でメモリ / ディスク
free -h                              # ホスト全体
incus storage info default           # プール使用量
```

**同時アクティブは 3〜4 プロジェクトが上限。** 空き 3.2GB に対し、開発サーバーとエージェントが動くコンテナは 300〜800MB を消費する。常駐させるものは `newproj api 768MiB 1` のように絞る。

メモリもディスクも thin（上限であって予約ではない）ため、使っていないプロジェクトを停止せずに置いておくコストはほぼゼロ。

```bash
incus stop blog --project blog       # 明示的に止めたいとき
incus start blog --project blog
```

## リソース上限を後から変える

```bash
incus config set blog limits.memory=2GiB --project blog
incus config set blog limits.cpu.allowance=400ms/100ms --project blog   # 4コア相当
incus config device override blog root size=30GiB --project blog
incus restart blog --project blog
```

CPU は**必ず時間スライス形式**で指定する。`400%` のようなパーセント形式は相対的な重みであってハードキャップにならない。

## テンプレートを更新する

エージェント CLI を最新にした新しいイメージを作る。既存プロジェクトには遡及せず、以降に作るものへ反映される。

```bash
# 手元から
make image
```

既存コンテナの CLI を今すぐ更新したい場合は、そのコンテナ内で実行する。

```bash
pj blog 'agent-update'
```

## VM が必要になったら

信頼できない第三者のコードを流す場合など、カーネルごと分離したいとき。ネステッド仮想化は有効になっている。

```bash
incus launch dev-base sandbox --vm --project blog
```

メモリを最低 512MB〜1GB 占有するため、常用するならホストのプラン変更が前提。

## トラブル時

| 症状 | 確認 |
|---|---|
| コンテナが IP を取れない | `sudo ufw status`（incusbr0 の許可）、`incus network info incusbr0` の送信パケット数 |
| コンテナ内 systemd が起動しない | `incus config get <名前> security.nesting --project <名前>` |
| `.incus` が解決できない | `systemctl status incus-dns`、`resolvectl status incusbr0` |
| SSH ホスト鍵の警告 | `rm ~/.ssh/known_hosts.incus`（コンテナ作り直し時は正常） |
| コンテナに入れない | `pj <名前>` で incus 経由。ネットワークを介さない |

ホスト自体から締め出された場合は、ConoHa コントロールパネルのコンソール（VNC）から root パスワードでログインする。**サーバー作成時の root パスワードは控えておくこと。**
