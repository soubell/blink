# blink-tor 設計 (v1 ドラフト)

対象: `soubell/blink` (fork of blinksh/blink, default branch `raw`, HEAD `6669181`)
目的: VPN構成 (Network Extension) なしで、Blink 内蔵の Tor 経由で SSH 接続する。
**主用途 (2026-11-27 そうた訂正): 通常の (clearnet) サーバへ、送信元 IP を Tor の出口ノードに変えて SSH すること**。`.onion` のサーバへは繋がない (ATYP domain のため副次的に繋がるが要件ではない)。
前提: ビルドは GitHub Actions で無署名 IPA を作り、署名はサイドロード側 (SideStore/AltStore 等) で後付けする。

## 1. スコープ

- 対象: `ssh`, `scp`, `sftp`, `ssh-copy-id` (いずれも `SSHClient.dial` + ProxyCommand callback を通る)
- 対象外: **Mosh** — 本体トラフィックが UDP で Tor に乗らない。Tor 指定ホストへの mosh は明示エラーで弾く (bootstrap 用 SSH だけ Tor に乗せて本体が直結、という最悪の漏れ方を防ぐ)。弾く位置は callback より前段 (config 解決直後) が必須 — Mosh 側 `executeProxyCommand` はコマンドが `ssh -W` 形式前提で `stdioHostAndPort!` を force unwrap しており、`tor ...` が流れるとクラッシュする (SPEC-CHECK.md §5)
- 対象外 (v1): Files.app (BlinkFileProvider) 経由の Tor 接続 — 独自 parse が失敗して接続エラーになる fail-closed を確認済み (漏れ・クラッシュなし、SPEC-CHECK.md §6)
- 対象外 (v1): bridges (obfs4 / Snowflake 等)。v2 で IPtProxyUI の Transport と設定 UI を一緒に入れる
- 対象外 (v1): SSH 用ローカルエコー / 予測エコー (2026-11-27 そうた決定: 「いったんv1ではやらない」)。SSH はサーバ側エコー前提のまま。Blink には mosh 専用の予測オプションしかなく、SSH 用は存在しないことを確認済み。やるなら v2 で簡易版 (打鍵即表示 + エコー重複除去、フルスクリーンアプリでは崩れる割り切り) を検討

## 2. 起動方式: Magic ProxyCommand

ホスト設定の ProxyCommand に次を指定すると Tor 経由になる:

```
ProxyCommand tor %h %p
```

- Host の Advanced 設定にも `~/.ssh/config` にも既存の欄で書ける。新規 UI ゼロで v1 が成立する
  - 仕様確認済み (SPEC-CHECK.md §1): 設定 UI に ProxyCmd 欄が実在 (`Settings/ViewControllers/BKHosts/HostView.swift:547`)、`~/.ssh/config` は `Include ../.ssh/config` で有効
- `ssh -W` 用のジャンプホスト指定など、通常の ProxyCommand とは文字列で排他に判定できる (`tor` で始まる場合のみ横取り、それ以外は従来動作)
- v2 で設定 UI に Tor トグルを追加し、内部でこの ProxyCommand を生成する形に拡張できる

## 3. 差し込み点

`Blink/Commands/ssh/ssh.swift` の `BlinkSSH.executeProxyCommand(command:sockIn:sockOut:errFd:)`:

- 現行: libssh の proxycommand callback から呼ばれ、`ios_system(cmd)` で内部コマンドを実行し stdin/stdout を libssh のソケット fd に dup2 する
- 変更: 先頭で magic 判定。`tor <host> <port>` なら `ios_system` に渡さず `TorPipe.run(host:port:sockIn:sockOut:errFd:)` を呼ぶ
- この static 関数は ssh / CopyFiles (scp・sftp) / SSHCopyID の全 call site から共有されているので、1箇所の変更で全コマンドに効く
- Mosh 側 (`Blink/Commands/mosh/mosh.swift` の private `executeProxyCommand`) は別実装。こちらは横取りせず、Tor 指定時は接続開始前にエラーにする

### libssh callback の契約 (仕様確認済み — SPEC-CHECK.md §2/§3)

- libssh は blinksh/libssh-apple v0.12.0 (独自パッチ版)。callback は `(command: String, inSock: Int32, outSock: Int32) -> Void` の Swift closure で、connect 中に同期的に呼ばれる
- callback 内でブロックするのは既存パターン (現行実装も `ios_system` を同期実行)。TorPipe が bootstrap 待ち・SOCKS 接続を同期で行ってよい
- `cmd` 内の `%h` / `%p` は libssh が展開済みのはず (Mosh の ProxyJump 経路が展開前提で実運用されているのが根拠)。実装時に SSHTests で callback へ渡る文字列を確認して最終確定する。TorPipe は展開後の host / port を parse する

## 4. Tor の組み込み

Onion Browser 3.X と同構成 (実績あり):

- SPM 依存を追加 (実装済み — TorProxy.swift):
  - `https://github.com/iCepa/Tor.framework` (≥ 409.17.1, upToNextMajor) の **CTor** プロダクトのみ。TorConfiguration / TorThread / TorController が揃う
  - `IPtProxyUI-ios` は v1 では入れない (当初案から変更)。bridges を使わない v1 では Transport の型しか必要なく、Tor 側は `UseBridges 0` で足りるため。bridges と一緒に v2 で追加する
- `TorService` (アプリ側 singleton, 新規):
  - `TorConfiguration`: `cookieAuthentication = true`, `autoControlPort = true`, `clientOnly = true`, `avoidDiskWrites = true`, `dataDirectory = Library/tor`, `options: ["SocksPort": "auto"]` (Onion Browser の `TorManager.getTorConf()` が雛形)
  - `TorThread` 起動 → `TorController(controlPortFile:)` 接続 → `status/bootstrap-phase` で進捗取得、`net/listeners/socks` で実際の SOCKS endpoint を取得 (port は `auto` 任せにして衝突回避)
  - 状態: `stopped / bootstrapping(Int%) / ready(NWEndpoint) / failed(Error)`

## 5. TorPipe (SSH フレームワーク側, 新規)

入力: host, port, sockIn, sockOut, errFd

1. `TorService.shared.socksEndpoint()` — 未起動なら Tor を起動し bootstrap 100% まで待つ。進捗を errFd に出力 (`Connecting to Tor... 45%`)。タイムアウト既定 120s
2. `NWConnection` で SOCKS endpoint へ接続
3. SOCKS5 ハンドシェイク: no-auth greeting → CONNECT、**ATYP は常に domain** (名前解決を Tor 側に寄せる = DNS 漏れ防止 + `.onion` 対応)
4. 成功後、双方向ポンプ:
   - inSock → NWConnection.send
   - NWConnection.receive → outSock へ write
   - 片側 EOF で半閉じ、エラーで両側 close。libssh 側の切断検知に任せる
5. SOCKS のメッセージ組み立ては既存 `SSH/SOCKS.swift` の `SOCKSMessage` を流用・拡張する (現在はサーバ側 framer 用途)

### Fail-closed 原則

- Tor が ready でない / SOCKS が失敗した場合は**直結にフォールバックしない**。接続をエラーで中止する
- これを破るコードパスを作らない (通常の ProxyCommand なし接続と Tor 接続は設定時点で排他)

## 6. ライフサイクル / 同時接続

- Tor は初回 Tor 接続時に遅延起動し、以後アプリ生存中は常駐 (再 bootstrap の待ち時間を毎回払わない)
- 複数の Tor 接続は同じ Tor プロセス / SOCKS を共有する。回路分離は v1 では Tor 既定 (SOCKS 認証情報による分離は v2 検討)
- ControlMaster との関係: **Tor 接続では ControlMaster を `.no` に強制する (必須仕様)**。仕様確認で判明した穴 (SPEC-CHECK.md §4): グローバル既定で全ホスト `ControlMaster auto` が有効なうえ、SSHPool の再利用照合は hostName + user + port のみで proxyCommand を見ないため、放置すると直結の既存接続を Tor 指定接続が再利用してしまう。`ssh.swift` の `useControlMaster` 決定箇所で tor-magic 時に `.no` を返せば、`SSHPool.dial` が非 exposed で張るため双方向とも再利用されなくなる (`-W` 時に `.no` にする既存前例と同じ形)。CopyFiles / SSHCopyID はプール経由でないので対象外

## 7. ビルド: GitHub Actions で無署名 IPA

本家 `.github/workflows/build.yml` にコメントアウトで残っている無署名 IPA 手順が原型。新規に `.github/workflows/ipa.yml` を作る:

- trigger: `workflow_dispatch` + 作業ブランチへの push
- `runs-on: macos-latest` + `setup-xcode latest-stable` (実装済み — ipa.yml)。本家 CI の Xcode 15.0 固定では Tor.framework 409.17.1 の swift-tools 6.3 を解決できないため、最新の安定版 Xcode を使う
- steps:
  1. `actions/checkout@v4` (`submodules: recursive`)
  2. `actions/cache@v4`: `xcfs/.build`, `Frameworks/ios_system/xcfs/.build` (本家 CI と同じキー設計)
  3. `./get_frameworks.sh` / `./get_resources.sh` (cache miss 時のみ)
  4. `cp template_setup.xcconfig developer_setup.xcconfig`
  5. SPM 解決 + ビルド:
     `xcodebuild build -project Blink.xcodeproj -scheme Blink -sdk iphoneos -configuration Debug CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
  6. `Payload/` に `.app` を入れて zip → `Blink-tor.ipa`
  7. `actions/upload-artifact@v4` で IPA と build.log を保存
- **Debug configuration を使う理由**: Release は `BLINK_PUBLISHING_OPTION_TESTFLIGHT` で課金 (Blink+) シナリオが有効になる。Debug の `BLINK_PUBLISHING_OPTION_DEVELOPER` がサイドロード用途に合う
- アプリ本体の deployment target は **17.6** (SPEC-CHECK.md §7)。対応デバイスは iOS 17.6 以降
- 署名時に落ちる entitlements (iCloud / Push / Keychain sharing 等) のうち、Tor 機能と SSH 本体に必須なものが無いことは実装時に確認する (Keychain は鍵保存に絡むため要注意 — 再署名先の keychain-access-group で動くか実機確認項目)

## 8. テスト / 検証項目

- CI: 無署名 IPA が生成できること (ビルド成功が最低ライン)
- 実機 (サイドロード後):
  - 通常ホストへの直結 SSH が従来通り (回帰なし)
  - clearnet ホストへ Tor 経由で接続し、サーバ側ログで出口ノード IP になっている (主用途の本命テスト)
  - (副次) `ProxyCommand tor %h %p` で `.onion` の SSH サーバへ接続できる
  - Tor bootstrap 中の表示、失敗時に直結へ漏れない (機内モード / Tor 到達不能環境で接続が失敗すること)
  - mosh を Tor ホストに使おうとすると明示エラーになる
  - アプリをバックグラウンドに置いて戻った後のセッション継続 (Tor プロセスのサスペンド挙動)

## 9. 未決事項

- [ ] 起動方式は Magic ProxyCommand で確定でよいか (vs 最初から設定 UI トグル)
- [x] bridges は v1 では入れない (2026-11-27 そうた決定: 「ブリッジは一旦なし」)。Transport は `.none` 固定
- [ ] Tor の常駐ポリシー: アプリ生存中ずっと / 最後の Tor 接続が切れたら停止
- [ ] 回路分離 (ホスト毎に SOCKS 認証を変える) を v1 に入れるか
