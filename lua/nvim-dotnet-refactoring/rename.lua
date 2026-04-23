local M = {}

local SK = vim.lsp.protocol.SymbolKind

local TYPE_KINDS = {
  [SK.Class]     = true,
  [SK.Struct]    = true,
  [SK.Interface] = true,
  [SK.Enum]      = true,
}

local uv = vim.uv or vim.loop

-- ── LSP fetch ────────────────────────────────────────────────────────────────

local function get_document_symbols(bufnr, timeout_ms)
  local params  = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local results = vim.lsp.buf_request_sync(
    bufnr, "textDocument/documentSymbol", params, timeout_ms or 2000
  )
  if not results then return nil end
  for _, resp in pairs(results) do
    if resp.result and #resp.result > 0 then return resp.result end
  end
  return nil
end

-- ── range helper ─────────────────────────────────────────────────────────────

local function pos_in_range(pos, range)
  local sl, sc = range.start.line, range.start.character
  local el, ec = range["end"].line, range["end"].character
  local row, col = pos[1], pos[2]
  if row < sl or row > el then return false end
  if row == sl and col < sc then return false end
  if row == el and col > ec then return false end
  return true
end

-- ── type symbol finder ───────────────────────────────────────────────────────

-- Returns the type symbol whose selectionRange contains pos (0-indexed).
-- Using selectionRange (name token only) means the match fires only when the
-- cursor is on the type name itself — never inside a method body.
local function find_type_by_cursor(symbols, pos)
  for _, sym in ipairs(symbols) do
    if sym.children then
      local found = find_type_by_cursor(sym.children, pos)
      if found then return found end
    end
    if TYPE_KINDS[sym.kind] and pos_in_range(pos, sym.selectionRange) then
      return sym
    end
  end
end

-- ── file helpers ─────────────────────────────────────────────────────────────

-- "MyClass.partial.cs" -> "MyClass"
local function file_stem(filename)
  return (filename or vim.fn.expand("%:t")):match("^([^.]+)")
end

local function do_rename_file(old_name, new_name)
  local old_path = vim.fn.expand("%:p")
  local dir      = vim.fn.fnamemodify(old_path, ":h")
  local filename = vim.fn.expand("%:t")
  local new_filename = filename:gsub("^" .. vim.pesc(old_name), new_name, 1)
  local new_path     = dir .. "/" .. new_filename

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

-- ── LSP rename ───────────────────────────────────────────────────────────────

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
      vim.schedule(function() do_rename_file(old_name, new_name) end)
    end
  end, 0)
end

-- ── public API ───────────────────────────────────────────────────────────────

M.rename = function()
  if vim.bo.filetype ~= "cs" then
    vim.lsp.buf.rename()
    return
  end

  local bufnr  = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local pos    = { cursor[1] - 1, cursor[2] }

  local symbols  = get_document_symbols(bufnr)
  local type_sym = symbols and find_type_by_cursor(symbols, pos)
  local old_name = type_sym and type_sym.name
  local stem     = file_stem()
  local will_rename_file = old_name ~= nil and old_name == stem

  local default = old_name or vim.fn.expand("<cword>")
  local prompt  = will_rename_file
    and string.format("Rename '%s' (+ file): ", default)
    or  string.format("Rename '%s': ", default)

  vim.ui.input({ prompt = prompt, default = default }, function(new_name)
    if not new_name or new_name == "" or new_name == default then return end
    apply_rename(new_name, old_name, will_rename_file)
  end)
end

M._internals = {
  file_stem           = file_stem,
  do_rename_file      = do_rename_file,
  find_type_by_cursor = find_type_by_cursor,
  pos_in_range        = pos_in_range,
}

return M
