local M = {}

local defaults = {
  keymap_rename        = nil,
  keymap_extract       = nil,
  keymap_extract_class = nil,
}

M.setup = function(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts or {})

  vim.api.nvim_create_user_command("DotnetRename", function()
    require("nvim-dotnet-refactoring.rename").rename()
  end, { desc = "Rename C# symbol (renames file too when name matches)" })

  vim.api.nvim_create_user_command("DotnetExtractToPartial", function()
    require("nvim-dotnet-refactoring.extract").extract()
  end, { desc = "Extract C# members to a new partial class file" })

  vim.api.nvim_create_user_command("DotnetExtractClass", function()
    require("nvim-dotnet-refactoring.extract_class").extract_class()
  end, { desc = "Extract C# top-level type(s) to their own file(s)" })

  if opts.keymap_rename then
    vim.keymap.set("n", opts.keymap_rename, function()
      require("nvim-dotnet-refactoring.rename").rename()
    end, { desc = "DotnetRename", silent = true })
  end

  if opts.keymap_extract then
    vim.keymap.set("n", opts.keymap_extract, function()
      require("nvim-dotnet-refactoring.extract").extract()
    end, { desc = "DotnetExtractToPartial", silent = true })
  end

  if opts.keymap_extract_class then
    vim.keymap.set("n", opts.keymap_extract_class, function()
      require("nvim-dotnet-refactoring.extract_class").extract_class()
    end, { desc = "DotnetExtractClass", silent = true })
  end
end

return M
