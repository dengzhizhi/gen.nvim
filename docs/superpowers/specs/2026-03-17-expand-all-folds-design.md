# Expand All Folds In Gen Windows

## Goal

Ensure every window created by `gen.nvim` starts with folds expanded, regardless of
the active display mode or any markdown/plugin-driven folding behavior attached to
the result buffer.

## Scope

- Apply to `float`, `horizontal-split`, `vertical-split`, `no-split`, and invalid
  display mode fallback windows.
- Affect only the `gen.nvim` result window.
- Preserve the existing fold configuration and providers; only expand folds after
  the window is created and configured.

## Approach

Add a small helper in `lua/gen/init.lua` that runs `silent! normal! zR` in the
result window context after `setup_window()` completes. This matches the requested
behavior exactly and keeps the change local to the generated result window.

## Testing

Add an automated test that:

- Creates folds in the current buffer before `gen.run_command()` opens the result
  window.
- Verifies the resulting window starts with closed folds before the feature is
  implemented.
- Verifies folds are open after the change by checking the fold state in the gen
  buffer window.
