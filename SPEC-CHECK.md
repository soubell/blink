# Blink 仕様確認レポート (blink-tor 設計の前提検証)

対象: `soubell/blink` ローカルクローン `~/workspace/blink-tor` (branch `raw`, HEAD `6669181`, version 18.7.2)
日付: 2026-11-27
方法: ソース精読のみ (Xcode ビルド不可の環境のため、ビルド/実行確認は含まない)

## 1. ProxyCommand の入力経路 — ✅ 設計通り

- ホストは ssh_config 形式で管理される。`BKConfig` が `blinksh/SSHConfig` (SPM, ≥0.0.5) で `.blink/ssh_config` を parse し、`BKGlobalSSHConfig` が `Include ../.ssh/config` を差し込むので **`~/.ssh/config` も有効**
- `BlinkConfig/BKSSHHost.swift:134` — `proxycommand` キーを parse して `proxyCommand` に保持、未知キーは skip。`:170` で `SSHClientConfig.proxyCommand` へ受け渡し
- **設定 UI に ProxyCmd 欄が実在**: `Settings/ViewControllers/BKHosts/HostView.swift:547` `Field("ProxyCmd", ..., placeholder: "ssh -W %h:%p bastion")`。ユーザーは既存 UI に `tor %h %p` と書ける。新規 UI ゼロの前提は成立
- CLI の `-o ProxyCommand=...` も `SSHCommand.sshOptions()` 経由で BKSSHHost に入る

## 2. libssh callback の契約 — ✅ 検証済み (Blink 独自パッチ)

- libssh は本家ではなく **blinksh/libssh-apple v0.12.0** の静的 xcframework (`xcfs/Package.swift:18`)。`set_proxycommand_function` は Blink 独自パッチによる callback
- `SSH/SSHClient.swift:278` — callback は `(cmd: String, inSock: Int32, outSock: Int32) -> Void` の Swift closure。connect 中に同期的に呼ばれ、未設定時は "No proxy callback configured" でソケットを shutdown する
- 現行の `BlinkSSH.executeProxyCommand` は callback 内で `ios_system` を同期実行している = **callback 内でブロックするのが既存パターン**。TorPipe が bootstrap 待ち + SOCKS 接続を callback 内で同期的に行う設計で問題ない
- callback を受ける call site は3系統:
  - `Blink/Commands/ssh/ssh.swift:173` (SSHPool 経由)
  - `Blink/Commands/ssh/CopyFiles.swift:362` (scp/sftp、`SSHClient.dial` 直接、プールなし)
  - `Blink/Commands/ssh/SSHCopyID.swift:162` (同上)
  - いずれも共通の `BlinkSSH.executeProxyCommand` を呼ぶ → 横取り1箇所で全部に効く、は正しい

## 3. `%h` / `%p` の展開 — ⚠️ 実績ベースで「展開される」、実装時に単体確認

- libssh (パッチ版) が callback へ渡す前に展開する、という直接のコード証拠は xcframework がバイナリ配布のため読めない
- 間接証拠: Mosh の ProxyJump 経路 (下記 §5) は callback で受けたコマンド文字列を parse して `-W host:port` の実値を使う実装で、実運用されている (本家 issue #1982 で `ProxyCmd ssh -W %h:%p JUMP` + mosh の動作報告あり)。展開されなければ成立しない
- 実装フェーズで SSHTests に「callback に渡る文字列」確認テストを1本入れて最終確定する

## 4. ControlMaster — 🚨 設計上の穴を発見、対策を必須化

- グローバル既定設定 (`BKGlobalSSHConfig.saveFile()`) は全ホストに `ControlMaster auto` を配る。つまり**デフォルトで有効**
- 再利用の照合キーが甘い:
  - `SSH/SSHClientConfig.swift:215` — `==` は **user と port だけ**を比較 (proxyCommand を見ない)
  - `Blink/Commands/ssh/SSHPool.swift:317` `isConnection(for:with:)` — 照合は hostName 文字列 + 上記 `==` のみ
- 結果: 同じ hostName/user/port なら、**直結で張った既存接続を Tor 指定の接続が再利用してしまう** (逆もあり得る)。fail-closed 原則が静かに崩れる
- 対策 (既存機構で完結する):
  - `ssh.swift:161` の `useControlMaster` 決定箇所で、proxyCommand が tor-magic の場合は `-W` 時と同じく **`.no` を強制**する
  - `.no` の場合 `SSHPool.dial` は `startConnection(exposeSocket: false)` になり、`isConnection` は非 exposed な control を常に弾く → Tor 接続が再利用されることも、直結接続を掴むこともなくなる
  - CopyFiles / SSHCopyID はプールを経由しないので対象外
- 代替案として `SSHClientConfig.==` に proxyCommand を含める手もあるが、既存の照合セマンティクス全体に影響するので v1 では採らない

## 5. Mosh — ⚠️ ガードなしだとクラッシュする

- `Blink/Commands/mosh/mosh.swift:445` の private `executeProxyCommand` は ios_system を使わず、受けたコマンドを `SSHCommand.parse` して **`stdioHostAndPort!` を force unwrap** する (コマンドが `ssh -W ...` 形式である前提)
- `tor %h %p` がここに流れると parse 結果に stdioHostAndPort がなく **クラッシュ** する
- よって Tor 指定ホストへの mosh は「接続開始前」に弾く必要がある (callback 内では遅い)。mosh コマンドの config 解決直後に proxyCommand の tor-magic 判定を入れて明示エラーにする

## 6. Files.app (BlinkFileProvider) — ✅ fail-closed で安全

- `BlinkFileProvider/SSH/SSHClient.swift:103` は独自に `ProxyCommand(command)` で parse を試み、失敗したら `cancelProxy` でソケットを閉じる
- `tor ...` は parse 失敗 → 接続失敗で終わる。直結フォールバックもクラッシュもしない。v1 では「Files.app 経由の Tor 接続は非対応 (失敗する)」で確定してよい

## 7. ビルド仕様 — ✅ 概ね設計通り、数値の訂正あり

- **アプリ本体の deployment target は 17.6** (`Blink.xcodeproj/project.pbxproj`、Blink ターゲット)。16.1 は SSH 等のフレームワーク側。→ 対応デバイスは iOS 17.6 以降
- 本家 CI (`.github/workflows/build.yml`): `macOS-latest` + Xcode 15.0 固定で BlinkTests のみ実行。無署名 IPA 手順はコメントアウトで残存 (archive + `IPHONEOS_DEPLOYMENT_TARGET='16.1'` override + Payload zip)。Xcode 15 では SDK が 17.0 のため 17.6 ターゲットと噛み合わない → ipa.yml は macos-15 / 既定 Xcode (16系) を使う設計判断は正しい
- entitlements (`Blink/Blink.entitlements`): aps-environment、associated-domains (webcredentials:blink.sh)、iCloud コンテナ/CloudKit/CloudDocuments、ubiquity-kvstore、keychain-access-groups、application-groups、user-fonts、default web browser 等。再署名 (SideStore 等、個人 Team) では iCloud / Push / associated-domains は落ちる前提。**keychain-access-groups が変わると既存鍵にアクセスできなくなる**が、サイドロードは新規インストール扱いなので v1 では実害なし (回帰確認項目には残す)
- scheme `Blink`、configuration は Debug (`BLINK_PUBLISHING_OPTION_DEVELOPER`) / Release (`..._TESTFLIGHT`) の使い分けは設計書記載通り

## まとめ: 設計への反映

| # | 項目 | 結論 |
|---|------|------|
| 1 | ProxyCmd 入力欄 (UI / ssh_config) | 実在する。新規 UI ゼロで成立 |
| 2 | callback 契約・同期ブロック | 問題なし。既存パターン通り |
| 3 | `%h`/`%p` 展開 | 実績上は展開される。実装時にテストで確定 |
| 4 | ControlMaster | **Tor 時は `.no` 強制を必須仕様に追加** (デフォルト auto + 照合キーに proxy なし) |
| 5 | Mosh | callback 前段で弾く (放置すると force unwrap でクラッシュ) |
| 6 | FileProvider | fail-closed 確認。v1 非対応で確定 |
| 7 | ビルド | deployment target 17.6 に訂正。Xcode は 16 系を使う |
