if vim.g.nvim_dotnet_loaded then
  return
end
vim.g.nvim_dotnet_loaded = true

-- auto-setup with defaults; call require("nvim-dotnet").setup(opts) to override
require("nvim-dotnet").setup()
