-- neo-tree のソース「wslremote」：WSL 側のディレクトリをツリー表示する
--
-- neo-tree の設定で sources に "wslremote.neotree" を足すと使える。
-- ファイル一覧は WSL 側のエージェントが返し、開くと wsl:// バッファになる。

local base = (...):match("^(.*)%.[^.]+$")
local P = require(base .. ".path")
local rpc = require(base .. ".rpc")
local wsl = require(base)

local manager = require("neo-tree.sources.manager")
local renderer = require("neo-tree.ui.renderer")
local cc = require("neo-tree.sources.common.commands")
local inputs = require("neo-tree.ui.inputs")

local api = vim.api

local M = {
  name = "wslremote",
  display_name = " 󰌽 WSL ",
}

-- M.reveal() から navigate へ渡す値（navigate は同期的に呼ばれる）
local pending

local HIDDEN = { [".git"] = true }

---------------------------------------------------------------------------
-- ツリーの組み立て
---------------------------------------------------------------------------

local function make_items(host, dir, entries)
  local items = {}
  for _, e in ipairs(entries) do
    if not HIDDEN[e.name] then
      local full = P.join(dir, e.name)
      local id = P.make(host, full)
      local item = { id = id, name = e.name, path = id, extra = { host = host, rpath = full } }
      if e.type == "directory" then
        item.type = "directory"
        item.loaded = false
        item.children = {}
      else
        item.type = "file"
        item.ext = e.name:match("%.([^.]+)$")
      end
      items[#items + 1] = item
    end
  end
  return items
end

-- preload に含まれるディレクトリは、開いた状態で中身も読み込んでおく
local function fill(item, preload)
  if item.type ~= "directory" or not preload[item.id] then
    return
  end
  local ok, entries = pcall(rpc.request, item.extra.host, "scandir", item.extra.rpath)
  if not ok then
    return
  end
  item.children = make_items(item.extra.host, item.extra.rpath, entries)
  item.loaded = true
  for _, child in ipairs(item.children) do
    fill(child, preload)
  end
end

local function show_message(state, msg, callback)
  state.path = "wslremote://message"
  renderer.show_nodes({ { id = "wslremote-msg", name = msg, type = "message" } }, state, nil, callback)
end

--- 現在のタブ / バッファから表示するルートを決める
local function current_target()
  local root = vim.t.wslremote_root
  if root then
    return P.parse(root)
  end
  return wsl.current_root()
end

---------------------------------------------------------------------------
-- neo-tree から呼ばれる口
---------------------------------------------------------------------------

function M.navigate(state, path, path_to_reveal, callback, _)
  local req = pending
  pending = nil

  local host, root
  if req and req.host then
    host, root = req.host, req.root
  elseif P.is_remote(path) then
    host, root = P.parse(path)
  elseif state.wsl then
    host, root = state.wsl.host, state.wsl.root
  else
    host, root = current_target()
  end
  if not host then
    return show_message(state, "WSL のタブで開いてください（<leader>wo）", callback)
  end

  local root_id = P.make(host, root)

  -- 同じルートなら、今開いているディレクトリを開いたまま読み直す
  local preload = { [root_id] = true }
  if state.tree and state.path == root_id then
    for _, id in ipairs(renderer.get_expanded_nodes(state.tree)) do
      preload[id] = true
    end
  end

  local reveal = req and req.reveal
  if reveal then
    local _, rpath = P.parse(reveal)
    local rel = P.relative(rpath, root)
    if rel and rel ~= "." then
      local dir = root
      local parts = vim.split(rel, "/", { plain = true })
      for i = 1, #parts - 1 do
        dir = P.join(dir, parts[i])
        preload[P.make(host, dir)] = true
      end
    else
      reveal = nil
    end
  end

  local root_item = {
    id = root_id,
    name = root == "/" and "/" or P.basename(root),
    path = root_id,
    type = "directory",
    loaded = false,
    children = {},
    extra = { host = host, rpath = root },
  }
  local ok, err = pcall(function()
    local entries = rpc.request(host, "scandir", root)
    root_item.children = make_items(host, root, entries)
    root_item.loaded = true
    for _, child in ipairs(root_item.children) do
      fill(child, preload)
    end
  end)
  if not ok then
    return show_message(state, tostring(err), callback)
  end

  state.path = root_id
  state.wsl = { host = host, root = root }
  state.default_expanded_nodes = vim.tbl_keys(preload)

  renderer.show_nodes({ root_item }, state, nil, function()
    if reveal then
      renderer.focus_node(state, reveal)
    end
    if callback then
      callback()
    end
  end)
end

function M.setup(_, _) end

---------------------------------------------------------------------------
-- 外から使う関数
---------------------------------------------------------------------------

--- WSL のタブなら WSL のツリーを開いて今のファイルを表示し true を返す。
--- WSL と関係ない場所なら何もせず false を返す。
function M.reveal(opts)
  opts = opts or {}
  local host, root = current_target()
  if not host then
    return false
  end
  local name = api.nvim_buf_get_name(0)
  pending = {
    host = host,
    root = root,
    reveal = P.is_remote(name) and name or nil,
  }
  local state = manager.get_state(M.name)
  state.dirty = true
  require("neo-tree.command").execute({
    source = M.name,
    action = opts.action or "focus",
    toggle = opts.toggle,
  })
  pending = nil
  return true
end

---------------------------------------------------------------------------
-- コマンド（キーマップから呼ばれる）
---------------------------------------------------------------------------

local C = {}

local function refresh(state)
  M.navigate(state, state.path)
end

local function toggle_directory(state, node)
  node = node or state.tree:get_node()
  if not node or node.type ~= "directory" then
    return
  end
  if node.loaded == false then
    local id = node:get_id()
    rpc.request_async(node.extra.host, "scandir", { node.extra.rpath }, function(entries, err)
      if err then
        return vim.notify(err, vim.log.levels.ERROR)
      end
      if not renderer.window_exists(state) then
        return
      end
      renderer.show_nodes(make_items(node.extra.host, node.extra.rpath, entries), state, id)
    end)
  else
    if node:is_expanded() then
      node:collapse()
    else
      node:expand()
    end
    renderer.redraw(state)
  end
end

-- open 系はすべて「ディレクトリなら展開、ファイルなら wsl:// として開く」
for _, name in ipairs({
  "open",
  "open_split",
  "open_vsplit",
  "open_tabnew",
  "open_drop",
  "open_tab_drop",
  "open_rightbelow_vs",
  "open_leftabove_vs",
  "open_with_window_picker",
  "split_with_window_picker",
  "vsplit_with_window_picker",
}) do
  if cc[name] then
    C[name] = function(state)
      cc[name](state, function(node)
        toggle_directory(state, node)
      end)
    end
  end
end

C.toggle_node = function(state)
  cc.toggle_node(state, function(node)
    toggle_directory(state, node)
  end)
end

C.refresh = refresh

C.navigate_up = function(state)
  if not state.wsl or state.wsl.root == "/" then
    return
  end
  state.wsl.root = P.parent(state.wsl.root)
  M.navigate(state, nil)
end

C.set_root = function(state)
  local node = state.tree:get_node()
  if node and node.type == "directory" and node.extra then
    state.wsl.root = node.extra.rpath
    M.navigate(state, nil)
  end
end

-- 対象ディレクトリ（カーソルがファイルならその親）
local function target_dir(state)
  local node = state.tree:get_node()
  if not node or not node.extra then
    return state.wsl and state.wsl.host, state.wsl and state.wsl.root
  end
  if node.type == "directory" then
    return node.extra.host, node.extra.rpath, node:get_id()
  end
  return node.extra.host, P.parent(node.extra.rpath), node:get_parent_id()
end

local function after_change(state, dir_id)
  if dir_id then
    local ok, node = pcall(state.tree.get_node, state.tree, dir_id)
    if ok and node then
      node:expand()
    end
  end
  refresh(state)
end

C.add = function(state)
  local host, dir, dir_id = target_dir(state)
  if not host then
    return
  end
  inputs.input("新規ファイル（末尾 / でディレクトリ）: " .. dir .. "/", "", function(name)
    if not name or name == "" then
      return
    end
    local path = P.join(dir, name)
    local ok, err = pcall(function()
      if name:sub(-1) == "/" then
        rpc.request(host, "mkdir", path)
      else
        rpc.request(host, "create", path)
      end
    end)
    if not ok then
      return vim.notify(tostring(err), vim.log.levels.ERROR)
    end
    after_change(state, dir_id)
  end)
end

C.add_directory = function(state)
  local host, dir, dir_id = target_dir(state)
  if not host then
    return
  end
  inputs.input("新規ディレクトリ: " .. dir .. "/", "", function(name)
    if not name or name == "" then
      return
    end
    local ok, err = pcall(rpc.request, host, "mkdir", P.join(dir, name))
    if not ok then
      return vim.notify(tostring(err), vim.log.levels.ERROR)
    end
    after_change(state, dir_id)
  end)
end

C.delete = function(state)
  local node = state.tree:get_node()
  if not node or not node.extra or node:get_depth() == 1 then
    return
  end
  inputs.confirm("削除しますか？ " .. node.extra.rpath, function(yes)
    if not yes then
      return
    end
    local ok, err = pcall(rpc.request, node.extra.host, "delete", node.extra.rpath)
    if not ok then
      return vim.notify(tostring(err), vim.log.levels.ERROR)
    end
    refresh(state)
  end)
end

C.rename = function(state)
  local node = state.tree:get_node()
  if not node or not node.extra or node:get_depth() == 1 then
    return
  end
  inputs.input("新しい名前: ", node.name, function(name)
    if not name or name == "" or name == node.name then
      return
    end
    local to = P.join(P.parent(node.extra.rpath), name)
    local ok, err = pcall(rpc.request, node.extra.host, "rename", node.extra.rpath, to)
    if not ok then
      return vim.notify(tostring(err), vim.log.levels.ERROR)
    end
    refresh(state)
  end)
end

-- 共通コマンド（close_node, close_window, show_help, next_source など）はそのまま使う
for k, v in pairs(cc) do
  if C[k] == nil then
    C[k] = v
  end
end
M.commands = C
M.components = require("neo-tree.sources.common.components")

-- WSL 側では使えないものは無効化しておく
local unsupported = {
  "c", "m", "p", "x", "y", "P", "l", "i", "b",
}
local mappings = {
  ["\\"] = "close_window",
  ["<bs>"] = "navigate_up",
  ["."] = "set_root",
  ["R"] = "refresh",
}
for _, key in ipairs(unsupported) do
  mappings[key] = "none"
end

M.default_config = {
  renderers = {
    directory = { { "indent" }, { "icon" }, { "name" } },
    file = { { "indent" }, { "icon" }, { "name" } },
    message = { { "indent", with_markers = false }, { "name", highlight = "NeoTreeMessage" } },
  },
  window = { mappings = mappings },
}

return M
