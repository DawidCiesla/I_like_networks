# Agent guidance

## Godot MCP

- The Godot project lives in `godot/`. Codex loads its MCP server from `.codex/config.toml`; `godot/.mcp.json` remains the config for clients that read that format.
- Keep the local Godot editor open with the Godot MCP Toolkit plugin enabled. The bridge discovers the editor's loopback port and authenticates using the token managed by the addon; do not copy that token into config files.
- Node.js 22+ and npm access are needed on first launch because `npx` fetches the bridge package.
- Use Godot MCP tools for live editor and scene operations. Inspect the current editor state before making changes. The Codex config asks before tools marked as writes run.
- If the server is unavailable, check that this repository is trusted by Codex, the Godot editor is running, and the addon is active. The loopback server is available only to agents running on the same machine as that editor.
