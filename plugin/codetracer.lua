if vim.g.loaded_codetracer then
  return
end
vim.g.loaded_codetracer = true

local function ensure_setup()
  if not require("codetracer.state").opts.mappings then
    require("codetracer").setup({})
  end
end

vim.api.nvim_create_user_command("CodeTracer", function(opts)
  ensure_setup()
  require("codetracer").command(opts)
end, {
  nargs = "*",
  complete = function(arglead, cmdline)
    return require("codetracer").complete(arglead, cmdline)
  end,
  desc = "CodeTracer: open a recording, run an operation, switch sessions",
})

-- A session file (`:mksession`) that saved CodeTracer sessions brings them
-- back (`:help codetracer-sessions`). Registered here, not in setup(), so a
-- session loaded at startup (`nvim -S`) is restored without any setup call.
vim.api.nvim_create_autocmd("SessionLoadPost", {
  group = vim.api.nvim_create_augroup("codetracer.session", { clear = true }),
  callback = function()
    if vim.g.codetracer_restore ~= nil then
      ensure_setup()
      require("codetracer.persist").on_session_load()
    end
  end,
})
