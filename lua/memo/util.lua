local M = {}

-- 削除確認（テストなどで差し替えられるように関数にしておく）
function M.confirm(msg)
  return vim.fn.confirm(msg, "&Yes\n&No", 2) == 1
end

return M
