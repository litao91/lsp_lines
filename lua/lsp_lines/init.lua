local M = {}

local render = require("lsp_lines.render")

---@private
local function to_severity(severity)
  if type(severity) == "string" then
    return assert(M.severity[string.upper(severity)], string.format("Invalid severity: %s", severity))
  end
  return severity
end

local function filter_by_severity(severity, diagnostics)
  if not severity then
    return diagnostics
  end

  if type(severity) ~= "table" then
    severity = to_severity(severity)
    return vim.tbl_filter(function(t)
      return t.severity == severity
    end, diagnostics)
  end

  local min_severity = to_severity(severity.min) or M.severity.HINT
  local max_severity = to_severity(severity.max) or M.severity.ERROR

  return vim.tbl_filter(function(t)
    return t.severity <= min_severity and t.severity >= max_severity
  end, diagnostics)
end

local function render_current_line(diagnostics, ns, bufnr, opts)
  local current_line_diag = {}
  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1

  for _, diagnostic in pairs(diagnostics) do
    local show = diagnostic.end_lnum and (lnum >= diagnostic.lnum and lnum <= diagnostic.end_lnum)
      or (lnum == diagnostic.lnum)
    if show then
      table.insert(current_line_diag, diagnostic)
    end
  end

  render.show(ns, bufnr, current_line_diag, opts)
end

-- Registers a wrapper-handler to render lsp lines.
-- This should usually only be called once, during initialisation.
M.setup = function()
  vim.api.nvim_create_augroup("LspLines", { clear = true })
  -- TODO: On LSP restart (e.g.: diagnostics cleared), errors don't go away.
  vim.diagnostic.handlers.virtual_lines = {
    ---@param namespace number
    ---@param bufnr number
    ---@param diagnostics table
    ---@param opts boolean
    show = function(namespace, bufnr, diagnostics, opts)
      opts = opts or {}
      local severity
      if opts.virtual_lines then
        if opts.virtual_lines.severity then
          severity = opts.virtual_lines.severity
        end
      end
      if severity then
        diagnostics = filter_by_severity(severity, diagnostics)
      end

      local ns = vim.diagnostic.get_namespace(namespace)
      if not ns.user_data.virt_lines_ns then
        ns.user_data.virt_lines_ns = vim.api.nvim_create_namespace("")
      end

      vim.api.nvim_clear_autocmds({ group = "LspLines" })
      if opts.virtual_lines.only_current_line then
        vim.api.nvim_create_autocmd("CursorMoved", {
          buffer = bufnr,
          callback = function()
            render_current_line(diagnostics, ns.user_data.virt_lines_ns, bufnr, opts)
          end,
          group = "LspLines",
        })
        -- Also show diagnostics for the current line before the first CursorMoved event
        render_current_line(diagnostics, ns.user_data.virt_lines_ns, bufnr, opts)
      else
        render.show(ns.user_data.virt_lines_ns, bufnr, diagnostics, opts)
      end
    end,
    ---@param namespace number
    ---@param bufnr number
    hide = function(namespace, bufnr)
      local ns = vim.diagnostic.get_namespace(namespace)
      if ns.user_data.virt_lines_ns then
        render.hide(ns.user_data.virt_lines_ns, bufnr)
        vim.api.nvim_clear_autocmds({ group = "LspLines" })
      end
    end,
  }
end

local toggle_value = false

---@return boolean
M.toggle = function()
  local new_value = toggle_value
  toggle_value = vim.diagnostic.config().virtual_lines
  vim.diagnostic.config({ virtual_lines = new_value })
  return new_value
end

return M
