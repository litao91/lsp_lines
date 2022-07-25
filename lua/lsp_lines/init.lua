local M = {}

local highlight_groups = {
  [vim.diagnostic.severity.ERROR] = "DiagnosticVirtualTextError",
  [vim.diagnostic.severity.WARN] = "DiagnosticVirtualTextWarn",
  [vim.diagnostic.severity.INFO] = "DiagnosticVirtualTextInfo",
  [vim.diagnostic.severity.HINT] = "DiagnosticVirtualTextHint",
}

-- These don't get copied, do they? We only pass around and compare pointers, right?
local SPACE = "space"
local DIAGNOSTIC = "diagnostic"
local OVERLAP = "overlap"
local BLANK = "blank"

-- Deprecated. Use `setup()` instead.
M.register_lsp_virtual_lines = function()
  print("lsp_lines.register_lsp_virtual_lines() is deprecated. use lsp_lines.setup() instead.")
  M.setup()
end

---Returns the distance between two columns in cells.
---
---Some characters (like tabs) take up more than one cell. A diagnostic aligned
---under such characters needs to account for that and add that many spaces to
---its left.
---
---@return integer
local function distance_between_cols(bufnr, lnum, start_col, end_col)
  local lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
  if vim.tbl_isempty(lines) then
    -- This can only happen is the line is somehow gone or out-of-bounds.
    return 1
  end

  local sub = string.sub(lines[1], start_col, end_col)
  return vim.fn.strdisplaywidth(sub, 0) -- these are indexed starting at 0
end

---@private
local function to_severity(severity)
  if type(severity) == 'string' then
    return assert(
      M.severity[string.upper(severity)],
      string.format('Invalid severity: %s', severity)
    )
  end
  return severity
end

local function filter_by_severity(severity, diagnostics)
  if not severity then
    return diagnostics
  end

  if type(severity) ~= 'table' then
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

-- Registers a wrapper-handler to render lsp lines.
-- This should usually only be called once, during initialisation.
M.setup = function()
  -- TODO: On LSP restart (e.g.: diagnostics cleared), errors don't go away.

  vim.diagnostic.handlers.virtual_lines = {
    ---@param namespace number
    ---@param bufnr number
    ---@param diagnostics table
    ---@param opts boolean
    show = function(namespace, bufnr, diagnostics, opts)
      vim.validate({
        namespace = { namespace, "n" },
        bufnr = { bufnr, "n" },
        diagnostics = {
          diagnostics,
          vim.tbl_islist,
          "a list of diagnostics",
        },
        opts = { opts, "t", true },
      })

      opts = opts or {}
      local severity
      if opts.virtual_lines then
        if opts.virtual_lines.severity then
          severity = opts.virtual_lines.severity
        end
      end
      if severity then
        print(vim.inspect(severity))
        diagnostics = filter_by_severity(severity, diagnostics)
      end

      table.sort(diagnostics, function(a, b)
        if a.lnum ~= b.lnum then
          return a.lnum < b.lnum
        else
          return a.col < b.col
        end
      end)

      local ns = vim.diagnostic.get_namespace(namespace)
      if not ns.user_data.virt_lines_ns then
        ns.user_data.virt_lines_ns = vim.api.nvim_create_namespace("")
      end
      local virt_lines_ns = ns.user_data.virt_lines_ns

      vim.api.nvim_buf_clear_namespace(bufnr, virt_lines_ns, 0, -1)

      -- This loop reads line by line, and puts them into stacks with some
      -- extra data, since rendering each line will require understanding what
      -- is beneath it.
      local line_stacks = {}
      local prev_lnum = -1
      local prev_col = 0
      for _, diagnostic in ipairs(diagnostics) do
        if line_stacks[diagnostic.lnum] == nil then
          line_stacks[diagnostic.lnum] = {}
        end

        local stack = line_stacks[diagnostic.lnum]

        if diagnostic.lnum ~= prev_lnum then
          table.insert(
            stack,
            { SPACE, string.rep(" ", distance_between_cols(bufnr, diagnostic.lnum, 0, diagnostic.col)) }
          )
        elseif diagnostic.col ~= prev_col then
          -- Clarification on the magic numbers below:
          -- +1: indexing starting at 0 in one API but at 1 on the other.
          -- -1: for non-first lines, the previous col is already drawn.
          table.insert(
            stack,
            { SPACE, string.rep(" ", distance_between_cols(bufnr, diagnostic.lnum, prev_col + 1, diagnostic.col) - 1) }
          )
        else
          table.insert(stack, { OVERLAP, diagnostic.severity })
        end

        if diagnostic.message:find("^%s*$") then
          table.insert(stack, { BLANK, diagnostic })
        else
          table.insert(stack, { DIAGNOSTIC, diagnostic })
        end

        prev_lnum = diagnostic.lnum
        prev_col = diagnostic.col
      end

      for lnum, lelements in pairs(line_stacks) do
        local virt_lines = {}

        -- We read in the order opposite to insertion because the last
        -- diagnostic for a real line, is rendered upstairs from the
        -- second-to-last, and so forth from the rest.
        for i = #lelements, 1, -1 do -- last element goes on top
          if lelements[i][1] == DIAGNOSTIC then
            local diagnostic = lelements[i][2]

            local left = {}
            local overlap = false
            local multi = 0

            -- Iterate the stack for this line to find elements on the left.
            for j = 1, i - 1 do
              local type = lelements[j][1]
              local data = lelements[j][2]
              if type == SPACE then
                if multi == 0 then
                  table.insert(left, { data, "" })
                else
                  table.insert(left, { string.rep("─", data:len()), highlight_groups[diagnostic.severity] })
                end
              elseif type == DIAGNOSTIC then
                -- If an overlap follows this, don't add an extra column.
                if lelements[j + 1][1] ~= OVERLAP then
                  table.insert(left, { "│", highlight_groups[data.severity] })
                end
                overlap = false
              elseif type == BLANK then
                if multi == 0 then
                  table.insert(left, { "└", highlight_groups[data.severity] })
                else
                  table.insert(left, { "┴", highlight_groups[data.severity] })
                end
                multi = multi + 1
              elseif type == OVERLAP then
                overlap = true
              end
            end

            local center_symbol
            if overlap and multi > 0 then
              center_symbol = "┼"
            elseif overlap then
              center_symbol = "├"
            elseif multi > 0 then
              center_symbol = "┴"
            else
              center_symbol = "└"
            end
            -- local center_text =
            local center = {
              { string.format("%s%s", center_symbol, "──── "), highlight_groups[diagnostic.severity] },
            }

            -- TODO: We can draw on the left side if and only if:
            -- a. Is the last one stacked this line.
            -- b. Has enough space on the left.
            -- c. Is just one line.
            -- d. Is not an overlap.

            for msg_line in diagnostic.message:gmatch("([^\n]+)") do
              local vline = {}
              vim.list_extend(vline, left)
              vim.list_extend(vline, center)
              vim.list_extend(vline, { { msg_line, highlight_groups[diagnostic.severity] } })

              table.insert(virt_lines, vline)

              -- Special-case for continuation lines:
              if overlap then
                center = { { "│", highlight_groups[diagnostic.severity] }, { "     ", "" } }
              else
                center = { { "      ", "" } }
              end
            end
          end
        end

        vim.api.nvim_buf_set_extmark(bufnr, virt_lines_ns, lnum, 0, {
          id = lnum + 1, -- Must be positive; +1 covers line=0.
          virt_lines = virt_lines,
          virt_lines_above = false,
        })
      end
    end,
    ---@param namespace number
    ---@param bufnr number
    hide = function(namespace, bufnr)
      local ns = vim.diagnostic.get_namespace(namespace)
      if ns.user_data.virt_lines_ns then
        vim.api.nvim_buf_clear_namespace(bufnr, ns.user_data.virt_lines_ns, 0, -1)
      end
    end,
  }
end

---@return boolean
M.toggle = function()
  local new_value = not vim.diagnostic.config().virtual_lines
  vim.diagnostic.config({ virtual_lines = new_value })
  return new_value
end

return M
