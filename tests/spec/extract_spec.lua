local extract = require("nvim-dotnet-refactoring.extract")
local h       = extract._internals
local SK      = h.SK

-- ── mock helpers ─────────────────────────────────────────────────────────────

local function range(sl, sc, el, ec)
  return { start = { line = sl, character = sc }, ["end"] = { line = el, character = ec } }
end

local function sym(name, kind, sl, sc, el, ec, children)
  return { name = name, kind = kind, range = range(sl, sc, el, ec),
           selectionRange = range(sl, sc, sl, sc + #name), children = children or {} }
end

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(lines, "\n"))
  return buf
end

local function teardown(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

-- ── pos_in_range ─────────────────────────────────────────────────────────────

describe("pos_in_range", function()
  it("returns true when pos is inside the range", function()
    assert.is_true(h.pos_in_range({ 2, 10 }, range(1, 0, 5, 0)))
  end)

  it("returns true when pos is on the start boundary", function()
    assert.is_true(h.pos_in_range({ 1, 0 }, range(1, 0, 5, 0)))
  end)

  it("returns true when pos is on the end boundary", function()
    assert.is_true(h.pos_in_range({ 5, 0 }, range(1, 0, 5, 0)))
  end)

  it("returns false when pos row is before range", function()
    assert.is_false(h.pos_in_range({ 0, 0 }, range(1, 0, 5, 0)))
  end)

  it("returns false when pos row is after range", function()
    assert.is_false(h.pos_in_range({ 6, 0 }, range(1, 0, 5, 0)))
  end)

  it("returns false when pos col is before start on the start line", function()
    assert.is_false(h.pos_in_range({ 1, 0 }, range(1, 4, 5, 0)))
  end)

  it("returns false when pos col is after end on the end line", function()
    assert.is_false(h.pos_in_range({ 5, 10 }, range(1, 0, 5, 5)))
  end)
end)

-- ── find_class_by_cursor ─────────────────────────────────────────────────────

describe("find_class_by_cursor", function()
  local method  = sym("DoWork",       SK.Method,   3, 4, 5, 5)
  local prop    = sym("Name",         SK.Property, 6, 4, 6, 40)
  local cls     = sym("OrderService", SK.Class,    2, 0, 10, 1, { method, prop })
  local symbols = { cls }

  it("finds the class when cursor is inside it", function()
    local found = h.find_class_by_cursor(symbols, { 4, 10 })
    assert.is_not_nil(found)
    assert.equals("OrderService", found.name)
  end)

  it("returns nil when cursor is outside all classes", function()
    assert.is_nil(h.find_class_by_cursor(symbols, { 0, 0 }))
  end)

  it("finds a nested class when symbols are wrapped in a namespace symbol", function()
    local inner   = sym("Inner", SK.Class, 4, 4, 8, 5, {})
    local outer   = sym("Outer", SK.Class, 2, 0, 10, 1, { inner })
    local found   = h.find_class_by_cursor({ outer }, { 5, 10 })
    assert.equals("Inner", found.name)
  end)
end)

-- ── find_member_by_cursor ────────────────────────────────────────────────────

describe("find_member_by_cursor", function()
  local method = sym("DoWork", SK.Method,   5, 4, 7, 5)
  local prop   = sym("Name",   SK.Property, 9, 4, 9, 40)
  local cls    = sym("Svc",    SK.Class,    2, 0, 12, 1, { method, prop })

  it("returns the member whose range contains the cursor", function()
    local found = h.find_member_by_cursor(cls, { 6, 10 })
    assert.is_not_nil(found)
    assert.equals("DoWork", found.name)
  end)

  it("returns nil when cursor is on the class declaration line", function()
    assert.is_nil(h.find_member_by_cursor(cls, { 2, 10 }))
  end)

  it("returns nil when cursor is between members", function()
    assert.is_nil(h.find_member_by_cursor(cls, { 8, 0 }))
  end)

  it("returns the symbol by reference so m.symbol == cursor_sym works", function()
    -- Roslyn full-signature names differ from stripped m.name, so identity
    -- comparison (m.symbol == cursor_sym) must be used, not name comparison.
    local prop_full = sym("Name : string", SK.Property, 9, 4, 9, 40)
    local cls2      = sym("Svc", SK.Class, 2, 0, 12, 1, { method, prop_full })
    local found     = h.find_member_by_cursor(cls2, { 9, 10 })
    assert.is_not_nil(found)
    -- same table reference
    assert.equals(prop_full, found)
  end)
end)

-- ── symbol_to_member ─────────────────────────────────────────────────────────

describe("symbol_to_member", function()
  it("uses sym.name as display", function()
    local m = h.symbol_to_member(sym("DoWork", SK.Method, 0, 0, 2, 0))
    assert.equals("DoWork", m.display)
    assert.equals("DoWork", m.name)
    assert.equals("method", m.kind)
  end)

  it("strips Roslyn full signature from name but keeps it in display", function()
    -- Roslyn returns e.g. "Multiply(int, int) : int" as sym.name
    local m = h.symbol_to_member(sym("Multiply(int, int) : int", SK.Method, 0, 0, 2, 0))
    assert.equals("Multiply",                 m.name)
    assert.equals("Multiply(int, int) : int", m.display)
  end)

  it("strips Roslyn constructor signature", function()
    local m = h.symbol_to_member(sym("MyClass(string name)", SK.Constructor, 0, 0, 2, 0))
    assert.equals("MyClass", m.name)
  end)

  it("leaves plain names (no parens) unchanged", function()
    local m = h.symbol_to_member(sym("Name", SK.Property, 0, 0, 0, 30))
    assert.equals("Name",     m.name)
    assert.equals("Name",     m.display)
    assert.equals("property", m.kind)
  end)

  it("handles field names correctly", function()
    local m = h.symbol_to_member(sym("_count", SK.Field, 0, 0, 0, 30))
    assert.equals("_count", m.name)
    assert.equals("field",  m.kind)
  end)

  it("labels nested enum correctly", function()
    local m = h.symbol_to_member(sym("Status", SK.Enum, 0, 0, 2, 1))
    assert.equals("nested enum", m.kind)
  end)
end)

-- ── get_file_context ─────────────────────────────────────────────────────────

describe("get_file_context", function()
  it("extracts usings and file-scoped namespace", function()
    local buf = make_buf("using System;\nusing System.Linq;\n\nnamespace MyApp.Services;\n\npublic class Foo {}")
    local usings, ns, is_fs = h.get_file_context(buf)
    assert.equals(2, #usings)
    assert.equals("using System;",       usings[1])
    assert.equals("using System.Linq;",  usings[2])
    assert.equals("MyApp.Services",      ns)
    assert.is_true(is_fs)
    teardown(buf)
  end)

  it("detects traditional (block) namespace", function()
    local buf = make_buf("namespace MyApp\n{\n    public class Foo {}\n}")
    local _, ns, is_fs = h.get_file_context(buf)
    assert.equals("MyApp", ns)
    assert.is_false(is_fs)
    teardown(buf)
  end)

  it("returns nil namespace and empty usings when neither exist", function()
    local buf = make_buf("public class Bare {}")
    local usings, ns = h.get_file_context(buf)
    assert.equals(0, #usings)
    assert.is_nil(ns)
    teardown(buf)
  end)
end)

-- ── make_class_partial ───────────────────────────────────────────────────────

describe("make_class_partial", function()
  it("inserts 'partial' before 'class'", function()
    local buf      = make_buf("using System;\n\npublic class OrderService\n{\n}")
    local class_sym = sym("OrderService", SK.Class, 2, 0, 4, 1)
    h.make_class_partial(buf, class_sym)
    local lines = vim.api.nvim_buf_get_lines(buf, 2, 3, false)
    assert.truthy(lines[1]:find("partial class OrderService", 1, true))
    teardown(buf)
  end)

  it("is idempotent", function()
    local buf      = make_buf("public class Svc\n{\n}")
    local class_sym = sym("Svc", SK.Class, 0, 0, 2, 1)
    h.make_class_partial(buf, class_sym)
    h.make_class_partial(buf, class_sym)
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    local _, count = line:gsub("partial", "")
    assert.equals(1, count)
    teardown(buf)
  end)

  it("works for struct", function()
    local buf      = make_buf("public struct Point\n{\n}")
    local class_sym = sym("Point", SK.Struct, 0, 0, 2, 1)
    h.make_class_partial(buf, class_sym)
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.truthy(line:find("partial struct Point", 1, true))
    teardown(buf)
  end)
end)

-- ── remove_members ───────────────────────────────────────────────────────────

describe("remove_members", function()
  -- 10-line buffer matching the line numbers used in the member symbols
  local SOURCE = table.concat({
    "using System;",             -- 0
    "",                          -- 1
    "namespace MyApp;",          -- 2
    "",                          -- 3
    "public class OrderService", -- 4
    "{",                         -- 5
    "    private string _name;", -- 6
    "    public string Name { get; set; }",   -- 7
    "    public void DoWork() {}",            -- 8
    "}",                         -- 9
  }, "\n")

  local function make_member(name, kind, sl, el)
    local s = sym(name, kind, sl, 4, el, 4)
    return { symbol = s, name = name, display = name, kind = h.KIND_LABEL[kind] or "member" }
  end

  it("removes the selected member", function()
    local buf     = make_buf(SOURCE)
    local members = { make_member("DoWork", SK.Method, 8, 8) }
    h.remove_members(buf, members)
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.falsy(content:find("DoWork", 1, true))
    assert.truthy(content:find("_name", 1, true))
    teardown(buf)
  end)

  it("removes multiple members without corrupting positions", function()
    local buf = make_buf(SOURCE)
    local members = {
      make_member("_name",  SK.Field,    6, 6),
      make_member("DoWork", SK.Method,   8, 8),
    }
    h.remove_members(buf, members)
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.falsy(content:find("DoWork",  1, true))
    assert.falsy(content:find("_name",   1, true))
    assert.truthy(content:find("Name",   1, true))
    teardown(buf)
  end)

  it("leaves unselected members intact", function()
    local buf     = make_buf(SOURCE)
    local members = { make_member("DoWork", SK.Method, 8, 8) }
    h.remove_members(buf, members)
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.truthy(content:find("_name", 1, true))
    assert.truthy(content:find("Name",  1, true))
    teardown(buf)
  end)
end)

-- ── build_partial_content ────────────────────────────────────────────────────

describe("build_partial_content", function()
  local function joined(lines) return table.concat(lines, "\n") end

  local SOURCE = table.concat({
    "using System;",
    "using System.Linq;",
    "",
    "namespace MyApp.Services;",
    "",
    "public class OrderService",
    "{",
    "    private string _name;",
    "    public void DoWork() {}",
    "}",
  }, "\n")

  it("produces file-scoped partial with usings, namespace, and member", function()
    local buf       = make_buf(SOURCE)
    local class_sym = sym("OrderService", SK.Class, 5, 0, 9, 1, {
      sym("_name",  SK.Field,  7, 4, 7, 30),
      sym("DoWork", SK.Method, 8, 4, 8, 30),
    })
    local dowork_m = { symbol = class_sym.children[2], name = "DoWork",
                       display = "DoWork()", kind = "method" }
    local content  = joined(h.build_partial_content(class_sym, "OrderService", { dowork_m }, buf))

    assert.truthy(content:find("using System;",                  1, true))
    assert.truthy(content:find("namespace MyApp.Services;",      1, true))
    assert.truthy(content:find("public partial class OrderService", 1, true))
    assert.truthy(content:find("DoWork",                         1, true))
    assert.falsy (content:find("private string _name",           1, true))
    teardown(buf)
  end)

  it("wraps in block namespace when source uses traditional style", function()
    local code = "using System;\nnamespace MyApp\n{\n    public class Svc\n    {\n        public void Run() {}\n    }\n}"
    local buf  = make_buf(code)
    local class_sym = sym("Svc", SK.Class, 3, 4, 7, 5, {
      sym("Run", SK.Method, 5, 8, 5, 30),
    })
    local run_m  = { symbol = class_sym.children[1], name = "Run",
                     display = "Run()", kind = "method" }
    local content = joined(h.build_partial_content(class_sym, "Svc", { run_m }, buf))

    assert.truthy(content:find("namespace MyApp\n{", 1, true))
    assert.truthy(content:find("partial class Svc",  1, true))
    teardown(buf)
  end)

  it("omits namespace when there is none", function()
    local code = "public class Bare\n{\n    public void M() {}\n}"
    local buf  = make_buf(code)
    local class_sym = sym("Bare", SK.Class, 0, 0, 3, 1, {
      sym("M", SK.Method, 2, 4, 2, 25),
    })
    local m_m  = { symbol = class_sym.children[1], name = "M",
                   display = "M()", kind = "method" }
    local content = joined(h.build_partial_content(class_sym, "Bare", { m_m }, buf))

    assert.falsy (content:find("namespace", 1, true))
    assert.truthy(content:find("partial class Bare", 1, true))
    teardown(buf)
  end)
end)
