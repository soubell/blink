# blink-tor v1 — サイドロード & 実機テスト手順

用意済み (2026-11-27 12:26 JST 確認):
- `Blink-18.7.2-2065-unsigned.ipa` (61 MB, SHA-256 `369c6869c5bc38587d5ec6775289fd3b97ac82db491502eb06a3bfe555f9e1f1`)
  - 入手先: GitHub Release `unsigned-ipa` の資産 (生の IPA が直接落ちる。Actions artifact の zip 二重包みは廃止)
    https://github.com/soubell/blink/releases/download/unsigned-ipa/Blink-18.7.2-2065-unsigned.ipa
  - 出所: soubell/blink `feat/tor-v1` run 45933198907 (commit `3a6706e`)
  - この版の変更点: Tor 起動失敗の修正その3 (本命)。TorController は init 内で connect 済みなのに、接続済み状態で connect() を呼ぶとエラーなしで NO を返し、Swift 側で汎用エラーになっていた。実機3回目のテストでは Tor 自体は bootstrap 69% まで正常に進んでいたのに、こちらの接続ループだけが「失敗」していた。`isConnected` を見てから connect するよう修正 (Onion Browser と同じ)
  - 検証済み: バイナリ内に `TorProxy` / `TorService` / `TorCommand.isMagic` / `PhaseHeartbeat` のシンボルと Tor 本体の文字列あり (Tor は静的リンクのため Frameworks/ に単独バンドルはない)
## 1. サイドロード (署名は端末側で後付け)

未署名のままでは入らない。Sideloadly / AltStore / SideStore / Xcode のいずれかで自分の証明書で再署名してインストールする
(BUILD.md 「GitHub Actions: unsigned IPA」節の通り)。成果物は IPA 単体のみ。
sideload 用 entitlements はビルド時に適用済みで、ファイル自体はリポジトリの `Blink/Blink-sideload.entitlements` にある (手動 `codesign --entitlements` する場合のみ必要)。

注意: 無料/個人チームだと App Group (`group.sh.blink`) が付かず、Blink はアプリ内コンテナ
(`Library/Application Support/Blink`) にフォールバックして起動する。File Provider など拡張との共有はその場合は使えない。
鍵保存まわり (Keychain) が再署名先で動くかは実機確認項目。

## 2. Tor 接続テスト (本命)

1. Blink でホスト設定を開き、**ProxyCmd 欄に `tor %h %p` とだけ書く** (これが Magic ProxyCommand の合言葉)。
   対象は普通の clearnet サーバでいい (`.onion` はおまけ)。
2. 接続する。初回は Tor の bootstrap が走り、進捗がターミナルに出る (タイムアウト 120s):
   ```
   blink-tor: Starting Tor
   blink-tor: bootstrap 45%
   blink-tor: Building Tor circuit to example.com:22
   blink-tor: Connected to example.com:22 via Tor
   ```
   待たされている間は 10 秒ごとに `blink-tor: Building Tor circuit to ... — 20s` のような経過表示が繰り返される。これが出ていれば「遅いだけ」、失敗した場合は `blink-tor: Tor failed to start: ...` のように理由が出て接続が切れる (直結には落ちない)。
3. 繋がったらサーバ側で接続元 IP を確認する: **自分の IP ではなく Tor の出口ノードの IP になっていること**。
   サーバ側で Tor 出口からの接続をブロックしている場合は接続自体が失敗する (漏れるわけではない)。
4. 回帰確認: ProxyCmd を空にした通常ホストへの直結 SSH が従来通り動くこと。

## 3. fail-closed / 例外の確認 (DESIGN-tor.md §8)

- 機内モードや Tor に届かない環境では、**接続が失敗すること** (直結に落ちないこと)。
- そのホストに mosh を使うと**明示エラーで弾かれること** (Tor は TCP のみ、mosh 本体は UDP のため)。
- アプリをバックグラウンドに置いて戻った後のセッション継続。

## 4. 既知の割り切り (v1)

- SSH のローカルエコー/予測エコーなし (v2 候補)。Tor 経由だと表示が数百ms〜1秒遅れるが、入力自体は順番通り入る。
- bridges なし。Tor がブロックされる環境では繋がらない。
- Tor は初回接続時に遅延起動し、以後アプリ生存中は常駐。
