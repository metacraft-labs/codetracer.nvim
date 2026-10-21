--- Key spellings: CodeTracer's keymap spells a key `Ctrl+F5`, `Alt+Left`,
--- `Shift+G`, `g g` (a sequence is space-separated); Neovim spells the same
--- keys `<C-F5>`, `<M-Left>`, `G`, `gg`. This module translates the first into
--- the second, and gives both a canonical form so a key the user mapped can be
--- recognised whichever way it was written.
local M = {}

-- CodeTracer key names that Neovim spells differently, or that need the
-- angle-bracket form even without a modifier.
local NAMED = {
  Up = "Up",
  Down = "Down",
  Left = "Left",
  Right = "Right",
  Home = "Home",
  End = "End",
  PageUp = "PageUp",
  PageDown = "PageDown",
  Enter = "CR",
  Return = "CR",
  Escape = "Esc",
  Esc = "Esc",
  Tab = "Tab",
  Backspace = "BS",
  Delete = "Del",
  Insert = "Insert",
  Space = "Space",
}
for i = 1, 12 do
  NAMED["F" .. i] = "F" .. i
end

-- Single characters that have a special meaning inside a mapping's left-hand
-- side and must be written by name (`:help <>`).
local SPECIAL_CHARS = {
  ["<"] = "lt",
  ["\\"] = "Bslash",
  ["|"] = "Bar",
  [" "] = "Space",
}

local MODIFIERS = { Ctrl = "C", Control = "C", Alt = "M", Meta = "M", Shift = "S", Cmd = "D", Super = "D" }

--- One chord (`Ctrl+Shift+F5`) as a Neovim key, or nil when it has no
--- Neovim spelling (a lone modifier, or Shift on a symbol under Ctrl).
local function chord(token)
  local parts = vim.split(token, "+", { plain = true })
  -- `Ctrl++` / `Ctrl+Shift+-`: an empty part means the key itself was `+`.
  local key = parts[#parts]
  local mods = {}
  for i = 1, #parts - 1 do
    local m = MODIFIERS[parts[i]]
    if m == nil then
      if parts[i] == "" and i == #parts - 1 and key == "" then
        key = "+"
      else
        return nil
      end
    else
      mods[#mods + 1] = m
    end
  end
  if key == "" then
    return nil
  end
  if MODIFIERS[key] then
    return nil -- a lone modifier is not a key
  end

  local shift = vim.tbl_contains(mods, "S")
  local named = NAMED[key]
  if named == nil and #key ~= 1 then
    return nil
  end
  if named == nil then
    -- A single character. Shift on a letter is the upper-case letter; a
    -- letter otherwise is lower-case (the keymap writes `Ctrl+B`).
    if key:match("%a") then
      if shift then
        key = key:upper()
        mods = vim.tbl_filter(function(m)
          return m ~= "S"
        end, mods)
        if #mods > 0 then
          -- <C-S-b>: keep Shift explicit under another modifier, where the
          -- upper-case letter alone would not say it.
          mods[#mods + 1] = "S"
          key = key:lower()
        end
      else
        key = key:lower()
      end
    elseif shift then
      return nil -- Shift on a symbol: the keymap's layout-dependent spelling
    end
    if #mods == 0 then
      local special = SPECIAL_CHARS[key]
      return special and ("<" .. special .. ">") or key
    end
    local special = SPECIAL_CHARS[key]
    return "<" .. table.concat(mods, "-") .. "-" .. (special or key) .. ">"
  end
  if #mods == 0 then
    return "<" .. named .. ">"
  end
  return "<" .. table.concat(mods, "-") .. "-" .. named .. ">"
end

--- A CodeTracer key (`Ctrl+K Ctrl+Down`, `g g`) as a mapping's left-hand
--- side, or nil when Neovim cannot express it.
function M.to_lhs(key)
  if type(key) ~= "string" or key == "" then
    return nil
  end
  local out = {}
  for token in key:gmatch("%S+") do
    local c = chord(token)
    if c == nil then
      return nil
    end
    out[#out + 1] = c
  end
  if #out == 0 then
    return nil
  end
  return table.concat(out)
end

--- The canonical spelling of a left-hand side (`<c-f5>` and `<C-F5>` are one
--- key), for comparing a key the user mapped with one the server binds.
function M.canonical(lhs)
  return vim.fn.keytrans(vim.keycode(lhs))
end

return M
