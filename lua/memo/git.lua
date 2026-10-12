-- 管理フォルダを git リポジトリ（GitHub など）と同期する
local config = require("memo.config")

local M = {}

local state = {
  running = false, -- 同期中
  pending = false, -- 同期中に次の同期を頼まれた
  pending_manual = false,
  pulled_once = false, -- このセッションで一度 pull したか
  conflict = false, -- 競合で止まっている（自動同期を休む）
  timer = nil,
}

local function opts()
  return config.options.sync
end

local function dir()
  return config.options.dir
end

local function notify(msg, level)
  vim.notify("memo: " .. msg, level or vim.log.levels.INFO)
end

function M.is_repo()
  return vim.uv.fs_stat(dir() .. "/.git") ~= nil
end

local function git_cmd(args)
  -- core.quotepath=false: 日本語のファイル名をエスケープしない
  local cmd = { "git", "-c", "core.quotepath=false", "-C", dir() }
  return vim.list_extend(cmd, args)
end

-- GIT_TERMINAL_PROMPT=0: 認証が必要でも入力待ちで固まらずに失敗させる
local ENV = { GIT_TERMINAL_PROMPT = "0" }

-- 非同期で git を実行。cb(ok, stdout, stderr) はメインループで呼ばれる
local function run(args, cb)
  local ok, err = pcall(vim.system, git_cmd(args), { text = true, env = ENV }, function(res)
    vim.schedule(function()
      cb(res.code == 0, vim.trim(res.stdout or ""), vim.trim(res.stderr or ""))
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(false, "", "git を実行できません: " .. tostring(err))
    end)
  end
end

-- 同期実行（終了時用）
local function run_wait(args, timeout)
  local ok, obj = pcall(vim.system, git_cmd(args), { text = true, env = ENV })
  if not ok then
    return false, ""
  end
  local res = obj:wait(timeout)
  return res.code == 0, vim.trim(res.stdout or ""), vim.trim(res.stderr or "")
end

-- steps: { function(next, fail) ... } を順番に実行
local function chain(steps, done)
  local i = 0
  local function next_step()
    i = i + 1
    local step = steps[i]
    if not step then
      return done(true)
    end
    step(next_step, function(msg)
      done(false, msg)
    end)
  end
  next_step()
end

local function commit_message()
  return os.date(opts().commit_message)
end

-- 変更があれば add + commit
local function step_commit(next, fail)
  run({ "status", "--porcelain" }, function(ok, out, err)
    if not ok then
      return fail(err)
    end
    if out == "" then
      return next()
    end
    run({ "add", "-A" }, function(ok2, _, err2)
      if not ok2 then
        return fail(err2)
      end
      run({ "commit", "-q", "-m", commit_message() }, function(ok3, out3, err3)
        if not ok3 then
          return fail(err3 ~= "" and err3 or out3)
        end
        next()
      end)
    end)
  end)
end

local function refresh_ui()
  vim.cmd("silent! checktime")
  pcall(function()
    require("memo.sidebar").refresh()
  end)
end

--- commit → pull --rebase → push
--- @param manual boolean :MTSync から呼ばれたか（結果を必ず通知する）
function M.sync(manual)
  if not M.is_repo() then
    if manual then
      notify(("%s は git リポジトリではありません。:MTSync init <URL> で設定できます"):format(dir()), vim.log.levels.WARN)
    end
    return
  end
  if state.running then
    state.pending = true
    state.pending_manual = state.pending_manual or manual
    return
  end
  if state.conflict and not manual then
    return
  end
  state.running = true
  state.pulled_once = true
  local before, has_remote, has_upstream

  chain({
    step_commit,
    function(next)
      run({ "remote" }, function(_, out)
        has_remote = out ~= ""
        next()
      end)
    end,
    function(next)
      if not has_remote then
        return next()
      end
      run({ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, function(ok)
        has_upstream = ok
        next()
      end)
    end,
    function(next)
      run({ "rev-parse", "HEAD" }, function(_, out)
        before = out
        next()
      end)
    end,
    function(next, fail)
      if not has_upstream then
        return next()
      end
      run({ "pull", "--rebase", "--autostash", "-q" }, function(ok, out, err)
        if ok then
          return next()
        end
        -- 競合など。競合したファイルを控えてから rebase を取り消し、手元の状態に戻す
        run({ "diff", "--name-only", "--diff-filter=U" }, function(_, files)
          run({ "rebase", "--abort" }, function()
            state.conflict = true
            if files ~= "" then
              fail(("競合しました: %s\n手元の内容はそのままです。ターミナルで解決してから :MTSync を実行してください（それまで自動同期は止めます）")
                :format(table.concat(vim.split(files, "\n"), ", ")))
            else
              fail("pull に失敗しました\n" .. (err ~= "" and err or out))
            end
          end)
        end)
      end)
    end,
    function(next, fail)
      if not has_remote then
        return next()
      end
      local args = has_upstream and { "push", "-q" } or { "push", "-q", "-u", "origin", "HEAD" }
      run(args, function(ok, out, err)
        if not ok then
          return fail("push に失敗しました\n" .. (err ~= "" and err or out))
        end
        next()
      end)
    end,
  }, function(ok, msg)
    run({ "rev-parse", "HEAD" }, function(_, after)
      state.running = false
      if ok then
        state.conflict = false
        local pulled = before ~= nil and before ~= "" and after ~= before
        if pulled then
          refresh_ui()
        end
        if manual then
          notify(has_remote and "同期しました" or "commit しました（リモートが未設定です）")
        elseif pulled and opts().notify_pull then
          notify("リモートの変更を取り込みました")
        end
      else
        notify(msg or "同期に失敗しました", vim.log.levels.ERROR)
      end
      if state.pending then
        local m = state.pending_manual
        state.pending, state.pending_manual = false, false
        M.sync(m)
      end
    end)
  end)
end

--- 変更があったときに呼ぶ。少し待ってから同期する
function M.schedule()
  if not opts().auto or not M.is_repo() then
    return
  end
  if not state.timer then
    state.timer = vim.uv.new_timer()
  end
  state.timer:stop()
  state.timer:start(opts().delay * 1000, 0, vim.schedule_wrap(function()
    M.sync(false)
  end))
end

--- セッションで最初に一覧などを開いたときに一度だけ pull
function M.pull_once()
  if state.pulled_once or not opts().auto or not opts().pull_on_open or not M.is_repo() then
    return
  end
  M.sync(false)
end

--- Neovim 終了時: 未送信の変更を commit して push（待ち時間に上限あり）
function M.on_exit()
  if not opts().auto or not opts().push_on_exit or not M.is_repo() then
    return
  end
  if state.timer then
    state.timer:stop()
  end
  local ok, out = run_wait({ "status", "--porcelain" }, 3000)
  if ok and out ~= "" then
    run_wait({ "add", "-A" }, 3000)
    run_wait({ "commit", "-q", "-m", commit_message() }, 3000)
  end
  local _, remotes = run_wait({ "remote" }, 3000)
  if remotes == "" then
    return
  end
  -- 送っていない commit があるときだけ push
  local has_up = run_wait({ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, 3000)
  if has_up then
    local _, ahead = run_wait({ "rev-list", "--count", "@{u}..HEAD" }, 3000)
    if ahead == "0" then
      return
    end
  end
  run_wait(has_up and { "push", "-q" } or { "push", "-q", "-u", "origin", "HEAD" }, opts().exit_timeout * 1000)
end

--- 既存の管理フォルダをリモートリポジトリにつなぐ
function M.init(url)
  if not url or url == "" then
    notify("使い方: :MTSync init <リポジトリの URL>", vim.log.levels.ERROR)
    return
  end
  if state.running then
    notify("同期中です。少し待ってからもう一度実行してください", vim.log.levels.WARN)
    return
  end
  vim.fn.mkdir(dir(), "p")
  state.running = true
  local branch
  notify("リポジトリを設定しています…")

  chain({
    function(next, fail)
      if M.is_repo() then
        return next()
      end
      run({ "init", "-q", "-b", "main" }, function(ok, _, err)
        if not ok then
          return fail(err)
        end
        next()
      end)
    end,
    function(next, fail)
      run({ "remote", "get-url", "origin" }, function(exists)
        local args = exists and { "remote", "set-url", "origin", url } or { "remote", "add", "origin", url }
        run(args, function(ok, _, err)
          if not ok then
            return fail(err)
          end
          next()
        end)
      end)
    end,
    function(next, fail)
      step_commit(next, function(err)
        fail("commit できません。git config --global user.name / user.email を設定してください\n" .. err)
      end)
    end,
    function(next)
      run({ "symbolic-ref", "--short", "HEAD" }, function(_, out)
        branch = out ~= "" and out or "main"
        next()
      end)
    end,
    function(next, fail)
      run({ "fetch", "-q", "origin" }, function(ok, _, err)
        if not ok then
          return fail("リモートに接続できません。URL と認証（一度ターミナルで git push できるか）を確認してください\n" .. err)
        end
        next()
      end)
    end,
    function(next, fail)
      -- リモートに既に中身があれば取り込む
      run({ "rev-parse", "--verify", "-q", "origin/" .. branch }, function(exists)
        if not exists then
          return next()
        end
        run({ "pull", "-q", "--no-rebase", "--allow-unrelated-histories", "--no-edit", "origin", branch }, function(ok, out, err)
          if not ok then
            return fail("リモートの内容と競合しました。ターミナルで解決してください\n" .. (err ~= "" and err or out))
          end
          next()
        end)
      end)
    end,
    function(next, fail)
      run({ "push", "-q", "-u", "origin", branch }, function(ok, out, err)
        if not ok then
          return fail("push に失敗しました\n" .. (err ~= "" and err or out))
        end
        next()
      end)
    end,
  }, function(ok, msg)
    state.running = false
    state.pulled_once = true
    if ok then
      state.conflict = false
      refresh_ui()
      notify(("%s を %s と同期しました"):format(dir(), url))
    else
      notify(msg, vim.log.levels.ERROR)
    end
  end)
end

-- テスト用
function M._state()
  return state
end

return M
