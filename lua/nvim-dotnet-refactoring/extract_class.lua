local M = {}

-- ── LSP symbol kinds ─────────────────────────────────────────────────────────

local SK = vim.lsp.protocol.SymbolKind

-- Types that can be extracted to their own file.
local TYPE_KINDS = {
  [SK.Class]     = "class",
  [SK.Struct]    = "struct",
  [SK.Interface] = "interface",
  [SK.Enum]      = "enum",
}

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

-- ── range helpers (pure — no side effects, easy to test) ─────────────────────

-- LSP ranges are 0-indexed {start={line,character}, end={line,character}}.
local function pos_in_range(pos, range)
  local sl, sc = range.start.line, range.start.character
  local el, ec = range["end"].line, range["end"].character
  local row, col = pos[1], pos[2]
  if row < sl or row > el then return false end
  if row == sl and col < sc then return false end
  if row == el and col > ec then return false end
  return true
end

-- Returns the top-level (direct children of the symbol list, or inside a
-- namespace symbol) type symbols that are extractable.
-- We only extract top-level types — not types nested inside another class.
local function find_top_level_types(symbols)
  local types = {}
  for _, sym in ipairs(symbols) do
    if TYPE_KINDS[sym.kind] then
      types[#types + 1] = sym
    elseif sym.kind == SK.Namespace then
      -- Namespace symbols wrap the top-level types; recurse one level.
      for _, child in ipairs(sym.children or {}) do
        if TYPE_KINDS[child.kind] then
          types[#types + 1] = child
        end
      end
    end
  end
  return types
end

-- Returns the top-level type symbol whose range contains pos, or nil.
local function find_type_by_cursor(types, pos)
  for _, sym in ipairs(types) do
    if pos_in_range(pos, sym.range) then return sym end
  end
end

-- ── file context (buffer line scan — no Treesitter needed) ───────────────────

-- Returns usings (list of strings), namespace (string|nil), is_file_scoped (bool).
local function get_file_context(bufnr)
  local lines                             = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local usings, namespace, is_file_scoped = {}, nil, false
  for _, line in ipairs(lines) do
    if line:match("^using ") then
      usings[#usings + 1] = line
    elseif line:match("^namespace ") then
      namespace      = line:match("^namespace%s+([%w%.]+)")
      is_file_scoped = line:match(";%s*$") ~= nil
    end
  end
  return usings, namespace, is_file_scoped
end

-- ── keyword inference ────────────────────────────────────────────────────────

-- Infer the C# keyword(s) from the declaration line of a type symbol.
-- Returns e.g. "record struct", "record", "struct", "class", "interface", "enum".
local function infer_type_keyword(bufnr, sym)
  local row  = sym.range.start.line
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return line:match("%f[%w](record%s+struct)%f[%W]")
      or line:match("%f[%w](record%s+class)%f[%W]")
      or line:match("%f[%w](record)%f[%W]")
      or line:match("%f[%w](interface)%f[%W]")
      or line:match("%f[%w](enum)%f[%W]")
      or line:match("%f[%w](struct)%f[%W]")
      or "class"
end

-- ── type removal from buffer ─────────────────────────────────────────────────

-- Removes the given type symbols from the buffer.
-- Sorts bottom-to-top so earlier line numbers stay valid after each deletion.
-- Also eats any blank lines immediately after each removed block.
local function remove_types(bufnr, type_syms)
  local sorted = vim.tbl_map(function(s) return s end, type_syms)
  table.sort(sorted, function(a, b)
    return a.range.start.line > b.range.start.line
  end)
  local total = vim.api.nvim_buf_line_count(bufnr)
  for _, sym in ipairs(sorted) do
    local sr      = sym.range.start.line
    local er      = sym.range["end"].line
    local end_row = er + 1
    -- Also consume trailing blank lines after the type block.
    while end_row < total do
      local nxt = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1]
      if nxt and nxt:match("^%s*$") then end_row = end_row + 1 else break end
    end
    vim.api.nvim_buf_set_lines(bufnr, sr, end_row, false, {})
    total = total - (end_row - sr)
  end
end

-- ── new file content builder ─────────────────────────────────────────────────

-- Builds the lines for a new standalone .cs file containing `type_sym`.
local function build_type_file_content(bufnr, type_sym)
  local usings, ns, is_file_scoped = get_file_context(bufnr)

  local sr = type_sym.range.start.line
  local er = type_sym.range["end"].line
  local type_lines = vim.api.nvim_buf_get_lines(bufnr, sr, er + 1, false)

  local out = {}
  for _, u in ipairs(usings) do out[#out + 1] = u end
  if #usings > 0 then out[#out + 1] = "" end

  if ns then
    if is_file_scoped then
      out[#out + 1] = "namespace " .. ns .. ";"
      out[#out + 1] = ""
      for _, l in ipairs(type_lines) do out[#out + 1] = l end
    else
      out[#out + 1] = "namespace " .. ns
      out[#out + 1] = "{"
      for _, l in ipairs(type_lines) do out[#out + 1] = l end
      out[#out + 1] = "}"
    end
  else
    for _, l in ipairs(type_lines) do out[#out + 1] = l end
  end

  out[#out + 1] = ""
  return out
end

-- ── symbol → display struct ──────────────────────────────────────────────────

local function symbol_to_type(sym, bufnr)
  local kw   = infer_type_keyword(bufnr, sym)
  local kind = TYPE_KINDS[sym.kind] or kw
  return { symbol = sym, name = sym.name, display = sym.name, kind = kind, kw = kw }
end

-- ── dialog ───────────────────────────────────────────────────────────────────

local function show_dialog(types, cursor_idx, dir, bufnr, on_confirm)
  local selected = {}
  selected[cursor_idx or 1] = true
  local current = cursor_idx or 1
  local HEADER  = 2

  local function build_lines()
    local lines = { "  Extract type(s) to own file(s)", "" }
    for i, t in ipairs(types) do
      local check = selected[i] and "[x]" or "[ ]"
      lines[#lines + 1] = string.format("  %s  %-36s %s", check, t.display, t.kind)
    end
    lines[#lines + 1] = ""
    -- Show a preview of which files will be created.
    local previews = {}
    for i, t in ipairs(types) do
      if selected[i] then previews[#previews + 1] = t.name .. ".cs" end
    end
    if #previews > 0 then
      lines[#lines + 1] = "  Will create: " .. table.concat(previews, ", ")
    else
      lines[#lines + 1] = "  (no types selected)"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Space toggle · Enter confirm · Esc cancel"
    return lines
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  local ui     = vim.api.nvim_list_uis()[1]
  local width  = 65
  local height = #types + 7
  local win    = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = math.max(0, math.floor((ui.height - height) / 2)),
    col       = math.max(0, math.floor((ui.width - width) / 2)),
    width     = width,
    height    = height,
    style     = "minimal",
    border    = "rounded",
    title     = " Extract class ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true

  local function refresh()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_lines())
    vim.bo[buf].modifiable = false
    pcall(vim.api.nvim_win_set_cursor, win, { HEADER + current, 0 })
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  local o = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "<Esc>",   close, o)
  vim.keymap.set("n", "q",       close, o)
  vim.keymap.set("n", "j",       function() if current < #types then current = current + 1; refresh() end end, o)
  vim.keymap.set("n", "<Down>",  function() if current < #types then current = current + 1; refresh() end end, o)
  vim.keymap.set("n", "k",       function() if current > 1 then current = current - 1; refresh() end end, o)
  vim.keymap.set("n", "<Up>",    function() if current > 1 then current = current - 1; refresh() end end, o)

  vim.keymap.set("n", "<Space>", function()
    selected[current] = not selected[current]
    refresh()
  end, o)

  vim.keymap.set("n", "<CR>", function()
    local sel = {}
    for i, t in ipairs(types) do
      if selected[i] then sel[#sel + 1] = t end
    end
    if #sel == 0 then
      vim.notify("[nvim-dotnet] Select at least one type", vim.log.levels.WARN)
      return
    end
    close()
    on_confirm(sel, dir)
  end, o)

  refresh()
end

-- ── extraction logic ─────────────────────────────────────────────────────────

local function do_extract(bufnr, sel, dir)
  -- Check for conflicts first (before touching anything).
  local conflicts = {}
  for _, t in ipairs(sel) do
    local path = dir .. "/" .. t.name .. ".cs"
    if vim.fn.filereadable(path) == 1 then
      conflicts[#conflicts + 1] = { type = t, path = path }
    end
  end

  local function perform()
    -- Write files in original top-to-bottom order so content is read before removal.
    for _, t in ipairs(sel) do
      local content = build_type_file_content(bufnr, t.symbol)
      local path    = dir .. "/" .. t.name .. ".cs"
      vim.fn.writefile(content, path)
    end
    -- Remove extracted types from the original buffer (bottom-to-top internally).
    local syms = vim.tbl_map(function(t) return t.symbol end, sel)
    remove_types(bufnr, syms)
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("write") end)
    local names = vim.tbl_map(function(t) return t.name .. ".cs" end, sel)
    vim.notify(string.format("[nvim-dotnet] Extracted %d type(s) → %s",
      #sel, table.concat(names, ", ")))
  end

  if #conflicts > 0 then
    local conflict_names = vim.tbl_map(function(c) return c.type.name .. ".cs" end, conflicts)
    vim.ui.select({ "Overwrite", "Cancel" },
      { prompt = "Already exist: " .. table.concat(conflict_names, ", ") },
      function(choice)
        if choice == "Overwrite" then perform() end
      end)
  else
    perform()
  end
end

-- ── public API ───────────────────────────────────────────────────────────────

M.extract_class = function()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "cs" then
    vim.notify("[nvim-dotnet] Only works in C# files", vim.log.levels.WARN)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local pos    = { cursor[1] - 1, cursor[2] }

  local symbols = get_document_symbols(bufnr)
  if not symbols then
    vim.notify("[nvim-dotnet] LSP not ready — no document symbols", vim.log.levels.WARN)
    return
  end

  local top_types = find_top_level_types(symbols)
  if #top_types == 0 then
    vim.notify("[nvim-dotnet] No extractable top-level types found", vim.log.levels.WARN)
    return
  end

  -- Convert to display structs (needs bufnr to infer keyword).
  local types = vim.tbl_map(function(s) return symbol_to_type(s, bufnr) end, top_types)

  -- Pre-select the type the cursor is currently in.
  local cursor_sym = find_type_by_cursor(top_types, pos)
  local cursor_idx = 1
  if cursor_sym then
    for i, t in ipairs(types) do
      if t.symbol == cursor_sym then cursor_idx = i; break end
    end
  end

  local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h")

  show_dialog(types, cursor_idx, dir, bufnr, function(sel, d)
    do_extract(bufnr, sel, d)
  end)
end

M._internals = {
  pos_in_range           = pos_in_range,
  find_top_level_types   = find_top_level_types,
  find_type_by_cursor    = find_type_by_cursor,
  get_file_context       = get_file_context,
  infer_type_keyword     = infer_type_keyword,
  remove_types           = remove_types,
  build_type_file_content = build_type_file_content,
  symbol_to_type         = symbol_to_type,
  TYPE_KINDS             = TYPE_KINDS,
  SK                     = SK,
}

return M
