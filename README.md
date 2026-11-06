# Meilynx for Claude Code

Claude Code runs tools on a developer's machine: shell commands, file edits, web fetches and calls to MCP servers. This plugin puts each of those tool calls in front of your organization's Meilynx proxy before it runs. The proxy applies your organization's tool access rules, content checks and approval holds, records the decision as a sealed entry in your audit chain, and tells Claude Code whether the tool may run.

The plugin is for organizations with a Meilynx subscription. You need the address of your organization's Meilynx proxy and a credential from your Meilynx administrator.

## What the plugin does

For every covered tool call:

1. **Before the tool runs**, Claude Code starts the Meilynx hook adapter, which sends the call to your Meilynx proxy.
2. The proxy decides: **allow**, **deny**, or **hold for approval**. It seals the decision into your audit chain before it answers.
3. A deny or a hold stops the tool, and the developer sees the reason. An allow adds no approval of its own, so Claude Code's usual permission prompts still apply. Meilynx never approves a tool call on a developer's behalf.
4. **After the tool runs**, the adapter sends the result to the proxy, which seals it in the same chain. A finding on the result is shown to Claude as feedback. The tool has already run at that point, so nothing is undone.

### Covered tools

| Claude Code tool | What it does |
|---|---|
| Bash, PowerShell | Runs a command |
| Edit, Write, NotebookEdit | Changes a file |
| WebFetch | Fetches a web page |
| Any MCP tool | Calls a tool on an MCP server |

Other tools, such as Read, Glob, WebSearch and TodoWrite, are not sent to the proxy.

## What is sent, and where

The plugin communicates with exactly two destinations.

| Destination | When | What is sent |
|---|---|---|
| **Your organization's Meilynx proxy**, at the address you configure (for example `https://px-7f3a2c9d.proxy.meilynx.com`) | Before and after each covered tool call | The tool name; the full tool input (for example the command line, the file path and the text being written, the address being fetched, or the arguments of an MCP tool); after the call, the tool's result; the identifier Claude Code gives the tool call; the Claude Code session identifier; and the name of the host, `claude-code`. Every request uses HTTPS and carries your Meilynx credential. The plugin refuses a proxy address that does not start with `https://`. |
| **GitHub** (`github.com` and the download hosts GitHub redirects to) | Once per adapter version, at the first session after install or update | A download request for the adapter build for your operating system, from this repository's releases. Nothing about your work, your files or your credential is sent. |

Nothing else leaves the machine. The plugin sends no usage data to Meilynx or to anyone else, and it does not read or send any credential other than the one you give it.

**Where the content goes after the proxy.** Your Meilynx proxy runs in an environment dedicated to your organization. The tool input and result stay in your organization's own capture store, under the capture policy your organization sets. The Meilynx control plane receives metadata only: tool names, decisions, reasons, chain positions and cryptographic digests. It never receives the tool input or the result.

**What is stored on the developer's machine.**

| Item | Location | Contents |
|---|---|---|
| The adapter program | Claude Code's data folder for this plugin (`~/.claude/plugins/data/`) | The downloaded adapter, kept only after its checksum matches the one pinned in this plugin |
| Adapter state | `~/.meilynx/hook/` | The proxy's last stated fail mode (see below) and, only if your organization opted into fail open, a list of tool calls made while the proxy was unreachable: tool name, identifiers, the cause and a digest of the input. No tool content. |
| Plugin settings | Claude Code's settings | The proxy address and any file paths you entered |
| Your credential | Your operating system's secure credential store (the macOS Keychain, or Claude Code's credentials file where no keychain is available) | The credential you entered. It is never written to a settings file, a message or a log. |

## How the adapter is obtained and checked

The adapter is a compiled program built by Meilynx for Linux (x86_64 and arm64), macOS (Apple silicon and Intel) and Windows (x86_64). It is not stored in this repository. At the start of the first session after you install or update the plugin, the plugin downloads the build for your machine from this repository's GitHub releases and compares its SHA-256 checksum with the checksum pinned in `adapter/SHA256SUMS`. A download that does not match is deleted and never run. Each new Claude Code session checks the installed copy against the pinned checksum again.

Each release also carries a Sigstore signature and a build provenance attestation for every file, so your security team can confirm independently that a build came from Meilynx's release pipeline.

The macOS builds in release 0.1.0 are not notarized by Apple, and the Windows build carries no Authenticode signature. A device policy that runs only platform-signed programs will refuse the adapter, and covered tool calls are then denied.

## What happens when something fails

Unless your organization opted into fail open, the plugin blocks a covered tool call whenever it cannot get a decision from the proxy.

| Condition | Result |
|---|---|
| The proxy is unreachable, does not answer within the adapter's deadline (5 seconds by default), or answers with an error | The tool call is denied, with the cause in the message |
| The adapter cannot be downloaded, does not match its pinned checksum, cannot read its configuration, or fails internally | The tool call is denied |
| The adapter is missing, crashes, or does not answer within Claude Code's hook timeout | The tool call is denied, on Claude Code 2.1.295 or later |
| No proxy address or credential is configured | The tool call is denied |
| Your organization opted into fail open for a bounded period, and the proxy gave no answer at all | The tool call runs and is recorded on the machine, then sent to the proxy and sealed once the proxy is reachable again. Records sent this way are marked as asserted by the adapter. |

On Windows, install Git for Windows on each machine: Claude Code runs this plugin's hooks through the Git Bash shell it provides.

A developer can remove or disable a plugin they installed themselves. To keep the plugin in place, deliver it through managed settings as described under [Roll out across your organization](#roll-out-across-your-organization).

## What the developer sees

| Decision | In Claude Code |
|---|---|
| Allow | Nothing from Meilynx. Claude Code's own permission flow decides as usual. |
| Deny | The tool does not run. The message gives the reason and the rule that applied. |
| Hold | The tool does not run. The message carries a hold id. A reviewer releases or denies the hold in Meilynx under **Compliance > MCP Approvals**, and once released, the agent's next retry runs once. |

Messages carry the proxy's reason, the rule and the hold id. They never carry the tool input or the credential.

## Install for one developer

Use this to evaluate the plugin. In Claude Code:

```
/plugin marketplace add Meilynx/meilynx-claude-plugin
/plugin install meilynx@meilynx
```

Claude Code asks for:

- **Meilynx proxy URL**: your organization's proxy address.
- **Meilynx credential**: the agent credential or project key your Meilynx administrator issued. Claude Code stores it in your system's secure credential store.

Leave the two optional fields empty unless your IT team gives you a credential file or a configuration file. Start a new session, and the plugin downloads and checks the adapter.

Before the first covered tool call is allowed, your Meilynx administrator authors the rules that allow it: in Meilynx, **Policies > Tool Access**, with **Claude Code** chosen under *Coding-agent hooks*, then publish. Covered tool calls are denied until a rule allows them.

## Roll out across your organization

For an organization, deliver the plugin through Claude Code **managed settings**, so it is installed on every machine, cannot be disabled by a developer, and keeps running when you allow only managed hooks. Use endpoint-managed settings (an MDM profile or the `managed-settings.json` file on each machine). Claude Code does not fetch server-managed settings in some configurations that send model traffic to a proxy, for example when `ANTHROPIC_BASE_URL` is exported in a developer's shell, and endpoint-managed settings apply in every configuration.

```json
{
  "extraKnownMarketplaces": {
    "meilynx": {
      "source": { "source": "github", "repo": "Meilynx/meilynx-claude-plugin" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": {
    "meilynx@meilynx": true
  },
  "allowManagedHooksOnly": true,
  "pluginConfigs": {
    "meilynx@meilynx": {
      "options": {
        "proxy_url": "https://px-7f3a2c9d.proxy.meilynx.com",
        "credential_file": "/etc/meilynx/hook-credential"
      }
    }
  }
}
```

What each key does:

- `extraKnownMarketplaces` and `enabledPlugins` install the plugin on every machine that receives the settings. A plugin enabled in managed settings stays enabled even if a developer turns it off.
- `allowManagedHooksOnly` stops hooks from any other source. Hooks from a plugin that managed settings enable still run, matched on the full name `meilynx@meilynx`.
- `pluginConfigs` sets the proxy address and the credential file for every developer, so nobody types them. Provision the credential file with your device management, readable by the developer's account only. A credential typed into Claude Code is stored per user, so a fleet rollout uses a credential file.

To also send Claude Code's model traffic through your Meilynx proxy, set `ANTHROPIC_BASE_URL` to the proxy address in the same managed settings, under `env`. Your Meilynx contact can confirm the settings for your deployment.

To limit developers to approved marketplaces, add `strictKnownMarketplaces` as described in Claude Code's documentation on managing plugins for an organization.

## Verify a sealed record

Every decision is a receipt in Meilynx under **Compliance > Evidence**, listed under the virtual server `hook.claude-code`. Each receipt shows the tool name, the decision and its reason, the record's position in the hash chain, a digest of the tool input or result, and a chain integrity verdict. **Chain intact** means every record in scope verified and the chain's order is unbroken.

To check the chain without relying on Meilynx systems:

1. In Meilynx, open **Governance > Local Audit** and generate an integrity pack for the period you want to examine.
2. Run the independent verifier on the pack. The verifier is published under an open-source licence at [github.com/Meilynx/meilynx-verify](https://github.com/Meilynx/meilynx-verify) and runs offline:

   ```
   python3 verify-pack.py --records <pack>/records --manifest <pack>/manifest.json
   ```

   Exit code `0` means every record verified. Any change to a record, including a decision, a reason or a session identifier, breaks verification, and the output names the first record that fails. The verifier's README lists the options for a signed pack.

## Documentation and support

- Customer documentation, for signed-in Meilynx customers: [docs.meilynx.com/mcp/claude-code-hooks](https://docs.meilynx.com/mcp/claude-code-hooks)
- Support: [support@meilynx.com](mailto:support@meilynx.com)
- Security reports: [security@meilynx.com](mailto:security@meilynx.com)
- Privacy policy: [meilynx.com/privacy](https://www.meilynx.com/privacy)
- Terms: [meilynx.com/terms](https://www.meilynx.com/terms)

## Licence

Proprietary. Use is permitted with a Meilynx subscription. See [LICENSE](LICENSE).
