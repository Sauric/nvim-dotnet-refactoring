local extract_class = require("nvim-dotnet-refactoring.extract_class")
local h             = extract_class._internals
local SK            = h.SK

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

  it("returns false when pos row is before range", function()
    assert.is_false(h.pos_in_range({ 0, 0 }, range(1, 0, 5, 0)))
  end)

  it("returns false when pos row is after range", function()
    assert.is_false(h.pos_in_range({ 6, 0 }, range(1, 0, 5, 0)))
  end)

  it("returns true on the start boundary", function()
    assert.is_true(h.pos_in_range({ 1, 0 }, range(1, 0, 5, 0)))
  end)

  it("returns true on the end boundary", function()
    assert.is_true(h.pos_in_range({ 5, 0 }, range(1, 0, 5, 0)))
  end)
end)

-- ── find_top_level_types ──────────────────────────────────────────────────────

describe("find_top_level_types", function()
  it("returns top-level class, struct, interface, and enum symbols", function()
    local cls   = sym("MyClass",   SK.Class,     0,  0,  5, 1)
    local iface = sym("IFoo",      SK.Interface, 7,  0, 10, 1)
    local enm   = sym("Status",    SK.Enum,      12, 0, 15, 1)
    local st    = sym("Point",     SK.Struct,    17, 0, 20, 1)
    local types = h.find_top_level_types({ cls, iface, enm, st })
    assert.equals(4, #types)
  end)

  it("unwraps types inside a namespace symbol", function()
    local cls = sym("Inner", SK.Class, 2, 0, 5, 1)
    local ns  = { name = "MyApp", kind = SK.Namespace, range = range(0, 0, 10, 0),
                  children = { cls } }
    local types = h.find_top_level_types({ ns })
    assert.equals(1, #types)
    assert.equals("Inner", types[1].name)
  end)

  it("does not include nested types inside a class", function()
    local nested = sym("Inner", SK.Class, 3, 4, 4, 5)
    local outer  = sym("Outer", SK.Class, 0, 0, 6, 1, { nested })
    -- find_top_level_types returns outer but not nested (it only goes one level)
    local types = h.find_top_level_types({ outer })
    assert.equals(1, #types)
    assert.equals("Outer", types[1].name)
  end)

  it("returns empty table when no extractable types are present", function()
    local method = sym("DoWork", SK.Method, 0, 0, 2, 0)
    local types  = h.find_top_level_types({ method })
    assert.equals(0, #types)
  end)

  it("returns empty table for empty symbol list", function()
    assert.equals(0, #h.find_top_level_types({}))
  end)

  it("handles multiple sibling classes", function()
    local c1 = sym("Class1",  SK.Class, 0, 0,  5, 1)
    local c2 = sym("Class2",  SK.Class, 7, 0, 12, 1)
    local c3 = sym("Record1", SK.Class, 14, 0, 18, 1)
    local types = h.find_top_level_types({ c1, c2, c3 })
    assert.equals(3, #types)
  end)
end)

-- ── find_type_by_cursor ───────────────────────────────────────────────────────

describe("find_type_by_cursor", function()
  local c1 = sym("Class1",  SK.Class,  0, 0,  6, 1)
  local c2 = sym("Record1", SK.Class,  8, 0, 14, 1)
  local c3 = sym("Status",  SK.Enum,  16, 0, 20, 1)

  it("returns the type whose range contains the cursor", function()
    local found = h.find_type_by_cursor({ c1, c2, c3 }, { 10, 5 })
    assert.is_not_nil(found)
    assert.equals("Record1", found.name)
  end)

  it("returns nil when cursor is between types", function()
    assert.is_nil(h.find_type_by_cursor({ c1, c2, c3 }, { 7, 0 }))
  end)

  it("returns nil for empty list", function()
    assert.is_nil(h.find_type_by_cursor({}, { 0, 0 }))
  end)

  it("matches start boundary of type range", function()
    local found = h.find_type_by_cursor({ c1 }, { 0, 0 })
    assert.is_not_nil(found)
    assert.equals("Class1", found.name)
  end)

  it("matches end boundary of type range", function()
    local found = h.find_type_by_cursor({ c1 }, { 6, 1 })
    assert.is_not_nil(found)
    assert.equals("Class1", found.name)
  end)
end)

-- ── get_file_context ─────────────────────────────────────────────────────────

describe("get_file_context", function()
  it("extracts usings and file-scoped namespace", function()
    local buf = make_buf("using System;\nusing System.Linq;\n\nnamespace MyApp;\n\npublic class Foo {}")
    local usings, ns, is_fs = h.get_file_context(buf)
    assert.equals(2,                  #usings)
    assert.equals("using System;",    usings[1])
    assert.equals("using System.Linq;", usings[2])
    assert.equals("MyApp",            ns)
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

-- ── infer_type_keyword ────────────────────────────────────────────────────────

describe("infer_type_keyword", function()
  it("returns 'class' for a plain class", function()
    local buf = make_buf("public class MyClass\n{\n}")
    local s   = sym("MyClass", SK.Class, 0, 0, 2, 1)
    assert.equals("class", h.infer_type_keyword(buf, s))
    teardown(buf)
  end)

  it("returns 'struct' for a struct", function()
    local buf = make_buf("public struct Point\n{\n}")
    local s   = sym("Point", SK.Struct, 0, 0, 2, 1)
    assert.equals("struct", h.infer_type_keyword(buf, s))
    teardown(buf)
  end)

  it("returns 'record' for a record (class)", function()
    local buf = make_buf("public record Person(string Name);\n")
    local s   = sym("Person", SK.Class, 0, 0, 0, 30)
    assert.equals("record", h.infer_type_keyword(buf, s))
    teardown(buf)
  end)

  it("returns 'record struct' for a record struct", function()
    local buf = make_buf("public record struct Point(int X, int Y);\n")
    local s   = sym("Point", SK.Struct, 0, 0, 0, 40)
    assert.equals("record struct", h.infer_type_keyword(buf, s))
    teardown(buf)
  end)

  it("returns 'record class' for an explicit record class", function()
    local buf = make_buf("public record class Person(string Name);\n")
    local s   = sym("Person", SK.Class, 0, 0, 0, 40)
    assert.equals("record class", h.infer_type_keyword(buf, s))
    teardown(buf)
  end)

  it("returns 'interface' for an interface", function()
    local buf = make_buf("public interface IFoo\n{\n}")
    local s   = sym("IFoo", SK.Interface, 0, 0, 2, 1)
    assert.equals("interface", h.infer_type_keyword(buf, s))
    teardown(buf)
  end)

  it("returns 'enum' for an enum", function()
    local buf = make_buf("public enum Status { Active, Inactive }")
    local s   = sym("Status", SK.Enum, 0, 0, 0, 40)
    assert.equals("enum", h.infer_type_keyword(buf, s))
    teardown(buf)
  end)

  it("falls back to 'class' when keyword cannot be matched", function()
    -- Unusual but should not crash.
    local buf = make_buf("public abstract MyThing\n{\n}")
    local s   = sym("MyThing", SK.Class, 0, 0, 2, 1)
    assert.equals("class", h.infer_type_keyword(buf, s))
    teardown(buf)
  end)
end)

-- ── remove_types ─────────────────────────────────────────────────────────────

describe("remove_types", function()
  local SOURCE = table.concat({
    "using System;",          -- 0
    "",                       -- 1
    "namespace MyApp;",       -- 2
    "",                       -- 3
    "public class Class1",    -- 4
    "{",                      -- 5
    "    public int X;",      -- 6
    "}",                      -- 7
    "",                       -- 8
    "public class Record1",   -- 9
    "{",                      -- 10
    "    public int Y;",      -- 11
    "}",                      -- 12
    "",                       -- 13
    "public class Class2",    -- 14
    "{",                      -- 15
    "}",                      -- 16
  }, "\n")

  it("removes a single type block", function()
    local buf   = make_buf(SOURCE)
    local types = { sym("Record1", SK.Class, 9, 0, 12, 1) }
    h.remove_types(buf, types)
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.falsy (content:find("Record1", 1, true))
    assert.truthy(content:find("Class1",  1, true))
    assert.truthy(content:find("Class2",  1, true))
    teardown(buf)
  end)

  it("removes multiple types without line-shift corruption", function()
    local buf   = make_buf(SOURCE)
    local types = {
      sym("Class1",  SK.Class, 4,  0,  7, 1),
      sym("Class2",  SK.Class, 14, 0, 16, 1),
    }
    h.remove_types(buf, types)
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.falsy (content:find("Class1", 1, true))
    assert.falsy (content:find("Class2", 1, true))
    assert.truthy(content:find("Record1", 1, true))
    teardown(buf)
  end)

  it("eats blank lines that follow a removed type", function()
    local buf   = make_buf(SOURCE)
    local types = { sym("Class1", SK.Class, 4, 0, 7, 1) }
    h.remove_types(buf, types)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- No consecutive blank lines should exist in the result.
    local has_double_blank = false
    for i = 1, #lines - 1 do
      if lines[i]:match("^%s*$") and lines[i + 1]:match("^%s*$") then
        has_double_blank = true
      end
    end
    assert.is_false(has_double_blank)
    teardown(buf)
  end)

  it("handles removing all types from the buffer", function()
    local simple = table.concat({
      "public class A\n{\n}\n\npublic class B\n{\n}",
    }, "\n")
    local buf   = make_buf(simple)
    local types = {
      sym("A", SK.Class, 0, 0, 2, 1),
      sym("B", SK.Class, 4, 0, 6, 1),
    }
    h.remove_types(buf, types)
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.falsy(content:find("class A", 1, true))
    assert.falsy(content:find("class B", 1, true))
    teardown(buf)
  end)
end)

-- ── build_type_file_content ───────────────────────────────────────────────────

describe("build_type_file_content", function()
  local function joined(lines) return table.concat(lines, "\n") end

  it("produces file-scoped namespace with usings", function()
    local code = table.concat({
      "using System;",
      "using System.Linq;",
      "",
      "namespace MyApp;",
      "",
      "public class Class1",
      "{",
      "    public int X;",
      "}",
      "",
      "public record Record1(string Name);",
    }, "\n")
    local buf = make_buf(code)
    -- Extract Record1 (line 10)
    local type_sym = sym("Record1", SK.Class, 10, 0, 10, 35)
    local content  = h.build_type_file_content(buf, type_sym)
    local text     = joined(content)

    assert.truthy(text:find("using System;",      1, true))
    assert.truthy(text:find("using System.Linq;", 1, true))
    assert.truthy(text:find("namespace MyApp;",   1, true))
    assert.truthy(text:find("Record1",             1, true))
    -- Should NOT contain Class1
    assert.falsy (text:find("Class1",              1, true))
    teardown(buf)
  end)

  it("produces block namespace when namespace is not file-scoped", function()
    local code = table.concat({
      "namespace MyApp",
      "{",
      "    public class Class1",
      "    {",
      "    }",
      "",
      "    public class Class2",
      "    {",
      "    }",
      "}",
    }, "\n")
    local buf      = make_buf(code)
    local type_sym = sym("Class2", SK.Class, 6, 4, 8, 5)
    local content  = h.build_type_file_content(buf, type_sym)
    local text     = joined(content)

    assert.truthy(text:find("namespace MyApp\n{", 1, true))
    assert.truthy(text:find("Class2", 1, true))
    assert.falsy (text:find("Class1", 1, true))
    teardown(buf)
  end)

  it("produces content with no namespace when none exists", function()
    local code = "public class Bare\n{\n}"
    local buf  = make_buf(code)
    local s    = sym("Bare", SK.Class, 0, 0, 2, 1)
    local content = h.build_type_file_content(buf, s)
    local text    = joined(content)
    assert.truthy(text:find("public class Bare", 1, true))
    assert.falsy (text:find("namespace",         1, true))
    teardown(buf)
  end)

  it("ends with a trailing newline (last element is empty string)", function()
    local buf  = make_buf("public class Foo\n{\n}")
    local s    = sym("Foo", SK.Class, 0, 0, 2, 1)
    local content = h.build_type_file_content(buf, s)
    assert.equals("", content[#content])
    teardown(buf)
  end)

  it("preserves indented member lines inside the extracted type", function()
    local code = table.concat({
      "namespace N;",
      "",
      "public class MyClass",
      "{",
      "    public int X { get; set; }",
      "    public void Foo() {}",
      "}",
    }, "\n")
    local buf = make_buf(code)
    local s   = sym("MyClass", SK.Class, 2, 0, 6, 1, {
      sym("X",   SK.Property, 4, 4, 4, 32),
      sym("Foo", SK.Method,   5, 4, 5, 24),
    })
    local content = h.build_type_file_content(buf, s)
    local text    = joined(content)
    assert.truthy(text:find("public int X { get; set; }", 1, true))
    assert.truthy(text:find("public void Foo() {}",       1, true))
    teardown(buf)
  end)
end)

-- ── symbol_to_type ────────────────────────────────────────────────────────────

describe("symbol_to_type", function()
  it("returns name and kind for a class", function()
    local buf = make_buf("public class MyClass\n{\n}")
    local s   = sym("MyClass", SK.Class, 0, 0, 2, 1)
    local t   = h.symbol_to_type(s, buf)
    assert.equals("MyClass", t.name)
    assert.equals("MyClass", t.display)
    assert.equals("class",   t.kind)
    teardown(buf)
  end)

  it("returns kind 'struct' for SK.Struct", function()
    local buf = make_buf("public struct Point\n{\n}")
    local s   = sym("Point", SK.Struct, 0, 0, 2, 1)
    local t   = h.symbol_to_type(s, buf)
    assert.equals("struct", t.kind)
    teardown(buf)
  end)

  it("returns kind 'interface' for SK.Interface", function()
    local buf = make_buf("public interface IFoo\n{\n}")
    local s   = sym("IFoo", SK.Interface, 0, 0, 2, 1)
    local t   = h.symbol_to_type(s, buf)
    assert.equals("interface", t.kind)
    teardown(buf)
  end)

  it("returns kind 'enum' for SK.Enum", function()
    local buf = make_buf("public enum Status { A, B }")
    local s   = sym("Status", SK.Enum, 0, 0, 0, 26)
    local t   = h.symbol_to_type(s, buf)
    assert.equals("enum", t.kind)
    teardown(buf)
  end)

  it("sets kw to 'record struct' for a record struct", function()
    local buf = make_buf("public record struct Point(int X);\n")
    local s   = sym("Point", SK.Struct, 0, 0, 0, 33)
    local t   = h.symbol_to_type(s, buf)
    assert.equals("record struct", t.kw)
    teardown(buf)
  end)

  it("stores the original LSP symbol in t.symbol", function()
    local buf = make_buf("public class Foo {}")
    local s   = sym("Foo", SK.Class, 0, 0, 0, 19)
    local t   = h.symbol_to_type(s, buf)
    assert.equals(s, t.symbol)
    teardown(buf)
  end)
end)
