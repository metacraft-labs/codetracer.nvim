--- Highlight groups for the pane server's semantic styles.
---
--- A span names a style (`ct.value-modified`, `ct.surface-active-row`), never a
--- colour. Each style is a highlight group, `CodeTracer` followed by the role
--- in CamelCase (`CodeTracerValueModified`), defined with `default = true` as a
--- link to a standard group, so a colour scheme — or the user — styles it
--- like the rest of the editor.
local M = {}

M.namespace = vim.api.nvim_create_namespace("codetracer.panes")

-- Role → standard group, first matching rule wins (exact names before
-- prefixes).
local EXACT = {
  ["chrome-text"] = "Normal",
  ["chrome-muted"] = "Comment",
  ["chrome-title"] = "Title",
  ["chrome-title-focused"] = "Title",
  ["chrome-notification"] = "WarningMsg",
  ["chrome-error"] = "ErrorMsg",
  ["chrome-success"] = "DiagnosticOk",
  ["chrome-info"] = "DiagnosticInfo",
  ["chrome-accent"] = "Special",
  ["chrome-prompt"] = "Question",
  ["editor-text"] = "Normal",
  ["surface-selection"] = "Visual",
  ["surface-current-line"] = "CursorLine",
  ["surface-active-row"] = "CursorLine",
  ["surface-drop-indicator"] = "Search",
  ["surface-menu"] = "Pmenu",
  ["surface-card"] = "NormalFloat",
  ["surface-input"] = "NormalFloat",
  ["surface-field"] = "NormalFloat",
  ["surface-status-line"] = "StatusLine",
  ["surface-top-bar"] = "TabLine",
  ["gutter-breakpoint"] = "DiagnosticError",
  ["gutter-breakpoint-disabled"] = "Comment",
  ["gutter-tracepoint"] = "DiagnosticInfo",
  ["gutter-execution-pointer"] = "DiagnosticWarn",
  ["gutter-inspection-pointer"] = "DiagnosticHint",
  ["line-number-active"] = "CursorLineNr",
  ["line-execution"] = "CursorLine",
  ["line-search-match"] = "Search",
  ["line-not-taken"] = "Comment",
  ["value-modified"] = "DiffChange",
  ["value-unchanged"] = "Normal",
  ["value-number"] = "Number",
  ["value-string"] = "String",
  ["value-boolean"] = "Boolean",
  ["value-pointer"] = "Special",
  ["value-none"] = "Comment",
  ["value-error"] = "ErrorMsg",
  ["value-media"] = "Special",
  ["category-return-value"] = "Type",
  ["category-watch"] = "Special",
  ["call-args"] = "Identifier",
  ["call-return"] = "Type",
  ["event-fault"] = "ErrorMsg",
  ["event-tracepoint"] = "DiagnosticInfo",
  ["build-failed"] = "ErrorMsg",
  ["build-succeeded"] = "DiagnosticOk",
  ["build-running"] = "DiagnosticInfo",
  ["syntax-plain"] = "Normal",
  ["syntax-number"] = "Number",
  ["syntax-operator"] = "Operator",
  ["syntax-punctuation"] = "Delimiter",
  ["syntax-bracket"] = "Delimiter",
  ["syntax-regexp"] = "String",
  ["heat-0"] = "Comment",
  ["heat-1"] = "DiagnosticHint",
  ["heat-2"] = "DiagnosticInfo",
  ["heat-3"] = "DiagnosticWarn",
  ["heat-4"] = "DiagnosticWarn",
  ["heat-5"] = "DiagnosticError",
  ["scrubber-track"] = "PmenuSbar",
  ["scrubber-thumb"] = "PmenuThumb",
  ["scrubber-mark"] = "NonText",
  ["tab-active"] = "TabLineSel",
  ["tab-active-focused"] = "TabLineSel",
  ["line-number"] = "LineNr",
}

local PREFIX = {
  { "border-", "WinSeparator" },
  { "divider-", "WinSeparator" },
  { "tab-", "TabLine" },
  { "session-tab", "TabLine" },
  { "surface-", "Normal" },
  { "gutter-", "SignColumn" },
  { "line-number", "LineNr" },
  { "source-", "Normal" },
  { "line-", "Normal" },
  { "value-", "Identifier" },
  { "category-", "Identifier" },
  { "syntax-keyword", "Keyword" },
  { "syntax-type", "Type" },
  { "syntax-string", "String" },
  { "syntax-comment", "Comment" },
  { "syntax-tag", "Tag" },
  { "syntax-metatag", "Tag" },
  { "syntax-", "Identifier" },
  { "timeline-", "Special" },
  { "event-", "Normal" },
  { "build-", "Comment" },
  { "mode-", "ModeMsg" },
  { "frame-", "Comment" },
  { "scrubber-", "NonText" },
  { "heat-", "Comment" },
}

--- The standard group a role links to by default.
function M.default_link(role)
  local exact = EXACT[role]
  if exact then
    return exact
  end
  for _, rule in ipairs(PREFIX) do
    if role:sub(1, #rule[1]) == rule[1] then
      return rule[2]
    end
  end
  return "Normal"
end

--- `ct.value-modified` → `CodeTracerValueModified`.
function M.group_of(style)
  local role = style:gsub("^ct%.", "")
  local camel = role
    :gsub("(%w+)", function(w)
      return w:sub(1, 1):upper() .. w:sub(2)
    end)
    :gsub("[^%w]", "")
  return "CodeTracer" .. camel, role
end

local defined = {}

--- The group for `style`, defined on first use.
function M.group(style)
  local group, role = M.group_of(style)
  if not defined[group] then
    vim.api.nvim_set_hl(0, group, { link = M.default_link(role), default = true })
    defined[group] = true
  end
  return group
end

--- The plugin's own groups (source decorations, attributes).
function M.setup()
  local own = {
    CodeTracerExecutionLine = { link = "CursorLine", default = true },
    CodeTracerExecutionSign = { link = "DiagnosticWarn", default = true },
    CodeTracerBreakpointSign = { link = "DiagnosticError", default = true },
    CodeTracerBreakpointDisabledSign = { link = "Comment", default = true },
    CodeTracerTracepointSign = { link = "DiagnosticInfo", default = true },
    CodeTracerInlineValue = { link = "DiagnosticVirtualTextHint", default = true },
    CodeTracerFlowValue = { link = "Comment", default = true },
    CodeTracerStackTab = { link = "TabLine", default = true },
    CodeTracerStackTabActive = { link = "TabLineSel", default = true },
    CodeTracerBold = { bold = true, default = true },
    CodeTracerItalic = { italic = true, default = true },
    CodeTracerUnderline = { underline = true, default = true },
  }
  for name, spec in pairs(own) do
    vim.api.nvim_set_hl(0, name, spec)
  end
  -- A colour-scheme change clears links set with `default`; define them again.
  defined = {}
end

return M
