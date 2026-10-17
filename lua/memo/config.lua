local M = {}

M.defaults = {
  -- メモと ToDo を置くディレクトリ（両方ここに入る）
  dir = "~/memo",
  -- :Memo d で作るデイリーメモのファイル名（os.date 形式）
  daily_format = "%Y-%m-%d",
  -- frontmatter の created に入れる日時
  created_format = "%Y-%m-%d %H:%M",
  -- frontmatter の title を書き換えて保存したら、ファイル名も追従させる
  sync_filename = true,
  -- チェックボックス切り替え（メモディレクトリ内の markdown バッファで有効）
  checkbox_key = "<leader>x",
  picker = {
    -- Telescope 内のキー。n = ノーマルモード, i = 挿入モード（false で無効）
    keys = {
      grep = { n = "g", i = "<C-g>" }, -- 本文 / ToDo 項目の絞り込みへ
      delete = { n = "d", i = false }, -- 削除（確認あり）
      toggle = { n = "x", i = false }, -- ToDo 項目ピッカーで完了にする
      insert = { n = "/", i = false }, -- ノーマルモードから絞り込み入力へ戻る
    },
    -- ToDo 項目ピッカーに完了済み（- [x]）も含めるか
    todo_items_include_done = false,
  },
  -- git 同期（dir が git リポジトリのときだけ動く）
  sync = {
    auto = true, -- 変更のたびに自動で commit / pull / push
    delay = 10, -- 最後の変更から何秒待って同期するか
    pull_on_open = true, -- セッションで最初に :Memo / :Todo / :MT を使ったとき pull
    push_on_exit = true, -- Neovim 終了時に未送信の変更を push
    exit_timeout = 5, -- 終了時の push を待つ最大秒数
    notify_pull = true, -- リモートの変更を取り込んだら通知
    commit_message = "memo: %Y-%m-%d %H:%M", -- os.date 形式
    conflict = "stop", -- 競合したら "stop": 自動同期を止める / "copy": 相手の版を採用し自分の版を別メモに残す
  },
  -- 共有（家族・チームと共有するリポジトリ。管理フォルダの中の shared/ に置く）
  shared = {
    enabled = true,
    dir = "shared", -- 管理フォルダの中のフォルダ名
    label = "共有", -- 一覧ペインの見出し
    sync = {
      auto = true,
      delay = 5, -- 最後の変更から何秒待って同期するか
      poll = 120, -- 何秒おきにほかの人の変更を取り込むか（0 で無効）
      pull_on_open = true,
      push_on_exit = true,
      exit_timeout = 5,
      notify_pull = true,
      commit_message = "shared: %Y-%m-%d %H:%M",
      conflict = "copy",
    },
  },
  -- :MTClaude（管理フォルダで Claude Code を開く）
  claude = {
    cmd = "claude", -- 実行ファイル。{ "claude", "--model", "sonnet" } のようにリストでも可
    args = {}, -- 追加の引数（例: { "--permission-mode", "acceptEdits" }）
    continue = false, -- true なら前回の会話の続きから始める（--continue）
    layout = "right", -- "right" / "bottom" / "float"
    size = 0.4, -- right / bottom のときの幅・高さ（画面に対する割合）
    float_size = 0.8, -- float のときの大きさ
    -- "classic": 会話を Neovim のターミナル履歴に流す（ホイールでスクロール・/ で検索できる）
    -- "fullscreen": Claude Code 標準のフルスクリーン表示（スクロールは PgUp / PgDn）
    renderer = "classic",
    scrollback = 100000, -- 遡れる行数
    keys = {
      hide = "<C-q>", -- Claude のウィンドウを隠す（セッションは続く）
      pass_esc = true, -- Esc をすぐ Claude に渡す（kickstart の <Esc><Esc> と競合させない）
    },
  },
  -- メモ間リンク [[タイトル]]
  link = {
    follow_key = "<CR>", -- リンクの上で押すと開く（リンク以外では本来の動作）
    insert_key = "[[", -- 挿入モードで打つとリンク先を選ぶ一覧が出る（false で無効）
    create_missing = true, -- まだないメモへのリンクを開いたら作る
    update_on_rename = true, -- タイトルを変えたら他のメモのリンクも書き換える
  },
  -- 一覧に出さないファイル
  ignore = { "CLAUDE.md", "AGENTS.md", "README.md" },
  sidebar = {
    width = 32,
    -- 上から並べる段。"daily" を入れるとデイリーが独立した段になる。
    -- 入れなければ Memo の段の中に開閉できる「Daily」フォルダとして出る
    sections = { "memo", "todo", "shared" },
    daily_expanded = false, -- Daily フォルダを最初から開いておくか
    icons = { open = "▾", closed = "▸" },
  },
}

M.options = vim.deepcopy(M.defaults)

local function normalize_dir(dir)
  local d = vim.fs.normalize(vim.fn.expand(dir))
  d = vim.fn.resolve(d)
  d = d:gsub("/+$", "")
  return d
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- リストは添字ごとに混ざるので、指定があればそのまま使う
  if opts and opts.sidebar and opts.sidebar.sections then
    M.options.sidebar.sections = vim.deepcopy(opts.sidebar.sections)
  end
  for _, key in ipairs({ "ignore" }) do
    if opts and opts[key] then
      M.options[key] = vim.deepcopy(opts[key])
    end
  end
  if opts and opts.claude then
    for _, key in ipairs({ "cmd", "args" }) do
      if opts.claude[key] then
        M.options.claude[key] = vim.deepcopy(opts.claude[key])
      end
    end
  end
  M.options.dir = normalize_dir(M.options.dir)
end

M.options.dir = normalize_dir(M.options.dir)

return M
