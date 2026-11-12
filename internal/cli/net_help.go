package cli

const serveHelp = `USAGE: dit serve [PORT] [--host ADDR] [--token TOKEN] [--immutable]

  Serve this machine's portfolio over the network so another machine
  can connect to it. The server listens on PORT (default 8348) on
  all interfaces, and runs until you press Ctrl-C. It publishes the
  LOCAL stores: serving never goes through a saved connection, and
  connecting elsewhere does not change what is served here.

  MUTABLE BY DEFAULT. While serving, remote commands (tx, account,
  import, update, ...) can read AND change the portfolio. Re-run
  with --immutable to serve read-only: remote commands can read,
  but every write is refused with an error.

  --token TOKEN  require authentication. Clients must pass the same
                 token ('dit connect HOST:PORT --token TOKEN').
  --token=       (empty value) generate a random token and print it.
  no --token     open access — anyone who can reach the port can
                 read the portfolio, and change it unless --immutable.
                 The banner warns; serve only on a trusted network.
  --host ADDR    listen address (default 0.0.0.0, all interfaces).

  The banner prints the address and the exact 'dit connect' line
  for clients. 'dit clone HOST:PORT' on another machine pulls the
  whole portfolio (ledger + market data) into that machine's local
  stores; 'dit connect HOST:PORT' instead makes its commands run
  against this one live.`

const cloneHelp = `USAGE: dit clone [HOST:PORT] [--token TOKEN] [--yes] [--force]

  Pull a remote portfolio into the local stores. HOST:PORT is a
  machine running 'dit serve' (default port 8348). Without a
  target, the saved connection from 'dit connect' is cloned.

  The remote's whole portfolio — accounts, transactions, tickers,
  market data, FX rates — replaces the local documents, exactly
  like 'dit import BUNDLE'. Before replacing, the current local
  stores are backed up (see 'dit rollback'); --force skips the
  backup. The replacement is confirmed first; --yes skips the
  confirmation (required on non-interactive terminals).

  Cloning writes ONLY the local stores: the remote is read, and
  its own data is never touched. A serve may run with --immutable:
  cloning is a pure read of the remote, and immutability only
  forbids changes, which clone never makes.`

const connectHelp = `USAGE: dit connect HOST:PORT [--token TOKEN]

  Remember a remote portfolio as the active target. Subsequent
  commands (summary, accounts, tx, pnl, ...) run against THAT
  machine's data, not the local stores; every result is prefixed
  with a banner naming the address and port. 'dit disconnect'
  clears the target and returns to the local stores. Nothing is
  copied or changed by connecting: it is a pointer, not a mirror.

  HOST:PORT is a machine running 'dit serve' (default port 8348;
  the scheme may be omitted). Before saving, the connection is
  verified: the protocol is checked, and if the server runs with
  --immutable the connection is recorded as read-only, so write
  commands fail fast with a clear error.

  --token TOKEN  the server's token (see 'dit serve --token').
                 Re-running 'dit connect' against the saved target
                 keeps the saved token unless a new one is given.

  The target, token and read-only state are stored in
  ~/.dit/config.json (the DIT_REMOTE_URL / DIT_REMOTE_TOKEN /
  DIT_REMOTE_READONLY environment variables override it).`

const disconnectHelp = `USAGE: dit disconnect

  Clear the saved remote connection. Commands immediately run
  against the local stores again; the banner disappears. No data
  is deleted on either side — the remote machine keeps serving,
  and the local stores are exactly as they were. (Connected
  commands wrote the REMOTE stores, not these: disconnect only
  moves commands back, it never rewrites local data.)

  'dit connect' saves where commands run; 'dit disconnect'
  un-saves it. 'dit clone' copies data in; 'dit disconnect' does
  not.`
