if vim.g.loaded_codetracer then
  return
end
vim.g.loaded_codetracer = true

vim.api.nvim_create_user_command("CodeTracer", function(opts)
  local ct = require("codetracer")
  if not require("codetracer.state").opts.mappings then
    ct.setup({})
  end
  ct.command(opts)
end, {
  nargs = "*",
  complete = function(arglead, cmdline)
    return require("codetracer").complete(arglead, cmdline)
  end,
  desc = "CodeTracer: open a recording, run an operation, switch sessions",
})
