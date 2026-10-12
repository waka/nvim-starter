# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリについて

Windows 向けの個人用 Neovim 設定（`%LOCALAPPDATA%\nvim`）です。kickstart.nvim をベースにしていますが、lazy.nvim ではなく Neovim 組み込みの `vim.pack` を使います（Neovim 0.12 以上が必要）。自作のメモ / ToDo プラグインが `lua/memo` にあり、込み入ったコードはほぼここに集まっています。

README.md、コード内のコメント、コマンドの説明、`vim.notify` のメッセージは日本語です。ユーザーに見える文字列やコメントを足すときも日本語で書きます。コマンド・キー・設定項目を変えたら README.md も更新します（すべて README に載っています）。

## コマンド

ビルド、lint の設定、テストはありません。変更の確認は設定を読み込んで行います。

```powershell
nvim --headless "+lua require('memo')" +qa      # 設定と memo プラグインがエラーなく読み込めるか
```

プラグイン（Neovim の中で実行）:

```vim
:lua vim.pack.update()                          " プラグインを更新（nvim-pack-lock.json が書き換わる）
:lua vim.pack.update(nil, { offline = true })   " 状態と保留中の更新を確認
```

`nvim-pack-lock.json` はプラグインのリビジョンを固定するファイルで、コミット対象です。`vim.pack.add` でプラグインを足すと変更されます。

## 構成と読み込み順

- `init.lua` — 設定の本体。番号付きの `do ... end` セクションが並びます（オプション → キーマップ → `vim.pack` のビルドフック → UI プラグイン → Telescope → conform → blink.cmp → 個人用の「SECTION 999」）。各プラグインは `vim.pack.add { gh '...' }` の直後に `setup()` を呼ぶ形で、遅延読み込みはしていません。LSP サーバーとフォーマッタは未設定です。
- `lua/custom/plugins/init.lua` — 同じフォルダにある他の `*.lua` をすべて require します（順序は不定）。SECTION 999 から呼ばれるので、Telescope の setup より後に動きます。
- `lua/custom/plugins/memo.lua` — `require('memo').setup{}` を呼んでいる唯一の場所。
- `lua/memo/` — memo プラグイン（ローカルにあり、`vim.pack` の管理外）。

環境依存のパスを直接書いている箇所: `init.lua` の `project_roots`（`:Project` のピッカー。`fd` を使う）と、`lua/custom/plugins/memo.lua` の `dir`（メモの保存先）。

書き方は場所によって違い、stylua の設定はありません。`init.lua` と `lua/custom` は kickstart 流（シングルクォート、`require 'x'` のように括弧なし）、`lua/memo` はダブルクォートと括弧付きの呼び出しです。編集するファイルに合わせます。

## memo プラグインの設計

データモデル: 1 つのフォルダ（`config.options.dir`）に Markdown を平置きします。ファイル名は frontmatter の `title` をサニタイズしたものです。メモと ToDo の違いは `type: todo` かどうかだけで、それ以外はすべてメモ扱いです。タイトルが `daily_format` に一致するメモはデイリーメモになります。インデックスやキャッシュはなく、`store.list_all()` は呼ばれるたびにフォルダを読み直して解析します。

モジュール:

- `config.lua` — 既定値（設定項目の正となる一覧）と `options`。`setup` は deep merge したあと、リスト型の項目（`sidebar.sections`、`ignore`、`claude.cmd`、`claude.args`）を丸ごと上書きします。`tbl_deep_extend` はリストを添字ごとに混ぜてしまうためです。リスト型の項目を足すときは同じ処理が必要です。`dir` はここで正規化され、`store.is_memo_path` は正規化済みの dirname と比較することでそれに依存しています。
- `store.lua` — ファイル I/O 全般。frontmatter の解析、一覧と並べ替え、作成 / 削除、デイリーの判定、`sync_filename`（保存時に `title` が変わっていたらファイル名を変え、`link.rename_links` で他のメモの `[[リンク]]` も書き換える）。
- `init.lua` — `setup`。ユーザーコマンド（`:Memo`、`:Todo`、`:MT`、`:MTSync`、`:MTClaude`）と、全体をつなぐ autocmd を定義します。メモのパスで `BufReadPost` / `BufNewFile` が起きるとチェックボックスとリンクのバッファローカルなキーを付け、`BufWritePost` では `sync_filename` → `sidebar.refresh` → `git.schedule` の順に動きます。
- `sidebar.lua` — `:MT` の一覧ペイン。段ごとにスクラッチバッファとウィンドウを 1 つずつ持ち（`memo://memo`、`memo://todo` など）、描画した行から項目を引く `line_items[buf][lnum]` を保持します。他のモジュールはファイルを開く前に `sidebar.leave()` を呼び、一覧のウィンドウにファイルが開かないようにしています。
- `telescope.lua` — ピッカー全般（一覧、本文の行 / ToDo 項目の絞り込み、リンク先の選択、バックリンク）。Telescope は `deps()` の中で遅延 require します。
- `link.lua` — `[[タイトル]]` / `[[タイトル#見出し]]` / `[[タイトル|表示名]]` の解析、リンクを辿る・挿入する、バックリンク、リネーム時の書き換え、extmark によるハイライト。
- `checkbox.lua` — チェックボックスの切り替え。バッファ上と、ファイルを直接書き換える版（ToDo 項目ピッカー用）の両方があります。
- `git.lua` — `dir` が git リポジトリのときの裏での同期。commit → `pull --rebase --autostash` → push を、`vim.system` のコールバックをつなぐ非同期の `chain` で組んでいます。1 つの `state` テーブルで実行を直列化し（`running` / `pending`）、競合したら rebase を取り消して `state.conflict` を立て、手動の `:MTSync` まで自動同期を止めます。`on_exit` はタイムアウト付きで待つ同期版の `run_wait` を使います。
- `claude.lua` — `:MTClaude`。メモのフォルダを cwd にして Claude Code をターミナルバッファで動かし、メモの書式を説明するシステムプロンプトを渡します（`system_prompt()` で生成してキャッシュフォルダに書き出し、`--append-system-prompt-file` で指定）。`vim.uv` の fs_event でメモのフォルダを監視し、外部からの変更を `checktime` / 一覧の再描画 / git 同期に反映します。

モジュールをまたぐ決まり:

- 通常の `:w` 以外でメモを書き換え・リネーム・削除する処理は、自分で `require("memo.git").schedule()`（`sync.delay` 秒のデバウンス付き）を呼び、一覧も再描画する必要があります。`:w` の場合は `BufWritePost` の autocmd が両方やります。
- メモの書式は 2 か所で定義されていて、揃えておく必要があります。`store.create` / `store.parse_frontmatter` と、`claude.system_prompt()` のプロンプト本文です。
- メモのファイル操作には `vim.fn.readfile` / `writefile` と `vim.uv.fs_*` を使います。`io.open` / `os.remove` は Windows で非 ASCII（日本語）のパスを扱えません。
- require が循環しうるモジュール（`git`、`sidebar`、`link`、`telescope`、`memo`）は、ファイルの先頭ではなく関数の中で require しています。この形に合わせます。
- `util.confirm`、`git._state()`、`claude._state()` はテスト用の差し替え口です（テスト自体はリポジトリに入っていません）。
