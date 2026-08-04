# Runbook

日常運用の早見表。構築手順は [README](../README.md) を参照。

## project コマンド

ホスト上でプロジェクトを操作する。プロジェクトと同名のコンテナが 1:1 で対応する。

```
project                                    ライブダッシュボード（q で終了）
project create <name> [mem] [cpu] [disk]   作成して起動
project remove <name> [-y]                 完全に削除
project list                               一覧とリソース（1 回だけ出力）
project shell  <name> [command...]         コンテナに入る
project info   <name>                      詳細
```

### ライブダッシュボード

引数なしで実行すると全画面のダッシュボードが開く。

```bash
ssh -t aether project
```

```
  aether · Incus                                      2026-08-05 02:40:57   ⟳ 2s

  HOST
    load    0.15  0.11  0.11    cpu ░░░░░░░░░░░░    2%   (4 cores)    up 3h 30m
    memory  ███░░░░░░░░░░░░░░░░░   19%  757.9M / 3.8G   swap 84.0K
    disk    ██░░░░░░░░░░░░░░░░░░   11%  11.1G / 98.2G

  PROJECTS  2 running / 3 total

    PROJECT  NAME  STATE      ADDRESS          CPU  MEMORY                    PROC  NET ↓/↑   SNAP
    api      api   ● running  10.10.0.248   0.4% /100%  102.2M/512.0M █░░░  20%   13  0B/0B      0
    tui      tui   ● running  10.10.0.202   1.9% /100%  102.4M/768.0M █░░░  13%   13  0B/0B      0
    default  base  ○ stopped  -                      -  -                      -  -            0

  q quit   r refresh   +/- interval
```

| キー | 動作 |
|---|---|
| `q` / `Ctrl-C` | 終了 |
| `r` | 即座に再描画 |
| `+` / `-` | 更新間隔を変更（0.5〜30 秒） |

CPU 使用率とネットワーク速度は累積カウンタの差分から算出するため、**初回フレームでは `-` になり 2 フレーム目から表示される**。CPU 列は「1 コアに対する使用率 / 割り当てクォータ」の形式。

代替スクリーンを使うので、終了すると元の画面に戻る。

```bash
project create blog                    # 既定 (1GiB / 2コア相当)
project create api 768MiB 1            # 軽量
project create build 2GiB 4 30GiB      # ディスク上限つき

project remove blog                    # プロジェクト名の入力を求められる
project remove blog -y                 # 確認を省く（スクリプト用）
```

`project remove` は確認としてプロジェクト名の入力を求める。取り消せない操作のため。

出力は端末では色付きで表示され、**パイプ・リダイレクト時と `NO_COLOR` 指定時は自動的にプレーンテキストになる**ので、`project list | grep` のような使い方も壊れない。

## 入る

### ホストから

```bash
project shell blog                          # dev のログインシェル
project shell blog 'cd ~/workspace && git status'  # ワンショット
incus shell blog --project blog             # root で入る
```

`project shell` は `incus exec` 経由なので、sshd やネットワークが壊れていても入れる。復旧時の最終手段。

### クライアントから

```bash
herdr --remote blog.incus       # エージェント作業の本命
ssh blog.incus                  # 素のシェル
ssh blog.incus 'claude --version'
scp ./config.yml blog.incus:~/
rsync -avz ./src/ blog.incus:~/workspace/
```

herdr は 1 クライアント : 1 サーバーのため、複数プロジェクトを同時に見るならターミナルのタブを分ける。

```
タブ1 ── herdr --remote blog.incus
タブ2 ── herdr --remote api.incus
```

> 複数リモートの同時接続は upstream で最優先の計画中（未実装）。
> 実装されればこの構成のまま横断ビューが手に入る。

## 作業ディレクトリ

コンテナには `~/workspace` が用意してあり、**対話ログイン時の初期ディレクトリ**になっている。

```bash
$ ssh blog.incus
dev@blog:~/workspace$
```

`cd` を対話シェルに限定しているため、`scp` / `rsync` / `ssh <host> '<command>'` は影響を受けない（これらは非対話なので `~` のまま）。

```bash
scp ./config.yml blog.incus:workspace/     # 明示的に指定する
```

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

## ステータスライン

Claude Code のステータスラインは `~/.claude/statusline-command.sh` として同梱済みで、`~/.claude/settings.json` から有効になっている。追加の設定は不要。

実体は `image/files/statusline-command.sh`。macOS と Linux の両方で動くよう、`stat` / `date` の BSD・GNU 差分を吸収するラッパを持たせてある。これが無いと Linux 上では mtime と日時整形が空になり、レート制限のバーとヒストグラムが描画されない。

`jq` に依存するため、イメージには `jq` を同梱している。

更新したいときは `image/files/statusline-command.sh` を編集して `make image`。**既存のコンテナには遡及しない**ので、その場で反映するなら次を実行する。

```bash
incus file push image/files/statusline-command.sh \
  blog/home/dev/.claude/statusline-command.sh --project blog
```

## リソース

```bash
project list                         # プロジェクト横断 + ホストのメモリ
incus storage info default           # プール使用量
```

**同時アクティブは 3〜4 プロジェクトが上限。** 空き 3.2GB に対し、開発サーバーとエージェントが動くコンテナは 300〜800MB を消費する。常駐させるものは `project create api 768MiB 1` のように絞る。

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
project shell blog 'agent-update'
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
| `ssh <host> 'cmd'` で command not found | `/usr/local/bin` にリンクがあるか。対話シェルでは通るが非対話では通らない |
| コンテナに入れない | `project shell <名前>` で incus 経由。ネットワークを介さない |

ホスト自体から締め出された場合は、ConoHa コントロールパネルのコンソール（VNC）から root パスワードでログインする。**サーバー作成時の root パスワードは控えておくこと。**
