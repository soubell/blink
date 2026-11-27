# blink-tor v1 — サイドロード & 実機テスト手順

用意済み (2026-11-27 10:22 JST 確認):
- `Blink-18.7.2-2065-unsigned.ipa` (61 MB, SHA-256 `a70eb9527bc11b236622b612a3213d67ceb59076098c44f2f4c851f1603d8195`)
  - 出所: soubell/blink `feat/tor-v1` run 45909712734 (commit `09ff031`) の artifact `Blink-unsigned-ipa`
  - 検証済み: zip 正常 (3007 files)、バイナリ内に `TorProxy` / `TorService` / `TorCommand.isMagic` のシンボルと Tor 本体の文字列あり (Tor は静的リンクのため Frameworks/ に単独バンドルはない)
  - GitHub 上の artifact 期限: **2026-12-10 23:24 UTC まで**。過ぎたら Actions から再ダウンロードか再ビルドが必要
- `Blink-sideload.entitlements` — 再署名時に使う sideload 用 entitlements (iCloud / Push / Keychain sharing / App Group を落とした版)

## 1. サイドロード (署名は端末側で後付け)

未署名のままでは入らない。Sideloadly / AltStore / SideStore / Xcode のいずれかで自分の証明書で再署名してインストールする
(BUILD.md 「GitHub Actions: unsigned IPA」節の通り。`codesign` でやる場合は `--entitlements Blink-sideload.entitlements` を付ける)。

注意: 無料/個人チームだと App Group (`group.sh.blink`) が付かず、Blink はアプリ内コンテナ
(`Library/Application Support/Blink`) にフォールバックして起動する。File Provider など拡張との共有はその場合は使えない。
鍵保存まわり (Keychain) が再署名先で動くかは実機確認項目。

## 2. Tor 接続テスト (本命)

1. Blink でホスト設定を開き、**ProxyCmd 欄に `tor %h %p` とだけ書く** (これが Magic ProxyCommand の合言葉)。
   対象は普通の clearnet サーバでいい (`.onion` はおまけ)。
2. 接続する。初回は Tor の bootstrap が走り、進捗がターミナルに出る (`Connecting to Tor... 45%` のような表示、タイムアウト 120s)。
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
