#!/bin/sh
# Claude Code statusLine - 4-line, foreground-only, dynamic colors, progress bars
# Line 1: Git branch, Worktree, Current directory, Account email
# Line 2: Context usage, Model
# Line 3: 5h rate limit — unified race bar (fill=usage, ┃=now, ✗=predicted limit)
# Line 4: 7d rate limit — unified race bar

input=$(cat)
reset='\033[0m'
bold='\033[1m'

fg() { printf '\033[38;5;%sm' "$1"; }

now=$(date +%s)

# ── OS 差分の吸収 ────────────────────────────────────────────────────────────
# 同じスクリプトを macOS（BSD coreutils）と Linux（GNU coreutils）の両方で
# 動かすための薄いラッパ。GNU 形式を先に試し、失敗したら BSD 形式に落ちる。
# コンテナ側は Linux なので、これが無いと mtime と日時整形が全て空になり、
# レート制限のバーとヒストグラムが描画されない。
file_mtime() {   # <path> -> epoch
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}
epoch_fmt() {    # <epoch> <strftime>
  date -d "@$1" +"$2" 2>/dev/null || date -r "$1" +"$2" 2>/dev/null
}
iso_to_epoch() { # <YYYY-MM-DDTHH:MM:SS> -> epoch (UTC)
  date -u -d "$1" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%S" "$1" +%s 2>/dev/null
}

# ── Parse JSON ──────────────────────────────────────────────────────────────
# One jq pass for every field. This script runs every 10s and its cost is almost
# entirely process starts, so each extra `| jq` was ~6ms of pure overhead.
# Defaults are set first: if jq fails the eval yields nothing and the line still
# renders, the same as when each field was read separately.
cwd=""; model=""; effort=""; used=""; ctx_max=0
total_in=0; total_out=0; cache_read=0; cache_create=0
worktree=""; wt_branch=""
cur_in=0; cur_cache_read=0; cur_cache_create=0
rate_5h=""; rate_7d=""; rate_5h_reset=""; rate_7d_reset=""
eval "$(printf '%s' "$input" | jq -r '
  @sh "cwd=\(.workspace.current_dir // .cwd // "")",
  @sh "model=\(.model.display_name // "")",
  @sh "effort=\(.effort.level // "")",
  @sh "used=\(.context_window.used_percentage // "")",
  @sh "ctx_max=\(.context_window.context_window_size // .context_window.max_tokens // 0)",
  @sh "total_in=\(.context_window.total_input_tokens // 0)",
  @sh "total_out=\(.context_window.total_output_tokens // 0)",
  @sh "cache_read=\(.context_window.cache_read_input_tokens // 0)",
  @sh "cache_create=\(.context_window.cache_creation_input_tokens // 0)",
  @sh "worktree=\(.worktree.name // "")",
  @sh "wt_branch=\(.worktree.branch // "")",
  @sh "cur_in=\(.context_window.current_usage.input_tokens // 0)",
  @sh "cur_cache_read=\(.context_window.current_usage.cache_read_input_tokens // 0)",
  @sh "cur_cache_create=\(.context_window.current_usage.cache_creation_input_tokens // 0)",
  @sh "rate_5h=\(.rate_limits.five_hour.used_percentage // "")",
  @sh "rate_7d=\(.rate_limits.seven_day.used_percentage // "")",
  @sh "rate_5h_reset=\(.rate_limits.five_hour.resets_at // "")",
  @sh "rate_7d_reset=\(.rate_limits.seven_day.resets_at // "")"
' 2>/dev/null)"

# ── Rate-limit fallback via OAuth usage endpoint ────────────────────────────
# stdin .rate_limits is populated natively when Claude Code talks to Anthropic
# over subscription OAuth. When routed through a proxy (CLIProxyAPI), the proxy
# does not forward the anthropic-ratelimit-unified-* headers, so the field is
# empty. In that case only, query the Claude account's usage endpoint directly
# using the proxy's stored OAuth access token, cached 60s to avoid hammering it.
# 認証ファイル名にアカウント名が入るため、パスは決め打ちせずに探す
# （CLAUDE_PROXY_AUTH で明示指定も可能）。プロキシを使っていなければ
# 該当ファイルが無いだけで、このブロックは丸ごとスキップされる。
claude_auth="${CLAUDE_PROXY_AUTH:-}"
if [ -z "$claude_auth" ]; then
  for _f in "$HOME"/.cli-proxy-api/claude*.json; do
    [ -f "$_f" ] && { claude_auth=$_f; break; }
  done
fi
usage_cache="${TMPDIR:-/tmp}/claude-oauth-usage.json"
if [ -z "$rate_5h" ] && [ -n "$claude_auth" ] && [ -f "$claude_auth" ]; then
  now_ep=$(date +%s)
  cache_ok=0
  if [ -f "$usage_cache" ]; then
    cache_mtime=$(file_mtime "$usage_cache")
    [ $(( now_ep - cache_mtime )) -lt 60 ] && cache_ok=1
  fi
  if [ "$cache_ok" -eq 0 ]; then
    tok=$(jq -r '.access_token // empty' "$claude_auth" 2>/dev/null)
    if [ -n "$tok" ]; then
      resp=$(curl -s --max-time 3 https://api.anthropic.com/api/oauth/usage \
        -H "Authorization: Bearer $tok" \
        -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
      if echo "$resp" | jq -e '.five_hour.utilization' >/dev/null 2>&1; then
        echo "$resp" > "$usage_cache"
      elif [ -f "$usage_cache" ]; then
        touch "$usage_cache"   # keep last-good, back off 60s on failure
      fi
    fi
  fi
  if [ -f "$usage_cache" ]; then
    usage_asof=$(file_mtime "$usage_cache")
    rate_5h=$(jq -r '.five_hour.utilization // ""' "$usage_cache" 2>/dev/null)
    rate_7d=$(jq -r '.seven_day.utilization // ""' "$usage_cache" 2>/dev/null)
    r5_iso=$(jq -r '.five_hour.resets_at // ""' "$usage_cache" 2>/dev/null)
    r7_iso=$(jq -r '.seven_day.resets_at // ""' "$usage_cache" 2>/dev/null)
    [ -n "$r5_iso" ] && rate_5h_reset=$(iso_to_epoch "$(echo "$r5_iso" | cut -c1-19)")
    [ -n "$r7_iso" ] && rate_7d_reset=$(iso_to_epoch "$(echo "$r7_iso" | cut -c1-19)")
  fi
fi


# ── Roll a stale window forward ─────────────────────────────────────────────
# rate_limits arrive on API responses, so a session that has been idle keeps
# reporting the window it last saw — resets_at then sits in the past. Left as
# is, every recorded sample falls outside that window and the histogram draws
# as if nothing had ever been recorded. Advance by whole windows to the one we
# are actually in. (The percentages stay as last seen; only the axis is fixed.)
roll_forward() {
  rf=$1; rw=$2
  [ -n "$rf" ] && [ "$rf" -gt 0 ] 2>/dev/null || { echo "$rf"; return; }
  [ "$rf" -lt "$now" ] && rf=$(( rf + ( (now - rf) / rw + 1 ) * rw ))
  echo "$rf"
}
# Whether this session's figures are current decides if it may write to the
# shared series at all — see record_pace_sample.
rate_5h_live=0
rate_7d_live=0
[ -n "$rate_5h_reset" ] && [ "$rate_5h_reset" -gt "$now" ] 2>/dev/null && rate_5h_live=1
[ -n "$rate_7d_reset" ] && [ "$rate_7d_reset" -gt "$now" ] 2>/dev/null && rate_7d_live=1
rate_5h_reset=$(roll_forward "$rate_5h_reset" 18000)
rate_7d_reset=$(roll_forward "$rate_7d_reset" 604800)

# ── Git branch + dirty status ───────────────────────────────────────────────
git_branch=""
git_dirty=0
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  if ! git -C "$cwd" diff-index --quiet HEAD -- 2>/dev/null; then
    git_dirty=1
  fi
  if [ -n "$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | head -1)" ]; then
    git_dirty=2
  fi
fi


# ── Format token count ───────────────────────────────────────────────────────
# One decimal, rounded half-up, in shell arithmetic — matches awk's %.1f without
# paying for an awk start on every call.
fmt_tokens() {
  t=$1
  if [ "$t" -ge 1000000 ]; then
    d=$(( (t + 50000) / 100000 ))
    echo "$(( d / 10 )).$(( d % 10 ))M"
  elif [ "$t" -ge 1000 ]; then
    d=$(( (t + 50) / 100 ))
    echo "$(( d / 10 )).$(( d % 10 ))k"
  else
    echo "$t"
  fi
}

# ── Format epoch as clock time ───────────────────────────────────────────────
# Usage: fmt_clock <epoch> <mode>
#   mode: "short" → "HH:MM", "long" → "M/D HH:MM"
fmt_clock() {
  epoch=$1
  mode=$2
  if [ -z "$epoch" ] || [ "$epoch" -le 0 ] 2>/dev/null; then
    return
  fi
  if [ "$mode" = "long" ]; then
    epoch_fmt "$epoch" "%m-%d %H:%M"
  else
    epoch_fmt "$epoch" "%H:%M"
  fi
}

# ── Estimate epoch when usage hits 100% at current pace ─────────────────────
# Usage: estimate_full_epoch <used_pct_int> <remaining_secs> <window_secs> <now_epoch>
#   Returns epoch (integer) or empty if not estimable
estimate_full_epoch() {
  pct=$1
  remain=$2
  window=$3
  now_ep=$4
  if [ "$pct" -le 0 ] || [ "$pct" -ge 100 ]; then
    return
  fi
  elapsed=$(( window - remain ))
  if [ "$elapsed" -le 0 ]; then
    return
  fi
  time_to_full=$(( (100 - pct) * elapsed / pct ))
  echo $(( now_ep + time_to_full ))
}

# ── Instantaneous pace: the derivative of the ×N pace ratio ─────────────────
# ×N next to each bar is usage% / elapsed% — an integral over the whole window,
# so it lags: a quiet first hour hides the sprint happening right now. dU/dT
# answers "how fast am I burning at this moment", and holding it against ×N says
# whether the pace is climbing or falling.
# statusLine is stateless, so the series is persisted. Usage is per-account, so
# every session of the same account observes and extends the same series.
PACE_LOOKBACK=1800    # derivative is measured over this span (30 min)
PACE_SETTLE_SPAN=420  # below this the value is provisional — shown, but dimmed
# Kept outside TMPDIR: the histogram draws a whole window, so the 7d series has
# to survive a week, and macOS sweeps the per-user temp dir well before that.
PACE_DIR="$HOME/.claude/cache"

pace_key=""            # resolved once the email is known, before any pace call
pace_file() {
  printf '%s/claude-pace-%s-%s.tsv' "$PACE_DIR" "$pace_key" "$1"
}

# record_pace_sample <window_label> <utilization> <sample_gap> <keep_secs> <window_end>
# The gap is per window: 30s resolves a 5h window, 5min is plenty for 7d and
# keeps a week of samples down to a couple of thousand lines.
#
# Each row carries the window it belongs to, which is what separates "the window
# reset" from "a session reporting a reading a few minutes old". Both look
# identical as a drop in percentage — measured live, a stale session was 20
# points below a current one, the same size as a real reset — so no threshold on
# the value can tell them apart, and the old one guessed wrong often enough to
# wipe the history every few minutes. Keyed by window instead, a reset simply
# starts a new set of rows and nothing is ever deleted. Within one window a
# reading below the last is a stale observer, not news, so it is not written.
# Rows with no window (written by an earlier version) are read as current.
record_pace_sample() {
  pf=$(pace_file "$1")
  pv=$2; pgap=$3; pkeep=$4; pend=$5
  [ -z "$pv" ] && return
  [ -d "$PACE_DIR" ] || mkdir -p "$PACE_DIR" 2>/dev/null || return
  set -- $(awk -F'\t' -v cur="$pv" -v wend="$pend" '
    { nl++
      if (($3 == "" || $3 == wend) && $1 ~ /^[0-9]+$/) { lep = $1; lv = $2; seen = 1 }
    }
    END { printf "%d %d %d", seen ? lep : 0, nl + 0, (seen && cur < lv) ? 1 : 0 }
  ' "$pf" 2>/dev/null)
  last_ep=${1:-0}; lines=${2:-0}; backwards=${3:-0}
  if [ "$backwards" -eq 0 ] && [ $(( now - last_ep )) -ge "$pgap" ]; then
    printf '%s\t%s\t%s\n' "$now" "$pv" "$pend" >> "$pf"
  fi
  # Prune only once the file is well past what one window needs, so the rewrite
  # is rare and can't race the appends into losing much.
  if [ "$lines" -gt $(( pkeep / pgap * 2 + 100 )) ]; then
    awk -F'\t' -v c=$(( now - pkeep )) '$1 >= c' "$pf" > "$pf.tmp" 2>/dev/null \
      && mv "$pf.tmp" "$pf"
  fi
}

# instant_pace <window_label> <utilization> <window_secs>
# Echoes "<ok|prov>:<rate>" — the burn rate over the look-back as a multiple of
# "consuming the whole window at a flat rate". A span shorter than the settle
# time still yields a number, tagged prov so the caller can dim it: early on the
# series is a couple of samples wide and the value swings hard. Empty only while
# no earlier sample exists at all (first tick of a window).
instant_pace() {
  pf=$(pace_file "$1")
  [ -f "$pf" ] || return
  awk -F'\t' -v now="$now" -v cur="$2" -v w="$3" -v wend="$4" \
      -v look="$PACE_LOOKBACK" -v settle="$PACE_SETTLE_SPAN" '
    ($3 == "" || $3 == wend) && $1 ~ /^[0-9]+$/ && $1 >= now - look && $1 < now {
      if (base_t == 0 || $1 < base_t) { base_t = $1; base_v = $2 }
    }
    END {
      if (base_t == 0) exit
      span = now - base_t
      d = cur - base_v
      if (d < 0) exit
      v = (d / span) * (w / 100)
      if (v > 99) v = 99
      printf "%s:%s", (span >= settle) ? "ok" : "prov", \
        (v >= 10) ? sprintf("%.0f", v) : sprintf("%.1f", v)
    }
  ' "$pf"
}

# ── Consumption histogram, drawn on the window's own time axis ──────────────
# One cell per 1/50th of the window, so every column lines up with the race bar
# directly above it: ┃ sits under ┃, and a spike can be read against the ✗ it
# produced. Height is that slice's burn rate — ▄ is flat consumption (×1.0),
# █ is ×2 or worse.
# The row is always drawn at full width so it never vanishes from under its bar.
# Where there is no bar to draw the empty track shows through as the same dim ━
# the race bar uses for its unfilled part: left of ┃ that means unrecorded,
# right of ┃ it is simply the future. An idle slice that *was* recorded reads as
# a grey ▁ instead, so "nothing happened" stays distinct from "nothing known".
# pace_histogram <window_label> <window_secs> <reset_epoch> <time_pct> [width]
pace_histogram() {
  pf=$(pace_file "$1")
  ph_w=$2; ph_reset=$3; ph_tpct=$4; ph_width=${5:-50}
  # Without a window anchor nothing can be placed on the axis — lay the empty
  # track so the line still holds its place.
  if [ ! -f "$pf" ] || ! { [ -n "$ph_reset" ] && [ "$ph_reset" -gt 0 ] 2>/dev/null; }; then
    awk -v cells="$ph_width" 'BEGIN{
      for (i = 0; i < cells; i++) printf "\033[38;2;60;60;60m▁"
      printf "\033[0m"
    }'
    return
  fi
  awk -F'\t' -v now="$now" -v wstart=$(( ph_reset - ph_w )) -v w="$ph_w" \
      -v cells="$ph_width" -v tpct="$ph_tpct" -v ph_end="$ph_reset" '
    # n must start at a real 0: an uninitialised counter subscripts t[""], and
    # the resulting t[0] reads back as 0 — matching every cell boundary.
    BEGIN { n = 0; TRACK = "\033[38;2;60;60;60m▁"; R = "\033[0m" }
    ($3 == "" || $3 == ph_end) && $1 ~ /^[0-9]+$/ && $1 >= wstart && $1 <= now {
      t[n] = $1; v[n] = $2; n++
    }
    END {
      split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", B, " ")
      cell = w / cells
      # Same expression unified_bar uses, so the two ┃ land in the same column
      cursor = int(tpct * (cells - 1) / 100)
      flat = 100 / cells          # % a window consumes per cell at a flat rate
      j = 0; base = -1; out = ""
      # A cell can only be measured against the usage at its left edge, so the
      # first recorded cell is normally spent establishing that baseline. When
      # recording caught the window from its start, usage there was 0 by
      # definition — anchor on that instead and the first cell stays measurable.
      if (n > 0 && t[0] - wstart <= cell) base = 0
      for (i = 0; i < cells; i++) {
        if (i > cursor) { out = out TRACK R; continue }      # the future
        bt = wstart + (i + 1) * cell
        got = 0
        while (j < n && t[j] <= bt) { cur = v[j]; got = 1; j++ }
        if (!got && base < 0) { out = out TRACK R; continue } # never recorded
        if (base < 0) { base = cur; out = out "\033[38;2;108;108;108m" B[1] R; continue }
        d = (got ? cur : base) - base
        if (d < 0) d = 0
        base = (got ? cur : base)
        r = d / flat
        if (r <= 0) { out = out "\033[38;2;108;108;108m" B[1] R; continue }
        # Height is the coarse read and saturates at ×2 — eight glyphs is all
        # the vertical resolution a single terminal row has. Colour carries the
        # same quantity on a continuous ramp instead of repeating those eight
        # steps, so a near-miss (×0.9 against ×1.0) separates, and everything
        # past the height ceiling still ranks: ×2.1 and ×5 are both █ but not
        # the same red.
        lvl = int(r * 4 + 0.5)
        if (lvl < 1) lvl = 1
        if (lvl > 8) lvl = 8
        if (r <= 1)      { cr = int(255 * r); cg = 255; cb = 0 }
        else if (r <= 2) { cr = 255; cg = int(255 * (2 - r)); cb = 0 }
        else             { k = r - 2; if (k > 1) k = 1
                           cr = int(255 - 65 * k); cg = 0; cb = int(90 * k) }
        out = out sprintf("\033[38;2;%d;%d;%dm%s%s", cr, cg, cb, B[lvl], R)
      }
      printf "%s", out
    }
  ' "$pf"
}

total_tokens=$(( total_in + total_out ))
cache_total=$(( cache_read + cache_create ))
in_str=$(fmt_tokens "$total_in")
out_str=$(fmt_tokens "$total_out")
cache_str=$(fmt_tokens "$cache_total")

# ── Dynamic color by percentage ─────────────────────────────────────────────
pct_color() {
  pct=$1
  if [ "$pct" -ge 90 ]; then
    echo 196
  elif [ "$pct" -ge 80 ]; then
    echo 208
  elif [ "$pct" -ge 70 ]; then
    echo 220
  else
    echo 78
  fi
}

# ── Gradient progress bar (green → yellow → red, thin line) ────────────────
# Usage: progress_bar <pct> [nopct] [marker_pct] [color_mode] [width]
progress_bar() {
  pct=$1
  width=${5:-16}
  filled=$(( (pct * width + 99) / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  max_i=$(( width - 1 ))
  half=$(( max_i / 2 ))

  marker_pos=-1
  if [ -n "$3" ] && [ "$3" -ge 0 ] 2>/dev/null && [ "$3" -le 100 ] 2>/dev/null; then
    marker_pos=$(( ($3 * max_i + 99) / 100 ))
    [ "$marker_pos" -ge "$width" ] && marker_pos=$(( width - 1 ))
    [ "$marker_pos" -lt 0 ] && marker_pos=0
  fi

  bar=""
  i=0
  while [ $i -lt $width ]; do
    if [ $i -eq $marker_pos ]; then
      bar="${bar}\033[38;5;196m━"
    elif [ $i -lt $filled ]; then
      if [ "$4" = "blue" ]; then
        bar="${bar}\033[38;5;75m━"
      else
        if [ $i -le $half ]; then
          r=$(( i * 510 / max_i ))
          g=255
        else
          r=255
          g=$(( (max_i - i) * 510 / max_i ))
        fi
        bar="${bar}\033[38;2;${r};${g};0m━"
      fi
    else
      bar="${bar}\033[38;2;60;60;60m━"
    fi
    i=$(( i + 1 ))
  done

  if [ "$pct" -ge 90 ]; then
    pct_c=196
  elif [ "$pct" -ge 80 ]; then
    pct_c=208
  elif [ "$pct" -ge 70 ]; then
    pct_c=220
  else
    pct_c=78
  fi
  if [ "$2" = "nopct" ]; then
    printf "%s${reset}" "$bar"
  else
    printf "%s \033[38;5;${pct_c}m%d%%${reset}" "$bar" "$pct"
  fi
}

# ── Unified race bar: fill = usage%, ┃ = current time position, ✗ = predicted
#    point where usage hits 100% at current pace (only when it lands before reset)
# Usage: unified_bar <usage_pct> <time_pct> [marker_pct] [width]
unified_bar() {
  u_pct=$1
  t_pct=$2
  m_pct=$3
  width=${4:-50}
  filled=$(( (u_pct * width + 99) / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  max_i=$(( width - 1 ))
  half=$(( max_i / 2 ))
  cursor=$(( t_pct * max_i / 100 ))
  [ "$cursor" -gt "$max_i" ] && cursor=$max_i
  [ "$cursor" -lt 0 ] && cursor=0
  marker=-1
  if [ -n "$m_pct" ] && [ "$m_pct" -ge 0 ] 2>/dev/null && [ "$m_pct" -le 100 ] 2>/dev/null; then
    marker=$(( m_pct * max_i / 100 ))
    # ┃ (now) always wins the cell; push ✗ right so both stay visible
    [ "$marker" -le "$cursor" ] && marker=$(( cursor + 1 ))
    [ "$marker" -gt "$max_i" ] && marker=$max_i
  fi
  bar=""
  i=0
  while [ $i -lt $width ]; do
    if [ $i -eq $cursor ]; then
      bar="${bar}\033[1;38;5;255m┃\033[0m"
    elif [ $i -eq $marker ]; then
      bar="${bar}\033[1;38;5;196m✗\033[0m"
    elif [ $i -lt $filled ]; then
      if [ $i -le $half ]; then
        r=$(( i * 510 / max_i ))
        g=255
      else
        r=255
        g=$(( (max_i - i) * 510 / max_i ))
      fi
      bar="${bar}\033[38;2;${r};${g};0m━"
    else
      bar="${bar}\033[38;2;60;60;60m━"
    fi
    i=$(( i + 1 ))
  done
  printf "%s${reset}" "$bar"
}

# ── Underline progress on time text ─────────────────────────────────────────
# progress_time <part_a> <part_b> <pct> <color_a> <color_b>
#   part_a: colored text (est. full time)
#   part_b: dim text (" / reset_time")
#   Underline spans across both based on pct%
progress_time() {
  _a="$1"; _b="$2"; _pct=$3; _ca=$4; _cb=$5
  _full="${_a}${_b}"
  _total=${#_full}
  _filled=$(( _pct * _total / 100 ))
  [ "$_filled" -gt "$_total" ] && _filled=$_total
  _alen=${#_a}
  ul='\033[4m'

  # Underline stays ON for entire text; color change = progress boundary
  if [ "$_filled" -le "$_alen" ]; then
    _a_ul=$(printf '%s' "$_a" | cut -c1-"$_filled")
    _a_rest=$(printf '%s' "$_a" | cut -c"$((_filled+1))"-)
    printf "%b%b%s%b%s%b%s" "\033[38;5;${_ca}m" "$ul" "$_a_ul" "\033[38;5;${_cb}m" "$_a_rest" "\033[38;5;${_cb}m" "$_b"
  else
    _b_filled=$(( _filled - _alen ))
    _b_ul=$(printf '%s' "$_b" | cut -c1-"$_b_filled")
    _b_rest=$(printf '%s' "$_b" | cut -c"$((_b_filled+1))"-)
    printf "%b%b%s%b%s%b%s" "\033[38;5;${_ca}m" "$ul" "$_a" "\033[38;5;${_ca}m" "$_b_ul" "\033[38;5;${_cb}m" "$_b_rest"
  fi
}

# ── Separator ────────────────────────────────────────────────────────────────
sep="\033[38;5;240m │ ${reset}"

# ══════════════════════════════════════════════════════════════════════════════
# LINE 1 (output as line 2): Branch, Worktree, Current directory
# ══════════════════════════════════════════════════════════════════════════════
line1=""

# 🔀 Git branch — color reflects working tree status, 🌲 if worktree
if [ -n "$git_branch" ]; then
  branch_icon="🔀"
  wt_tag=""
  if [ -n "$worktree" ]; then
    branch_icon="🌲"
    branch_label="${git_branch}"
  else
    branch_label="${git_branch}"
  fi
  if [ "$git_dirty" -eq 2 ]; then
    line1="\033[38;5;196m${bold}${branch_icon} ${branch_label} ●${reset}"
  elif [ "$git_dirty" -eq 1 ]; then
    line1="\033[38;5;208m${bold}${branch_icon} ${branch_label} ✎${reset}"
  else
    line1="\033[38;5;78m${bold}${branch_icon} ${branch_label}${reset}"
  fi
else
  line1="\033[38;5;240m🚫 no git${reset}"
fi

# 📁 Current directory (shorten with ~)
if [ -n "$cwd" ]; then
  display_cwd="${cwd##*/}"
  [ -n "$line1" ] && line1="${line1}${sep}"
  line1="${line1}\033[38;5;252m󰉋  ${display_cwd}${reset}"
fi

# 👤 Authenticated account email — append to line1
# (not part of the statusLine stdin JSON; read from local Claude Code config)
# ~/.claude.json runs to a few hundred KB and only the account email is wanted
# from it, so the parse is cached for an hour — the value effectively never
# changes, and re-reading it every 10s cost more than everything else combined.
email=""
email_cache="$PACE_DIR/statusline-email"
if [ -f "$email_cache" ]; then
  ec_mtime=$(file_mtime "$email_cache")
  [ $(( now - ec_mtime )) -lt 600 ] && email=$(cat "$email_cache" 2>/dev/null)
fi
if [ -z "$email" ]; then
  email=$(jq -r '.oauthAccount.emailAddress // empty' "$HOME/.claude.json" 2>/dev/null)
  if [ -n "$email" ]; then
    [ -d "$PACE_DIR" ] || mkdir -p "$PACE_DIR" 2>/dev/null
    printf '%s' "$email" > "$email_cache" 2>/dev/null
  fi
fi
pace_key=$(printf '%s' "${email:-default}" | tr -c 'A-Za-z0-9' '_')
if [ -n "$email" ]; then
  [ -n "$line1" ] && line1="${line1}${sep}"
  line1="${line1}\033[38;5;245m👤 ${email}${reset}"
fi

# 🕒 Rate-limit data freshness — age of the shared usage cache.
# Shown only when the OAuth-usage fallback supplied the rate numbers (proxy
# path); shared across windows so every session prints the same age. Absent on
# the native-stdin path (direct OAuth), where numbers are already live.
if [ -n "$usage_asof" ]; then
  age=$(( $(date +%s) - usage_asof ))
  [ "$age" -lt 0 ] && age=0
  if [ "$age" -lt 60 ]; then
    age_str="${age}s"
  elif [ "$age" -lt 3600 ]; then
    age_str="$(( age / 60 ))m"
  else
    age_str="$(( age / 3600 ))h"
  fi
  if [ "$age" -ge 120 ]; then age_c=208; else age_c=245; fi
  [ -n "$line1" ] && line1="${line1}${sep}"
  line1="${line1}\033[38;5;${age_c}m🕒 ${age_str} ago${reset}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# LINE 2: Tokens + Context usage (own line)
# ══════════════════════════════════════════════════════════════════════════════
used_int=0
[ -n "$used" ] && used_int=$(printf "%.0f" "$used")
ctx_color=$(pct_color "$used_int")
used_raw=${used:-0}
if [ "$ctx_max" -gt 0 ] 2>/dev/null; then
  ctx_max_str=$(fmt_tokens "$ctx_max")
  ctx_used_tokens=$(( cur_in + cur_cache_read + cur_cache_create ))
  ctx_used_str=$(fmt_tokens "$ctx_used_tokens")
  ctx_info="${ctx_used_str} / ${ctx_max_str} (${used_int}%)"
else
  ctx_info="—"
fi
# "💭   " + " " = 6 cols before the bar, same as "⚡ 5h " on lines 3/4,
# so all three 50-col bars start at the same column.
line2="\033[38;5;255m💭   ${reset} $(progress_bar "$used_int" nopct "" "" 50) \033[38;5;${ctx_color}m${ctx_info}${reset}"
if [ -n "$model" ]; then
  line2="${line2}${sep}\033[38;5;75m${model}${reset}"
  [ -n "$effort" ] && line2="${line2}\033[38;5;245m [${effort}]${reset}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Rate limit shared calculations
# ══════════════════════════════════════════════════════════════════════════════
r5_int=0
[ -n "$rate_5h" ] && r5_int=$(printf "%.0f" "$rate_5h")
r5_color=$(pct_color "$r5_int")

r7_int=0
[ -n "$rate_7d" ] && r7_int=$(printf "%.0f" "$rate_7d")
r7_color=$(pct_color "$r7_int")

# Extend the series with this tick, then read the derivative back off it.
# Raw (fractional) utilization is used here — the integer percent shown on the
# bars is too coarse to differentiate over 30 minutes.
r5_inst=""; r7_inst=""
# Only a session whose window is still open may extend the series; one holding
# a window that already closed is reporting history, not the present.
if [ -n "$rate_5h" ]; then
  [ "$rate_5h_live" -eq 1 ] && record_pace_sample 5h "$rate_5h" 30 18000 "$rate_5h_reset"
  r5_inst=$(instant_pace 5h "$rate_5h" 18000 "$rate_5h_reset")
fi
if [ -n "$rate_7d" ]; then
  [ "$rate_7d_live" -eq 1 ] && record_pace_sample 7d "$rate_7d" 300 604800 "$rate_7d_reset"
  r7_inst=$(instant_pace 7d "$rate_7d" 604800 "$rate_7d_reset")
fi

# 5h time calculations
r5_time_pct=0; r5_marker=""
r5_full_clock="00:00"; r5_reset_clock="00:00"
if [ -n "$rate_5h_reset" ]; then
  r5_remaining=$(( rate_5h_reset - now ))
  r5_reset_clock=$(fmt_clock "$rate_5h_reset" "short")
  r5_reset_clock=${r5_reset_clock:-"00:00"}
  r5_full_epoch=$(estimate_full_epoch "$r5_int" "$r5_remaining" 18000 "$now")
  r5_full_clock=$(fmt_clock "$r5_full_epoch" "short")
  r5_full_clock=${r5_full_clock:-"00:00"}
  r5_window=18000
  r5_elapsed=$(( r5_window - r5_remaining ))
  [ "$r5_elapsed" -lt 0 ] && r5_elapsed=0
  r5_time_pct=$(( r5_elapsed * 100 / r5_window ))
  [ "$r5_time_pct" -gt 100 ] && r5_time_pct=100
  if [ -n "$r5_full_epoch" ] && [ "$r5_full_epoch" -gt 0 ] && [ "$r5_full_epoch" -lt "$rate_5h_reset" ]; then
    r5_wstart=$(( rate_5h_reset - r5_window ))
    r5_marker=$(( (r5_full_epoch - r5_wstart) * 100 / r5_window ))
    [ "$r5_marker" -gt 100 ] && r5_marker=100
    [ "$r5_marker" -lt 0 ] && r5_marker=0
  fi
fi

# 7d time calculations
r7_time_pct=0; r7_marker=""
r7_full_clock="00-00 00:00"; r7_reset_clock="00-00 00:00"
if [ -n "$rate_7d_reset" ]; then
  r7_remaining=$(( rate_7d_reset - now ))
  r7_reset_clock=$(fmt_clock "$rate_7d_reset" "long")
  r7_reset_clock=${r7_reset_clock:-"00-00 00:00"}
  r7_full_epoch=$(estimate_full_epoch "$r7_int" "$r7_remaining" 604800 "$now")
  r7_full_clock=$(fmt_clock "$r7_full_epoch" "long")
  r7_full_clock=${r7_full_clock:-"00-00 00:00"}
  r7_window=604800
  r7_elapsed=$(( r7_window - r7_remaining ))
  [ "$r7_elapsed" -lt 0 ] && r7_elapsed=0
  r7_time_pct=$(( r7_elapsed * 100 / r7_window ))
  [ "$r7_time_pct" -gt 100 ] && r7_time_pct=100
  if [ -n "$r7_full_epoch" ] && [ "$r7_full_epoch" -gt 0 ] && [ "$r7_full_epoch" -lt "$rate_7d_reset" ]; then
    r7_wstart=$(( rate_7d_reset - r7_window ))
    r7_marker=$(( (r7_full_epoch - r7_wstart) * 100 / r7_window ))
    [ "$r7_marker" -gt 100 ] && r7_marker=100
    [ "$r7_marker" -lt 0 ] && r7_marker=0
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# LINE 3 / LINE 4: Rate limit race bars (one line per window)
#   text: <usage%> ×<avg pace> <↗instant pace> [✗<predicted limit>] ↻<reset>
#   ✗ appears only when the predicted limit lands before the reset (= over pace)
#   ↗ / ↘ / → is the instant pace against the average: accelerating or easing off
#   dimmed grey on that figure = provisional, too few samples to trust yet
# ══════════════════════════════════════════════════════════════════════════════
# rate_line <label> <usage_pct> <usage_color> <time_pct> <marker_pct> <full_clock> <reset_clock> <instant_pace>
rate_line() {
  rl_label=$1; rl_pct=$2; rl_color=$3; rl_time=$4; rl_marker=$5
  rl_full=$6; rl_reset=$7; rl_inst=$8
  rl="\033[38;5;255m⚡\033[38;5;245m ${rl_label}${reset} $(unified_bar "$rl_pct" "$rl_time" "$rl_marker") \033[38;5;${rl_color}m$(printf '%4s' "${rl_pct}%")${reset}"
  if [ "$rl_time" -gt 0 ] && [ "$rl_pct" -gt 0 ]; then
    rl_ratio=$(awk "BEGIN{printf \"%.1f\", $rl_pct / $rl_time}")
    if [ "$rl_pct" -gt "$rl_time" ]; then rl_ratio_c=220; else rl_ratio_c=78; fi
    rl="${rl} \033[38;5;${rl_ratio_c}m×${rl_ratio}${reset}"
    if [ -n "$rl_inst" ]; then
      rl_q=${rl_inst#*:}
      rl_d=$(awk -v q="$rl_q" -v p="$rl_ratio" 'BEGIN{
        r = (p > 0) ? q / p : 0
        if      (r >= 2.00) printf "196:↗"
        else if (r >= 1.15) printf "220:↗"
        else if (r <= 0.85) printf "78:↘"
        else                printf "245:→"
      }')
      # Dimmed until the series spans the settle time — the arrow already points
      # the right way, the number just isn't trustworthy yet.
      case $rl_inst in
        prov:*) rl_qc=240 ;;
        *)      rl_qc=${rl_d%%:*} ;;
      esac
      rl="${rl} \033[38;5;${rl_qc}m${rl_d#*:}${rl_q}${reset}"
    fi
  fi
  [ -n "$rl_marker" ] && rl="${rl} \033[38;5;196m✗${rl_full}${reset}"
  # ⟳ renders 2 cells wide in some fonts while the terminal reserves 1 —
  # keep a space after it so it never overlaps the time
  rl="${rl} \033[38;5;245m⟳ ${rl_reset}${reset}"
  printf '%s' "$rl"
}

line3=$(rate_line "5h" "$r5_int" "$r5_color" "$r5_time_pct" "$r5_marker" "$r5_full_clock" "$r5_reset_clock" "$r5_inst")
line4=$(rate_line "7d" "$r7_int" "$r7_color" "$r7_time_pct" "$r7_marker" "$r7_full_clock" "$r7_reset_clock" "$r7_inst")

# Same 6-column indent as the bars above, so the histogram sits under its bar
hist5=$(pace_histogram 5h 18000 "$rate_5h_reset" "$r5_time_pct" 50)
hist7=$(pace_histogram 7d 604800 "$rate_7d_reset" "$r7_time_pct" 50)

# ── Output (6 lines, fixed — a histogram with nothing in it shows as track) ──
# 6 blank columns to clear the "⚡ 5h " label so each histogram sits under its
# bar. The leading \033[0m is load-bearing: a line that begins with whitespace
# gets left-trimmed before it reaches the terminal (confirmed by capturing what
# this script emits against what actually rendered), which shifted the whole
# histogram 6 columns left. Starting with an escape sequence keeps the spaces.
printf "%b\n%b\n%b\n\033[0m      %b\n%b\n\033[0m      %b" \
  "$line1" "$line2" "$line3" "$hist5" "$line4" "$hist7"
