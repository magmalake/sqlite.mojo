# Changelog

## Unreleased

## 0.3.5 - 2026-11-03

- libsqlite3 is found without `CONDA_PREFIX`: after `$CONDA_PREFIX/lib`,
  the tin looks next to the executable, in its `../lib`, and then asks the
  dynamic linker, which searches the binary's rpath (the environment
  `mojo build` ran in) before the system. A binary built with `pixi run
  mojo build` now runs from a plain shell with the environment's
  libsqlite3. The search lives in `sqlite/_dlopen.mojo`, shared with the
  other magmalake tins that load a library.
- A libsqlite3 that can't be loaded is an Error raised by the first call
  that needs it, naming every place searched and saying to set
  `CONDA_PREFIX`. It used to abort the process.
