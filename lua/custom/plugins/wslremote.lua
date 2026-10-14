local wsl = require("wslremote")

wsl.setup({
  default_host = "Ubuntu", -- distro name by `wsl -l'
  remote_nvim = "/home/yo_waka/.local/nvim-linux-x86_64/bin/nvim", -- if not found by WSL, set fullpath
})

vim.keymap.set("n", "<leader>wf", wsl.find_files, { desc = "[W]SL [F]iles" })
vim.keymap.set("n", "<leader>wg", wsl.live_grep, { desc = "[W]SL [G]rep" })
vim.keymap.set("n", "<leader>ww", wsl.grep_string, { desc = "[W]SL current [W]ord" })
vim.keymap.set("n", "<leader>wt", "<cmd>tab WslTerm<cr>", { desc = "[W]SL [T]erminal" })
vim.keymap.set("n", "<leader>wo", function()
  vim.ui.input({ prompt = "WSL open (tab): ", default = "Ubuntu:~/src/github.com/" }, function(input)
    if input and input ~= "" then
      vim.cmd("tab WslOpen " .. input)
    end
  end)
end, { desc = "[W]SL [O]pen in new tab" })

return {}
