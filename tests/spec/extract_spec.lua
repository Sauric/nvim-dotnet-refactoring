local extract = require("nvim-dotnet-refactoring.extract")
local h       = extract._internals

-- ── helpers ──────────────────────────────────────────────────────────────────

local function cs_parser_available()
  return pcall(vim.treesitter.language.add, "c_sharp")
end

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(lines, "\n"))
  vim.bo[buf].filetype = "cs"
  vim.treesitter.get_parser(buf, "c_sharp"):parse()
  return buf
end

local function teardown(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

-- Compact C# class used across many tests.
local BASE_CLASS = table.concat({
  "using System;",
  "using System.Collections.Generic;",
  "",
  "namespace MyApp.Services;",
  "",
  "public class OrderService",
  "{",
  "    private readonly string _name;",
  "    public string Name { get; set; }",
  "    public OrderService(string name) { _name = name; }",
  "    public void DoWork() { Console.WriteLine(_name); }",
  "    public enum Status { Active, Inactive }",
  "}",
}, "\n")

-- ── guard ────────────────────────────────────────────────────────────────────

if not cs_parser_available() then
  pending("c_sharp treesitter parser not installed — skipping extract_spec")
  return
end

-- ── find_member_at_cursor ────────────────────────────────────────────────────

describe("find_member_at_cursor", function()
  it("finds a method member", function()
    local buf = make_buf(BASE_CLASS)
    -- row 10 = "    public void DoWork() { ... }"
    local node = h.find_member_at_cursor(buf, { 10, 20 })
    assert.is_not_nil(node)
    assert.equals("method_declaration", node:type())
    teardown(buf)
  end)

  it("finds a property member", function()
    local buf = make_buf(BASE_CLASS)
    -- row 8 = "    public string Name { get; set; }"
    local node = h.find_member_at_cursor(buf, { 8, 18 })
    assert.is_not_nil(node)
    assert.equals("property_declaration", node:type())
    teardown(buf)
  end)

  it("finds a field member", function()
    local buf = make_buf(BASE_CLASS)
    -- row 7 = "    private readonly string _name;"
    local node = h.find_member_at_cursor(buf, { 7, 28 })
    assert.is_not_nil(node)
    assert.equals("field_declaration", node:type())
    teardown(buf)
  end)

  it("finds a constructor member", function()
    local buf = make_buf(BASE_CLASS)
    -- row 9 = "    public OrderService(string name) { ... }"
    local node = h.find_member_at_cursor(buf, { 9, 15 })
    assert.is_not_nil(node)
    assert.equals("constructor_declaration", node:type())
    teardown(buf)
  end)

  it("finds a nested enum member", function()
    local buf = make_buf(BASE_CLASS)
    -- row 11 = "    public enum Status { Active, Inactive }"
    local node = h.find_member_at_cursor(buf, { 11, 20 })
    assert.is_not_nil(node)
    assert.equals("enum_declaration", node:type())
    teardown(buf)
  end)

  it("returns nil when cursor is on the class declaration line", function()
    local buf = make_buf(BASE_CLASS)
    -- row 5 = "public class OrderService"
    local node = h.find_member_at_cursor(buf, { 5, 14 })
    assert.is_nil(node)
    teardown(buf)
  end)
end)

-- ── find_enclosing_class ─────────────────────────────────────────────────────

describe("find_enclosing_class", function()
  it("finds the class when cursor is inside a method body", function()
    local buf = make_buf(BASE_CLASS)
    local node = h.find_enclosing_class(buf, { 10, 25 })
    assert.is_not_nil(node)
    assert.equals("class_declaration", node:type())
    teardown(buf)
  end)

  it("finds the class when cursor is on the class line itself", function()
    local buf = make_buf(BASE_CLASS)
    local node = h.find_enclosing_class(buf, { 5, 14 })
    assert.is_not_nil(node)
    assert.equals("class_declaration", node:type())
    teardown(buf)
  end)

  it("returns nil when cursor is outside any class", function()
    local buf = make_buf(BASE_CLASS)
    -- row 0 = "using System;"
    local node = h.find_enclosing_class(buf, { 0, 5 })
    assert.is_nil(node)
    teardown(buf)
  end)
end)

-- ── get_all_members ──────────────────────────────────────────────────────────

describe("get_all_members", function()
  it("lists all members with correct names and kinds", function()
    local buf = make_buf(BASE_CLASS)
    local class_node = h.find_enclosing_class(buf, { 10, 0 })
    local members = h.get_all_members(class_node, buf)

    assert.equals(5, #members)

    assert.equals("_name",        members[1].name)
    assert.equals("field",        members[1].kind)
    assert.equals("Name",         members[2].name)
    assert.equals("property",     members[2].kind)
    assert.equals("OrderService", members[3].name)
    assert.equals("constructor",  members[3].kind)
    assert.equals("DoWork",       members[4].name)
    assert.equals("method",       members[4].kind)
    assert.equals("Status",       members[5].name)
    assert.equals("nested enum",  members[5].kind)

    teardown(buf)
  end)

  it("appends () to method and constructor display names", function()
    local buf = make_buf(BASE_CLASS)
    local class_node = h.find_enclosing_class(buf, { 10, 0 })
    local members = h.get_all_members(class_node, buf)

    assert.equals("DoWork()",       members[4].display)
    assert.equals("OrderService()", members[3].display)
    assert.equals("Name",           members[2].display)
    teardown(buf)
  end)
end)

-- ── get_namespace_info ───────────────────────────────────────────────────────

describe("get_namespace_info", function()
  it("detects file-scoped namespace", function()
    local buf = make_buf(BASE_CLASS)
    local ns, is_fs = h.get_namespace_info(buf)
    assert.equals("MyApp.Services", ns)
    assert.is_true(is_fs)
    teardown(buf)
  end)

  it("detects traditional namespace", function()
    local code = "namespace MyApp.Services\n{\n    public class Svc\n    {\n    }\n}"
    local buf  = make_buf(code)
    local ns, is_fs = h.get_namespace_info(buf)
    assert.equals("MyApp.Services", ns)
    assert.is_false(is_fs)
    teardown(buf)
  end)

  it("returns nil when there is no namespace", function()
    local buf = make_buf("public class Bare\n{\n    public void M() {}\n}")
    local ns  = h.get_namespace_info(buf)
    assert.is_nil(ns)
    teardown(buf)
  end)
end)

-- ── get_member_name (field special case) ─────────────────────────────────────

describe("get_member_name", function()
  it("correctly extracts field name from nested AST", function()
    local buf  = make_buf(BASE_CLASS)
    local tree = vim.treesitter.get_parser(buf, "c_sharp"):parse()[1]
    local root = tree:root()
    -- row 7 = the field declaration
    local field_node = root:named_descendant_for_range(7, 4, 7, 4)
    while field_node and field_node:type() ~= "field_declaration" do
      field_node = field_node:parent()
    end
    assert.is_not_nil(field_node)
    assert.equals("_name", h.get_member_name(field_node, buf))
    teardown(buf)
  end)
end)

-- ── build_partial_content ────────────────────────────────────────────────────

describe("build_partial_content", function()
  local function joined(lines) return table.concat(lines, "\n") end

  it("produces a file-scoped partial class with the extracted method", function()
    local buf        = make_buf(BASE_CLASS)
    local class_node = h.find_enclosing_class(buf, { 10, 0 })
    local members    = h.get_all_members(class_node, buf)
    -- extract just DoWork (index 4)
    local content    = joined(h.build_partial_content(class_node, "OrderService", { members[4] }, buf))

    assert.truthy(content:find("using System;", 1, true))
    assert.truthy(content:find("namespace MyApp.Services;", 1, true))
    assert.truthy(content:find("public partial class OrderService", 1, true))
    assert.truthy(content:find("DoWork", 1, true))
    -- must NOT contain the field declaration that wasn't selected
    assert.falsy(content:find("private readonly string _name", 1, true))
    teardown(buf)
  end)

  it("wraps with block namespace when source uses traditional namespace", function()
    local code = "using System;\nnamespace MyApp\n{\n    public class Svc\n    {\n        public void Run() {}\n    }\n}"
    local buf  = make_buf(code)
    local class_node = h.find_enclosing_class(buf, { 5, 0 })
    local members    = h.get_all_members(class_node, buf)
    local content    = joined(h.build_partial_content(class_node, "Svc", members, buf))

    assert.truthy(content:find("namespace MyApp\n{", 1, true))
    assert.truthy(content:find("partial class Svc", 1, true))
    teardown(buf)
  end)

  it("omits namespace wrapper when there is no namespace", function()
    local code = "public class Bare\n{\n    public void M() {}\n}"
    local buf  = make_buf(code)
    local class_node = h.find_enclosing_class(buf, { 2, 0 })
    local members    = h.get_all_members(class_node, buf)
    local content    = joined(h.build_partial_content(class_node, "Bare", members, buf))

    assert.falsy(content:find("namespace", 1, true))
    assert.truthy(content:find("partial class Bare", 1, true))
    teardown(buf)
  end)
end)

-- ── make_class_partial ───────────────────────────────────────────────────────

describe("make_class_partial", function()
  it("inserts 'partial' before the class keyword", function()
    local buf        = make_buf(BASE_CLASS)
    local class_node = h.find_enclosing_class(buf, { 10, 0 })
    h.make_class_partial(buf, class_node)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local class_line = table.concat(lines, "\n"):match("[^\n]*(partial class OrderService)[^\n]*")
    assert.is_not_nil(class_line)
    teardown(buf)
  end)

  it("is idempotent — does not double 'partial'", function()
    local buf        = make_buf(BASE_CLASS)
    local class_node = h.find_enclosing_class(buf, { 10, 0 })
    h.make_class_partial(buf, class_node)
    h.make_class_partial(buf, class_node)
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    -- should appear exactly once
    local _, count = content:gsub("partial class OrderService", "")
    assert.equals(1, count)
    teardown(buf)
  end)
end)

-- ── remove_members ───────────────────────────────────────────────────────────

describe("remove_members", function()
  it("removes selected members from the buffer", function()
    local buf        = make_buf(BASE_CLASS)
    local class_node = h.find_enclosing_class(buf, { 10, 0 })
    local members    = h.get_all_members(class_node, buf)
    -- remove DoWork (index 4)
    h.remove_members(buf, { members[4] })
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.falsy(content:find("DoWork", 1, true))
    -- other members still present
    assert.truthy(content:find("_name", 1, true))
    assert.truthy(content:find("Status", 1, true))
    teardown(buf)
  end)

  it("does not remove members that were not selected", function()
    local buf        = make_buf(BASE_CLASS)
    local class_node = h.find_enclosing_class(buf, { 10, 0 })
    local members    = h.get_all_members(class_node, buf)
    h.remove_members(buf, { members[4] })  -- only DoWork
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.truthy(content:find("Name", 1, true))
    assert.truthy(content:find("Status", 1, true))
    teardown(buf)
  end)

  it("removes multiple members without corrupting line positions", function()
    local buf        = make_buf(BASE_CLASS)
    local class_node = h.find_enclosing_class(buf, { 10, 0 })
    local members    = h.get_all_members(class_node, buf)
    -- remove Name (property, index 2) and DoWork (method, index 4)
    h.remove_members(buf, { members[2], members[4] })
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.falsy(content:find("public string Name", 1, true))
    assert.falsy(content:find("DoWork", 1, true))
    assert.truthy(content:find("_name", 1, true))
    assert.truthy(content:find("Status", 1, true))
    teardown(buf)
  end)
end)
