package cli

const upgradeHelp = `USAGE: dit upgrade [--check] [--version VERSION] [--yes]

  Download the latest release of dit from the GitHub releases page and
  replace the running binary in place.

  --check            only compare versions and report; change nothing.
  --version VERSION  install a pinned release (vX.Y.Z or X.Y.Z) instead of
                     the latest — how a downgrade is done.
  --yes              skip the confirmation (required on non-interactive
                     terminals).

  Before the replacement, the new binary is executed with --version: a
  corrupt or wrong-platform download is discarded and the working binary
  is never touched. The existing binary is backed up beside it first —
  dit.0.0.16 next to dit, dit.exe.0.0.16 on Windows — so rolling back is
  renaming the backup.

  The binary must sit in a directory you can write to; if it cannot be
  replaced, the error says so and the current binary is left in place.
  'dit update' is a different command: it refreshes market data.`
