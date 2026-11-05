# meum Claude Code plugin

Connects Claude Code sessions to meum's MCP server (`meum mcp`, see the main README's "For agents").

The server's program is `$MEUM_CLI` when that is set, otherwise `/Applications/meum.app/Contents/Resources/bin/meum`.
meum sets `MEUM_CLI` in its own tabs to the meum that runs them; the plugin trusts the variable as given, like any
other part of the session's environment.
