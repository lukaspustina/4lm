# Briefing: LLM Stack Setup auf MacBook Pro M5 Max

> **An den Coding Agent:** Dieses Briefing fasst Kontext, Architektur, Begründungen und offene Aufgaben zusammen. Lies es vollständig, bevor Du Code anfasst. Die Empfehlungen darin sind das Ergebnis mehrerer Recherche-Iterationen und sollten nicht ohne Begründung umgeworfen werden.

---

## 1. Kontext & Hardware

**Nutzer:** CTO, promovierter Informatiker, sehr technisch. Erwartet nüchterne Direktheit, keine Marketing-Floskeln, klare Trade-offs. Kommt von Claude Code, will jetzt produktiv mit OpenCode + lokalen Modellen arbeiten.

**Hardware:**
- MacBook Pro 16", M5 Max, 18 Cores
- 128 GB Unified Memory (~96 GB realistisch nutzbar nach OS/Apps/Browser)
- macOS Tahoe 26.4.1
- M5 Neural Accelerators in jedem GPU-Core, via Metal 4 in MLX-Backend zugänglich (3,8-4× TTFT-Speedup vs M4 für Prefill auf MoE-Modellen)
- 614 GB/s Memory-Bandwidth

**Kontext zur Person:**
- Existierender Homelab-Stack: Proxmox, TrueNAS, K3s, Wazuh, Gitea Actions, Portainer BE, Traefik
- Nutzt Tailscale für VPN/LAN-Zugriff (kann für Stack-Exposure relevant sein)
- 1Password als Credential-Manager
- Aktive Obsidian-Vaults (zwei, Zettelkasten-Style, DE/EN gemischt)
- Open-Source-Entwickler mit Rust-Tooling (mhost, Prism, tlsight, ifconfig-rs auf netray.info)
- Familienkontext: kann auf Privacy-Anforderungen einzahlen (Frau/Kinder, eigene Email/Kalender)

---

## 2. Software-Stack — Architektur

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ launchd (user-level, manual via `4lm start`)                                 │
│                                                                              │
│  ┌──────────────────────────────────┐  ┌──────────────────────────────────┐  │
│  │ com.4lm.backend    │  │ com.4lm.webui      │  │
│  │ (RunAtLoad, KeepAlive)           │  │ (RunAtLoad, KeepAlive)           │  │
│  │                                  │  │                                  │  │
│  │ → 4lm-backend-start.sh           │  │ → 4lm-webui-start.sh             │  │
│  │   → mlx-openai-server            │  │   → open-webui serve             │  │
│  │     :8000 (OpenAI API)           │←─│     :3000 (Web UI)               │  │
│  └──────────────────────────────────┘  └──────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
        ▲                                  ▲
        │ HTTP                             │ HTTP (browser)
        │                                  │
   ┌────┴─────┐                       ┌────┴─────┐
   │ OpenCode │                       │  Safari  │
   │   TUI    │                       │  Chrome  │
   └──────────┘                       └──────────┘
```

**Layer-Trennung:**
- **Layer 1 — Inference:** `mlx-openai-server` v1.7.1 (cubist38), Python/FastAPI-Daemon auf :8000. Liefert OpenAI-kompatible `/v1/chat/completions` mit dedizierten Tool-Call-Parsern pro Modell-Familie.
- **Layer 2 — Modelle:** MLX-Quants als Safetensors aus HF-Cache (~/.cache/huggingface/hub).
- **Layer 3 — MLX-Runtime:** Apples `mlx` + `mlx-lm`, nutzt Metal 4.
- **Layer 4 — Coding-Frontend:** OpenCode TUI (sst/opencode, derzeit anomalyco-Fork), spricht :8000.
- **Layer 5 — MCP-Server:** Per-Client subprocess-gespawnt von OpenCode (filesystem, git, github, gitea, obsidian, tavily, context7, sequential-thinking, playwright, postgres-readonly).
- **Layer 6 — Wissens-Layer:** Obsidian + Smart Connections Plugin (lokale Embeddings BGE-M3 oder Qwen3-Embedding-4B), `smart-connections-mcp` exponiert an OpenCode.
- **Layer 7 — Web-Frontend:** Open WebUI auf :3000, eigener launchd-Daemon.

---

## 3. Modell-Setup (Stand April 2026)

**Drei Slots:**

| Slot | Modell | Quant | Größe | Wofür |
|---|---|---|---|---|
| Build | GLM-4.7-Flash | MLX 8-bit | ~33 GB | Coding, Tool-Calling, Terminal-Tasks |
| Plan/Knowledge | Qwen3.6-35B-A3B | MLX 8-bit | ~38 GB | Long-Context-Reasoning, Multilingual, Vault-Synthese |
| Heavy-Reasoning | GPT-OSS-120B | MXFP4 | ~62 GB | On-demand für E-Mail-Multi-Thread, schwere Reasoning-Tasks |

**RAM-Bilanz Default-Profil:** Slot 1 + Slot 2 permanent geladen ≈ 71 GB Weights + KV-Cache. Die YAML-Profile geben `context_length: 65536` (64k) für Slot 1 und 2, `32768` (32k) für Slot 3 — die KV-Größe hängt zusätzlich von Modell-Architektur (`n_heads × head_dim`) und tatsächlicher Belegung pro Sequenz ab und ist erst zur Laufzeit messbar (siehe `4lm status` → Memory). Slot 3 lädt on-demand (`on_demand: true`, `on_demand_idle_timeout: 300`), tauscht Slot 2 temporär raus.

> **Phase-1-Reconciliation (2026-04-26):** Frühere Versionen des Briefings nannten "12 GB KV-Cache @32k". Die YAML-Profile waren auf 64k gestellt; zudem nutzten sie die nicht im Schema dokumentierten Keys `context_window`, `idle_timeout` und `max_concurrency`, die `mlx-openai-server` v1.7.1 stillschweigend ignoriert hat. Korrigiert auf `context_length` und `on_demand_idle_timeout` (siehe `docs/profile-schema.md`). Tatsächliche KV-Cache-Größe wird zur Laufzeit verifiziert.

**Begründung der Modellwahl** (nicht ohne Recherche kippen):

- **GLM-4.7-Flash für Build:** τ²-Bench Telecom 84,7 % (Open-Weight-SOTA für Tool-Calling), MIT-Lizenz, 30B-A3B-MoE läuft auf M5 mit hoher Geschwindigkeit, OpenCode-validiert.
- **Qwen3.6-35B-A3B für Plan/Knowledge:** SWE-Bench Verified 73,4 %, GPQA Diamond 86 %, MMLU-Pro 85,2 %, 256k Kontext, 119 Sprachen Training (entscheidend für DE-Vault-Inhalte). Halber RAM-Footprint vs Qwen3-Coder-Next 80B-A3B bei besseren Reasoning-Werten.
- **GPT-OSS-120B für Reasoning:** Höchstes MMLU in der lokalen Klasse (90), `harmony`-Parser nativ, 128k Kontext.

**Verworfene Modelle (nicht erneut evaluieren ohne neuen Anlass):**

- GLM-5 / GLM-5.1 (744-754B): RAM-Footprint 220-417 GB, kein MLX-Loader (`glm_moe_dsa` nicht in mlx-lm).
- Kimi K2.5 / K2.6 (1T): minimum 350-510 GB, im RAG-Setup unmöglich. Cloud-API-Option für Premium-Spot.
- DeepSeek V4-Pro (1.6T) / V4-Flash (284B): zu groß bzw. kein Tool-Parser in mlx-openai-server.
- Qwen3-Coder-Next 80B-A3B: war Vorgänger-Empfehlung, durch Qwen3.6-35B-A3B abgelöst (halber RAM, bessere Reasoning).
- MiniMax M2.5/M2.7 (230B): kippt OOM auf 128 GB.
- Devstral 2 123B: Lizenz-Restriktionen ($20M-Cap), Tool-Parser-Lücke.

---

## 4. Cloud-Fallback (für OpenCode-Hybrid-Mode)

| Tier | Modell | Kosten | Wann nutzen |
|---|---|---|---|
| Daily-Driver Premium | Z.ai GLM Coding Plan Pro | ~$30/Mo | 80 % der Cloud-Tasks (GLM-5.1) |
| Long-Horizon Spot | Kimi K2.6 via Moonshot/Baseten | $0,95/$4 per M | 4000+ Tool-Calls, Multi-Agent-Swarm |
| Refactor Premium | Claude Sonnet 4.6 | $3/$15 per M | Multi-File-Refactors, finale QA |
| Long-Context | Gemini 3.1 Pro | $2-4/$12-18 per M | Codebase-Analyse >200k |

**Nicht empfohlen:** GPT-5.5 (Preisverdopplung), Claude Max-Subscription (Anthropic-OAuth-Block für Drittanbieter-Agenten seit Februar 2026), GPT-5.2-Codex (abgelöst).

---

## 5. Was bereits geliefert ist

Im Repo-Root:

```
bin/
├── 4lm                          # Main control script (Bash)
├── 4lm-backend-start.sh         # launchd-Wrapper für mlx-openai-server
└── 4lm-webui-start.sh           # launchd-Wrapper für Open WebUI
launchd/
├── com.4lm.backend.plist
└── com.4lm.webui.plist
config/
├── profiles/
│   ├── default.yaml             # GLM + Qwen3.6 + GPT-OSS-on-demand
│   ├── coding-only.yaml         # GLM solo, 200k Kontext
│   └── knowledge-only.yaml      # Qwen3.6 solo, 256k Kontext
└── network.example.yaml         # Bind-Mode Template
docs/                            # setup.md, profile-schema.md
tests/                           # bats-Suite
.github/workflows/ci.yml         # macOS-CI
install.sh                       # Idempotenter Installer (kein bootstrap)
requirements.txt                 # mlx-openai-server==1.7.1, open-webui==0.6.43
Makefile                         # lint / fmt / test / check
README.md                        # Operator-Setup
```

**Eigenschaften der gelieferten Skripte:**
- Alle Bash-Scripts mit `set -euo pipefail`, Color-Output nur bei TTY (Pipe-safe).
- launchd-Plists nutzen moderne `bootstrap`/`bootout`/`kickstart`-Idiome, plus `Umask=0077`.
- Plists liegen in `~/.4lm/launchd/` — **nicht** in `~/Library/LaunchAgents/`. launchd scannt diesen Pfad nicht, deshalb kein Auto-Start beim Login. `4lm start` lädt explizit per `bootstrap`.
- `KeepAlive` nur bei `Crashed`, nicht bei `SuccessfulExit` — saubere `4lm stop` ohne Restart-Storm.
- `ThrottleInterval=30s`, `ExitTimeOut=60s` (MLX-Modelle brauchen Zeit zum Entladen).
- `__HOME__`-Platzhalter im Plist, durch Installer ersetzt.
- `4lm`-Kommando: `start | stop | restart | status | health | logs | profile {list|set|current} | expose | doctor | open | uninstall`.
- Profile-Switching ist atomar mit Rollback: validiert YAML, swappt Symlink, kickstartet Backend, polled `/v1/models` 30 s; bei Timeout Symlink-Rollback und erneuter Kickstart.
- LAN-Exposure nur über `4lm expose lan --confirm`. Dabei wird `WEBUI_REGISTRATION_ENABLED=false`, persistenter `WEBUI_SECRET_KEY` (mode 0600) und `DEFAULT_USER_ROLE=pending` gesetzt.

**Syntaktisch validiert** (`bash -n`, `plutil -lint`, `xmllint --noout`), Smoke-Tests via bats (CI auf `macos-latest`), aber **nicht End-to-End auf macOS getestet** (Modelle nicht geladen). Erste Inbetriebnahme ist Aufgabe des Operators (siehe `docs/setup.md`).

---

## 6. Aufgaben für den Coding Agent

### Phase A — Inbetriebnahme (Priorität 1)

1. **Voraussetzungen prüfen** — Python 3.11+, `huggingface-cli`. Pip-Pakete pinnt `requirements.txt`; `install.sh` ruft `pip install -r requirements.txt`.
2. **Modelle vorab herunterladen** (siehe Tabelle oben). ~140 GB Disk einplanen. Genaue Befehle in `docs/setup.md`.
3. **Wired-Memory-Limit + Sudoers** konfigurieren (Details in `docs/setup.md §Sudoers`):
   ```bash
   sudo /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304
   echo "iogpu.wired_limit_mb=98304" | sudo tee -a /etc/sysctl.conf
   ```
   Sudoers-Literal **muss exakt passen** (`/usr/sbin/sysctl -w iogpu.wired_limit_mb=98304`):
   ```
   lukas ALL=(root) NOPASSWD: /usr/sbin/sysctl -w iogpu.wired_limit_mb=98304
   ```
4. **`./install.sh` ausführen**, auf Fehler prüfen. Insbesondere:
   - Existieren `~/.local/bin` und ist es in `PATH`?
   - Wurden Plists nach `~/.4lm/launchd/` kopiert (NICHT `~/Library/LaunchAgents/`) und `__HOME__` substituiert?
   - Ist `~/.local/bin/4lm`-Symlink lauffähig?
   - `4lm doctor` läuft sauber durch.
5. **`4lm start` ausführen**, dann `4lm status` und `4lm health`. Erwarte 30-60 s Ladezeit für 71 GB Weights. Services starten **nicht** automatisch nach Reboot — bewusst. `4lm start` muss manuell aufgerufen werden.
6. **Open WebUI Erst-Registrierung im Inkognito-Fenster.** `DEFAULT_USER_ROLE=pending` heißt: jedes neue Konto landet ohne Rechte. Nach Registrierung explizit zum Admin promoten via WebUI-Admin-Panel.

### Phase B — OpenCode-Integration (Priorität 1)

7. **OpenCode installieren:** `brew install anomalyco/tap/opencode` (NICHT das gedrosselte Standard-`opencode`-Formula — nutze den anomaly-Fork).
8. **`~/.config/opencode/opencode.jsonc` erstellen** mit:
   - Provider `mlx` → `http://127.0.0.1:8000/v1`, Modelle `glm-4.7-flash`, `qwen3.6-35b`, `gpt-oss-120b`
   - Provider `zai` → `https://api.z.ai/coding/paas/v4` mit `{env:ZAI_API_KEY}`
   - Agents: `build` (mlx/glm-4.7-flash), `plan` (mlx/qwen3.6-35b), `review` (mlx/gpt-oss-120b), `escalate` (anthropic/claude-sonnet-4-6)
   - MCP-Server-Block für: filesystem, git, github, gitea, obsidian (via Local-REST-API-Plugin), tavily, context7, sequential-thinking, playwright, postgres-readonly
   - Permissions: `edit: ask`, `bash`-Whitelist projektspezifisch (rg, ls, cat, git status/diff/log → allow; rm -rf, sudo, git push → deny)
   - `autoupdate: false`, Version pinnen
9. **AGENTS.md im Projekt-Root** anlegen, schlank halten (≤150 Instruktionen — Frontier-Modelle folgen sonst nicht zuverlässig).
10. **Test-Run:** `cd ~/projects/<irgendwas> && opencode` — prüfe Tool-Loop, Multi-Turn-Stabilität, Modell-Switch via Agents.

### Phase C — Open WebUI Konfiguration (Priorität 2)

11. **Backend-Connection in WebUI-Settings:** OpenAI-API-URL `http://127.0.0.1:8000/v1`, Dummy-Key.
12. **MCP-Server in WebUI-Settings → Tools** für eigenständige Chat-Workflows (NICHT mit OpenCodes MCP teilen — stdio ist per-Client). Wichtig: dedizierte Filesystem-Scopes, read-only wo sinnvoll.
13. **RAG-Konfiguration für Obsidian-Vault:** WebUI hat eingebautes RAG, Workspace anbinden, Embedding-Modell auf BGE-M3 oder Qwen3-Embedding-4B umstellen (Default ist suboptimal).
14. **Tailscale-Binding optional:** Wenn Familien-/Mobile-Zugriff erwünscht, weiter `mode: local` (127.0.0.1) lassen und über das Tailnet erreichen — bringt Auth + ACL. `4lm expose lan --confirm` ist die Notbremse, wenn 0.0.0.0 wirklich nötig (z. B. iPad ohne VPN-Profil).

### Phase D — Operative Hygiene (Priorität 3)

15. **Log-Rotation via newsyslog**: erledigt von `install.sh` (`/etc/newsyslog.d/4lm.conf`, ein `sudo`-Prompt). Rotation bei 10 MB, 7 Generationen, gzip-komprimiert.
16. **Backup-Pfad für `~/.4lm/openwebui-data/`** zur Restic/Borg-Konfiguration hinzufügen.
17. **Versions-Pinning:** `requirements.txt` im Repo-Root pinnt `mlx-openai-server==1.7.1` und `open-webui==0.6.43`. Updates: Datei editieren, `./install.sh` (idempotent).
18. **Disk-Monitoring:** Quarterly-Reminder für `huggingface-cli scan-cache` und Cleanup.

### Phase E — Nice-to-have (Priorität niedrig)

19. **SwiftBar-Plugin** für Menüleisten-Indikator schreiben (zeigt Status, geladene Modelle, RAM-Auslastung, Restart-Buttons).
20. **Sleep-Hook auf Akku** — Backend automatisch stoppen bei Wechsel auf Battery-Power. Idee: `pmset` schedules oder `caffeinate`-basierter Wrapper.
21. **Profile-Auto-Switching:** Hook in OpenCode-Sessions, der bei großen Repo-Operationen automatisch auf `coding-only` wechselt.

---

## 7. Bekannte Probleme & Workarounds

- **`mlx-community/Qwen3-Coder-Next-4bit` Tool-Parser-Bug:** falsche `tool_parser_type: "json_tools"` in `tokenizer_config.json`. Manueller Fix auf `qwen3_coder` zwingend, sonst Crash beim ersten Tool-Call. **Betrifft uns nicht** weil wir Qwen3.6-35B nutzen, aber gut zu wissen falls Modell-Wechsel.
- **OpenCode-Issue #4255 (LM Studio + leere `tool_calls: []`):** Grund warum wir mlx-openai-server statt LM Studio nutzen. NICHT zu LM Studio wechseln.
- **OpenCode-Issue #4054 (per-Project MCP-Configs unzuverlässig):** Globale Config in `~/.config/opencode/opencode.jsonc` nutzen.
- **LiteLLM-Versionen 1.82.7/1.82.8 kompromittiert (Credential-Stealing-Malware):** Nicht installieren. Wir nutzen sowieso direkt mlx-openai-server, kein Proxy nötig.
- **Anthropic-OAuth-Block für Drittanbieter-Agenten (Feb 2026):** Claude Max-Subscription funktioniert NICHT mehr in OpenCode. Per-Token-API ist der einzige Weg. PR #18186 hat OAuth-Code aus OpenCode entfernt.
- **MLX KV-Cache-Konsistenzprobleme bei Conversation-Branching:** Bekanntes Issue, primär bei sehr langen Multi-Turn-Sessions (>30 Turns). Workaround: gelegentlich `/compact` in OpenCode oder Session-Restart.

---

## 8. Was NICHT geändert werden soll ohne Rücksprache

- **Backend-Wahl mlx-openai-server statt LM Studio/Ollama:** Begründet durch Tool-Parser-Reife. Issue #4255 ist seit Monaten offen.
- **Modell-Wahl GLM-4.7-Flash + Qwen3.6-35B-A3B:** Sweet Spot für 96 GB. Größere Modelle passen nicht (siehe Verworfene Modelle).
- **OpenCode statt Claude Code als Frontend:** Bewusste Entscheidung gegen Anthropic-Lock-in. Multi-Provider, Open-Source, lokale Modelle nativ.
- **Bash-Skripte statt Python für Control-Plane:** Robuster, weniger Dependencies, native macOS-Integration.
- **launchd statt Docker/Compose:** GPU-Passthrough auf Docker-for-Mac fehlt — Container halbieren die MLX-Performance.

---

## 9. Erfolgskriterium

Nach erfolgreicher Inbetriebnahme:
- `4lm status` zeigt beide Services running, Modelle geladen, RAM-Auslastung im Bereich 70-85 GB.
- `4lm health` returns 0 (Wired-Memory ≥ 98304 MB).
- OpenCode in einem Test-Projekt: Multi-Turn-Tool-Loop läuft >10 Iterationen ohne Hang oder Tool-Format-Fehler.
- Open WebUI im Browser zeigt beide lokalen Modelle, Chat-Test mit deutschem Prompt funktioniert.
- Reboot-Test: Nach Login starten beide Services automatisch innerhalb 60 s.

**Antiziele (sollten NICHT eintreten):**
- Mehrere Terminal-Sessions offen halten müssen für unterschiedliche Stack-Komponenten.
- Manuelle Eingriffe nach Reboot.
- OOM-Kills wenn beide Modelle parallel laufen.
- Tool-Loop-Hangs in OpenCode mit lokalem Backend.

---

## 10. Kommunikationsstil mit dem Nutzer

- **Direkt, keine Komplimente, keine Marketing-Floskeln.** Nutzer will Berater, keinen Cheerleader.
- **Klare Trade-offs benennen, nicht verschönern.** Wenn etwas Probleme machen wird, sag es.
- **Begründungen liefern, nicht nur Anweisungen.** Nutzer ist promovierter Informatiker und will den Reasoning-Pfad nachvollziehen können.
- **Bei Unsicherheit lieber zurückfragen als raten.** Standard-Defaults setzen ist okay, aber Architektur-Entscheidungen mit dem Nutzer abstimmen.
- **Deutsch in Konversation, technische Begriffe Englisch.**

Viel Erfolg.
