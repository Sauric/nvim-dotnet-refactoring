local M = {}

local TYPE_NODES = {
  class_declaration = true,
  struct_declaration = true,
  interface_declaration = true,
  enum_declaration = true,
  record_declaration = true,
  record_struct_declaration = true,
}

local uv = vim.uv or vim.loop

local function find_type_node_at_cursor()
  local node = vim.treesitter.get_node()
  while node do
    if TYPE_NODES[node:type()] then
      return node
    end
    node = node:parent()
  end
end

local function get_identifier(node)
  for child in node:iter_children() do
    if child:type() == "identifier" then
      return vim.treesitter.get_node_text(child, 0)
    end
  end
end

-- "MyClass.partial.cs" -> "MyClass"
local function file_stem()
  return vim.fn.expand("%:t"):match("^([^.]+)")
end

local function do_rename_file(old_name, new_name)
  local old_path = vim.fn.expand("%:p")
  local dir = vim.fn.fnamemodify(old_path, ":h")
  local filename = vim.fn.expand("%:t")
  local new_filename = filename:gsub("^" .. vim.pesc(old_name), new_name, 1)
  local new_path = dir .. "/" .. new_filename

  local ok = uv.fs_rename(old_path, new_path)
  if not ok then
    vim.notify("[nvim-dotnet] Failed to rename file", vim.log.levels.ERROR)
    return
  end

  local old_bufnr = vim.fn.bufnr(old_path)
  vim.cmd("keepalt edit " .. vim.fn.fnameescape(new_path))
  if old_bufnr ~= -1 and old_bufnr ~= vim.fn.bufnr(new_path) then
    vim.api.nvim_buf_delete(old_bufnr, { force = true })
  end

  vim.notify(string.format("[nvim-dotnet] %s → %s", filename, new_filename))
end

local function apply_rename(new_name, old_name, will_rename_file)
  local client = vim.lsp.get_clients({ bufnr = 0, method = "textDocument/rename" })[1]
  if not client then
    vim.notify("[nvim-dotnet] No LSP client supports rename", vim.log.levels.WARN)
    return
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.newName = new_name

  client.request("textDocument/rename", params, function(err, result)
    if err then
      vim.notify("[nvim-dotnet] Rename failed: " .. (err.message or "unknown"), vim.log.levels.ERROR)
      return
    end
    if result then
      vim.lsp.util.apply_workspace_edit(result, client.offset_encoding)
    end
    if will_rename_file then
      -- defer so buffer writes from workspace edit settle first
      vim.schedule(function()
        do_rename_file(old_name, new_name)
      end)
    end
  end, 0)
end

M.rename = function()
  if vim.bo.filetype ~= "cs" then
    vim.lsp.buf.rename()
    return
  end

  local type_node = find_type_node_at_cursor()
  local old_name = type_node and get_identifier(type_node)
  local stem = file_stem()
  local will_rename_file = old_name ~= nil and old_name == stem
  local default = old_name or vim.fn.expand("<cword>")

  local prompt = will_rename_file
    and string.format("Rename '%s' (+ file): ", default)
    or string.format("Rename '%s': ", default)

  vim.ui.input({ prompt = prompt, default = default }, function(new_name)
    if not new_name or new_name == "" or new_name == default then
      return
    end
    apply_rename(new_name, old_name, will_rename_file)
  end)
end

return M
