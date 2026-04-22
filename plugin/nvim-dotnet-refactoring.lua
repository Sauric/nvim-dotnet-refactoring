if vim.g.nvim_dotnet_refactoring_loaded then
  return
end
vim.g.nvim_dotnet_refactoring_loaded = true

require("nvim-dotnet-refactoring").setup()
