---
name: claude-code-tooling-installed
description: Claude Code add-ons installed at user scope — Context7 docs MCP, TypeScript + Pyright + Java (jdtls) LSP plugins, Chrome DevTools MCP plugin, claude-mem, Serena, security-guidance; where the binaries live and how to check them
metadata:
  type: reference
---

These were installed on 2026-10-09, all at user scope so they apply in every project.

**Context7 (docs lookup) is an MCP server, NOT a plugin.**
- Installed with `claude mcp add --transport http --scope user context7 https://mcp.context7.com/mcp` (stored in `~/.claude.json`).
- It uses the hosted endpoint and has no `CONTEXT7_API_KEY`, so it runs on the free rate limits. If calls get rate-limited, re-add it with `--header "CONTEXT7_API_KEY: <key>"`.
- Check it with `claude mcp get context7`. `installed_plugins.json` will not list it.
- Use it for SDK/framework docs (Spring Boot 3.5, Laravel 12, Nuxt 2, React 19, MUI v7) before guessing an API. OMC's `document-specialist` agent picks it up automatically.

**The LSP plugins come from the `claude-plugins-official` marketplace.**
- `typescript-lsp` runs `typescript-language-server --stdio` and covers .ts/.tsx/.js/.jsx/.mjs/.cjs/.mts/.cts.
- `pyright-lsp` runs `pyright-langserver --stdio` and covers .py/.pyi.
- `jdtls-lsp` runs `jdtls` and covers .java, with a 120s startup timeout. The binary is Eclipse JDT LS 1.61.0 (checksum-verified) in `~/.local/share/jdtls/1.61.0/`, launched by a wrapper script at `~/.local/bin/jdtls`. The wrapper pins `JAVA_HOME` to sdkman `21.0.11-ms`, because jdtls needs 21+ and Claude Code's PATH has no `java`. On a JDK upgrade, edit the wrapper; to upgrade jdtls, extract the new milestone and repoint the wrapper.
- The plugins only point at the servers. The binaries were installed separately with `npm install -g typescript typescript-language-server pyright`, which put typescript-language-server 6.0.1 and pyright 1.1.414 in `~/.nvm/versions/node/v24.15.0/bin/`.
- ⚠ The servers are tied to that nvm Node version. If Claude Code starts without it on PATH, or after `nvm use` switches to another version, the plugins are loaded but silently get no server. Fix by re-running the npm install under the active Node.

**Chrome DevTools is a plugin (`chrome-devtools-mcp@claude-plugins-official` 1.9.0), not a hand-added MCP server.**
- It ships its own stdio MCP server, `chrome-devtools`, which runs `npx --prefix ${PLUGIN_DATA} chrome-devtools-mcp@1.9.0`. It drives the system Chrome at `/usr/bin/google-chrome`.
- It needs `npx` on PATH, so the same nvm Node caveat as the LSP servers applies.
- Prefer it over the puppeteer-core recipe in [[wms2-web-ui-headless-browser-recipe]] when a live browser session is enough.

**claude-mem (`claude-mem@thedotmack` 13.35.0) comes from a third-party marketplace, added with `claude plugin marketplace add thedotmack/claude-mem`.**
- It hooks every lifecycle event (SessionStart, UserPromptSubmit, Pre/PostToolUse, Stop, SessionEnd), compresses what it captures, and injects context into new sessions. That runs ALONGSIDE this memory dir and OMC's hooks; it does not replace them.
- It needs Bun, and its Setup hook does NOT install it (it only logs "bun not found"). Bun 1.4.2 went in with `npm install -g bun` (nvm v24.15.0), then `bun install` was run in the plugin cache dir. After a plugin upgrade, re-run `bun install` in the new version dir if the worker crashes with missing modules.
- The sibling `claude-mem-cowork` streams tool use to cmem.ai. It was deliberately NOT installed.

**Serena is a plugin (`serena@claude-plugins-official`) that runs `uvx --from git+https://github.com/oraios/serena serena start-mcp-server`.**
- It needs `uvx` (`~/.local/bin`, uv 0.11.12). The uvx env was pre-built on 2026-10-09 so the first MCP start doesn't time out.
- The plugin tracks the repo's HEAD (unpinned), so a new upstream commit triggers a rebuild on a later start.
- It overlaps with the TS/Pyright LSP plugins and OMC's `lsp_*` / `ast_grep_*` tools, which are all symbol-level navigation. Serena's edge is whole-repo symbol editing and Java support; it downloads its own language servers per language on first use.
- `~/.serena/serena_config.yml` was created from the bundled template with `web_dashboard_open_on_launch: False`, so no browser tab opens per session. The dashboard itself is still ON at http://localhost:24282/dashboard/ (the port goes higher per extra instance).

**security-guidance (`security-guidance@claude-plugins-official` 2.0.12) runs pattern warnings on edits/Bash, an LLM diff review on Stop, and a commit reviewer.**
- Its SessionStart hook builds `~/.claude/security/agent-sdk-venv`. That build FAILS on this machine: system python3.12 has no `ensurepip` (`python3-venv` not installed) and no `pip`, so it reports `sdk_bootstrap: 3` and leaves an empty venv.
- Fixed without sudo: `uv venv --python /usr/bin/python3 ~/.claude/security/agent-sdk-venv && uv pip install --python <venv>/bin/python claude-agent-sdk` (0.2.165). The hook then reports `sdk_bootstrap: 1` (reused). If it breaks again, rebuild it the same way.
- Its warnings arrive as `PostToolUse` additionalContext: "[from security-guidance…] ⚠️ Security Warning…". They come from a plugin hook, not from the user.

All of these load only in sessions started after the install. If MCP tools are missing, see [[wms-mcp-tools-not-surfaced-use-psql-direct]]: `claude mcp list` and the session registry can disagree.
