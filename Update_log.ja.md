# L4D2 AnneHappy Rework 更新記録

## 更新記録

### 2026年6月12日-7月3日 更新記録
#### Anne モードと特殊感染者スポーン
- Anne 系の対戦モードで第三者視点が使えない問題を修正しました。`!tp` と第三者視点関連 cvar は Anne 系共有設定から適用されます。
- `infected_control.smx` のリファクタリングと最適化を継続しました。Left4DHooks PVS/可視性補助、スポーン性能設定、キュー調整、ウェーブ判定整理を追加し、異常スポーン、Smoker の二重舌、補充ウェーブが速すぎる問題を減らしました。
- `anne_cvar_shield.smx` を追加し、Anne の重要 cvar を保護します。プラグインや投票の残留設定が別モードの難度へ混ざるのを防ぎます。
- 26-7 テスト設定 `Anne25-11.cfg` を追加し、旧版 `infected_control25-11.smx` をロールバック用として保持しました。動的難度ドキュメントも更新しました。
- 極限難度の値が他の難度へ影響する問題を修正しました。動的難度切り替え時に Tank、Hunter などの段階別パラメータをより明確にリセットします。
- セーフルーム内の近接武器が出ない場合がある問題を修正し、`MeleeInTheSafeRoom` の処理を整理しました。
- `extra_menu` 対応の刷特投票メニュー `spawn_vote_menu.smx` を追加しました。Anne/キャンペーンの特殊感染者数、間隔、自動モード、テレポート判定、プリセットを投票で調整できます。
- not0721 系 coop/community/mutation モード、dirspawn preset、武器設定、SI limit 設定を追加・整理しました。
- `infected_control` に裏切り者モード関連ロジック、スポーン preset テーブル、多言語フレーズを追加し、今後の玩法拡張に備えました。

#### プレイヤー体験、投票、フィードバック
- 旧 `hextags` を `hextags_lite.smx` に置き換え、称号色の問題を修正しました。管理者コマンドを隠し、設定ファイルは `hextags_lite.cfg` に移行しました。
- `global_chat.smx`、`join.smx` と関連メッセージに多言語フレーズを追加し、全体チャット状態やチーム募集受信状態などを補いました。
- `l4d_stats.smx` の四半期ランキングと永続化まわりを修正し、ラウンド状態記録を補強しました。一部のデータベース処理と混雑時ステータス書き込み負荷も下げました。
- 旧 `killsound` と「叮叮叮」音效投票の機能を `l4d2_hitsound.smx` に統合しました。古い `sound_on/off` 投票ファイルを削除し、命中、キル、ヘッドショットの音效とアイコンをフィードバック插件で一元管理します。
- `spechud.sp` を更新し、ping 表示、ボーナス割合の内訳表示、観戦遅延表示の修正を追加しました。
- `basevotes.smx` を無効化し、無蓄力 Hunter の直接投票項目を削除しました。Anne 動的難度と新しい投票メニューとの衝突を減らします。
- `server_name.smx` は SourceBans description を直接書き換えなくなりました。表示処理は外部 proxy 側へ移しました。
- 混雑時アンロードと NPC 管理のチェック/提示頻度を下げ、混雑時の追加負荷を抑えました。
- 一部の管理者コマンド出力を隠し、プレイヤー向けチャットのノイズを減らしました。

#### 上流同期、マップ、基礎依存
- Left4DHooks、gamedata、include、テスト用源码を更新し、新しい native/forward を補いました。関連插件も再ビルドしました。
- `ai_tank3.smx` を更新し、RPG スコア権限処理と極限難度の callback/パラメータ問題を修正しました。Tank 行動設定も調整しました。
- Dead Center 2025、City 17、No Echo m3、Carried Off `cwm1_intro` などの上流 map/stripper 修正を同期しました。適用できる zonemod 更新は `zonemod_anne` にも反映しました。
- `cwm1_intro` の hittable/clipwall 修正を同期し、複数モードの `mapinfo.txt` を補いました。
- Rust 製サーバーブラウザ工具と Docker デプロイ README をこの仓库から削除しました。関連ワークフローは外部工具/网页側で维护します。
- `basevotes.smx` の配置、SourceMod 設定、データベース字段、複数ドキュメントを更新し、插件包構造を整理しました。
