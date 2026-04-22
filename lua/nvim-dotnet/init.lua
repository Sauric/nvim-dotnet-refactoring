local M = {}

local defaults = {
  -- set to a keymap string like "<leader>cr" to override, or false to skip
  keymap = nil,
}

M.setup = function(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts or {})

  vim.api.nvim_create_user_command("DotnetRename", function()
    require("nvim-dotnet.rename").rename()
  end, { desc = "Rename C# symbol (renames file too when name matches)" })

  if opts.keymap then
    vim.keymap.set("n", opts.keymap, function()
      require("nvim-dotnet.rename").rename()
    end, { desc = "DotnetRename", silent = true })
  end
end

return M
