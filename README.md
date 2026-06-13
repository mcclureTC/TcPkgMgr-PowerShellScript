# TcPkgMgr

A PowerShell ISE menu system for the TwinCAT Package Manager (`tcpkg`).  
Wraps every `tcpkg` command in a numbered, guided interface with read-only preview mode, remote target management, batch operations, and CSV import/export.

---

## Quick start

1. Open `TcPkgMgr.ps1` in the PowerShell ISE.
2. Press **F5** to run.
3. The script starts in **read-only mode** — all commands are shown but not executed. Use this to explore the menus and verify commands before making changes.
4. Select **8. Toggle read-only mode** from the main menu when you are ready to execute commands.

**Requirements:** Windows PowerShell 5.1 (ISE) · `tcpkg` on `PATH` · Administrator privileges for most package operations

---

## Menu structure

### Main menu

```mermaid
flowchart LR
    MAIN["🏠 Main Menu"]
    MAIN --> PKG["1. Packages & workloads"]
    MAIN --> SRC["2. Sources / Feeds"]
    MAIN --> CFG["3. Configuration"]
    MAIN --> TSK["4. Tasks / Automation"]
    MAIN --> RMT["5. Remote targets"]
    MAIN --> LFS["6. Search files in local packages"]
    MAIN --> FFS["7. Search files in feed packages"]
    MAIN --> RO["8. Toggle read-only mode"]
    MAIN --> RAW["9. Run raw tcpkg command"]

    classDef menu   fill:#1e3a5f,stroke:#4a9eda,color:#fff
    classDef action fill:#1a3a2a,stroke:#4aaf6a,color:#fff
    class MAIN menu
    class PKG,SRC,CFG,TSK,RMT,LFS,FFS,RO,RAW action
```

---

<details>
<summary><strong>1. Packages &amp; workloads</strong></summary>

```mermaid
flowchart TD
    PKG["1. Packages & workloads"]

    PKG --> P1["1. List available packages\ntcpkg list"]
    PKG --> P2["2. Search / list installed\ntcpkg list -i"]
    PKG --> P3["3. List upgradable\ntcpkg list -o"]
    PKG --> P4["4. List workloads\ntcpkg list -t workload"]
    PKG --> P5["5. Show package details\ntcpkg show"]
    PKG --> P6["6. List all versions\ntcpkg list -a"]
    PKG --> P7["7. Show dependency tree\ntcpkg resolve --dependency-tree"]
    PKG --> P8["8. Install a package"]
    PKG --> P9["9. Upgrade a package"]
    PKG --> P10["10. Repair a package\ntcpkg repair"]
    PKG --> P11["11. Uninstall a package"]
    PKG --> P12["12. Search for a package\ntcpkg list term"]
    PKG --> P13["13. Batch operation\non multiple targets"]

    P8  --> P8A["Single target\n→ Package browser\n→ Pick version\n→ Pick target"]
    P8  --> P8B["Multiple targets\n→ Batch operation"]
    P9  --> P9A["Single target\n→ Package browser"]
    P9  --> P9B["Multiple targets\n→ Batch operation"]
    P9  --> P9C["Upgrade ALL\ntcpkg upgrade all"]
    P11 --> P11A["Single target\n→ Installed list picker"]
    P11 --> P11B["Multiple targets\n→ Batch operation"]
    P11 --> P11C["Uninstall ALL\ntcpkg uninstall all"]

    P8B & P9B & P11B & P13 --> BATCH["Batch operation\n(see below)"]

    classDef menu   fill:#1e3a5f,stroke:#4a9eda,color:#fff
    classDef action fill:#1a3a2a,stroke:#4aaf6a,color:#fff
    classDef batch  fill:#3a1e5f,stroke:#9a6eda,color:#fff
    classDef info   fill:#3a2a1a,stroke:#cf9a4a,color:#fff
    class PKG menu
    class P1,P2,P3,P4,P5,P6,P7,P8,P9,P10,P11,P12,P13 action
    class P8A,P8B,P9A,P9B,P9C,P11A,P11B,P11C info
    class BATCH batch
```

#### Batch operation

Runs the same action sequentially across multiple remote targets.  
Targets are selected using numbers and ranges — both `1,3,5..8` and `1,3,5-8` syntax are supported.

> **Note on parallelism:** tcpkg holds a system-wide lock for the full duration of every command (including the initial compatibility check). Only one tcpkg process can run at a time on the local machine, so true parallel execution is not possible. All batch operations run sequentially.

```mermaid
flowchart TD
    BATCH["Batch operation"]
    BATCH --> BA["1. Install\nSearch feed\nPick package & version"]
    BATCH --> BB["2. Upgrade\nSearch feed\nPick package"]
    BATCH --> BC["3. Uninstall\nSearch installed\non a representative target"]

    BA --> BFEED["If feed missing on remote\n─────────────────────────\n1. Push from local\n   (Internet Access → False,\n    push over SSH, restore)\n2. Add feed remotely\n   (unauthenticated feeds only;\n    authenticated auto-falls back\n    to push-from-local)\n3. Skip target"]

    BA & BB & BC --> BTGT["Select targets\ne.g. 1,3,5..8 or 1-5"]
    BFEED --> BTGT

    BTGT --> BRUN["Run sequentially on each target\n─────────────────────────────\n• Per-target status: OK / Skipped / Failed\n• Internet Access restored after each target\n• Summary table on completion"]

    classDef batch fill:#3a1e5f,stroke:#9a6eda,color:#fff
    classDef step  fill:#1a3a2a,stroke:#4aaf6a,color:#fff
    classDef warn  fill:#3a2a1a,stroke:#cf9a4a,color:#fff
    class BATCH batch
    class BA,BB,BC,BTGT,BRUN step
    class BFEED warn
```

</details>

---

<details>
<summary><strong>2. Sources / Feeds</strong></summary>

```mermaid
flowchart TD
    SRC["2. Sources / Feeds"]
    SRC --> S1["1. List sources\ntcpkg source list"]
    SRC --> S2["2. Verify a source\ntcpkg source verify"]
    SRC --> S3["3. Add a Beckhoff feed\nStable / Outdated / Testing / Preview"]
    SRC --> S4["4. Add a custom source\ntcpkg source add"]
    SRC --> S5["5. Enable / disable a source\ntcpkg source edit --enabled"]
    SRC --> S6["6. Change source priority\ntcpkg source edit --priority"]

    classDef menu   fill:#1e3a5f,stroke:#4a9eda,color:#fff
    classDef action fill:#1a3a2a,stroke:#4aaf6a,color:#fff
    class SRC menu
    class S1,S2,S3,S4,S5,S6 action
```

</details>

---

<details>
<summary><strong>3. Configuration</strong></summary>

```mermaid
flowchart TD
    CFG["3. Configuration"]
    CFG --> C1["1. View configuration\ntcpkg config list"]
    CFG --> C2["2. Set an option\ntcpkg config set -n opt -v value\n─────────────────\nToggle / Enum / Number picker"]
    CFG --> C3["3. Unset an option\ntcpkg config unset -n opt"]
    CFG --> C4["4. Set proxy\ntcpkg config set proxy"]

    classDef menu   fill:#1e3a5f,stroke:#4a9eda,color:#fff
    classDef action fill:#1a3a2a,stroke:#4aaf6a,color:#fff
    class CFG menu
    class C1,C2,C3,C4 action
```

</details>

---

<details>
<summary><strong>4. Tasks / Automation</strong></summary>

```mermaid
flowchart TD
    TSK["4. Tasks / Automation"]
    TSK --> T1["1. List tasks"]
    TSK --> T2["2. Run a task\nCollects token values\nRuns steps sequentially"]
    TSK --> T3["3. Create a task\nName · Description\nSteps with token placeholders"]
    TSK --> T4["4. Show task details"]
    TSK --> T5["5. Delete a task"]

    classDef menu   fill:#1e3a5f,stroke:#4a9eda,color:#fff
    classDef action fill:#1a3a2a,stroke:#4aaf6a,color:#fff
    class TSK menu
    class T1,T2,T3,T4,T5 action
```

</details>

---

<details>
<summary><strong>5. Remote targets</strong></summary>

```mermaid
flowchart TD
    RMT["5. Remote targets"]
    RMT --> R1["1. List remote targets\ntcpkg remote list"]
    RMT --> R2["2. Verify a target\ntcpkg remote verify"]
    RMT --> R3["3. Add a remote target\ntcpkg remote add\n─────────────────\nSSH password via masked prompt\nHost key auto-accepted with -y"]
    RMT --> R4["4. Edit a remote target\ntcpkg remote edit\n─────────────────\nName · Host · Port · User\nInternet Access (True/False)"]
    RMT --> R5["5. Remove a remote target\ntcpkg remote remove"]
    RMT --> R6["6. Export targets to CSV\nColumns: Name Host Port User\nInternetAccess Password (optional)"]
    RMT --> R7["7. Import targets from CSV\n─────────────────\nConnectivity pre-check per target\nUpdate changed properties\nPassword: CSV / shared / per-target\nSkip unreachable hosts option"]

    classDef menu   fill:#1e3a5f,stroke:#4a9eda,color:#fff
    classDef action fill:#1a3a2a,stroke:#4aaf6a,color:#fff
    class RMT menu
    class R1,R2,R3,R4,R5,R6,R7 action
```

</details>

---

<details>
<summary><strong>6 &amp; 7. File search (local &amp; feed)</strong></summary>

```mermaid
flowchart TD
    LFS["6. Search files\nin local packages"]
    LFS --> LFS1["Enter search term\nPartial or exact match"]
    LFS1 --> LFS2["Open each .nupkg in\nC:\\ProgramData\\Beckhoff\\TcPkg\\lib\nas a ZIP archive"]
    LFS2 --> LFS3["Display matches\nFile · Size · Package · Path in pkg"]
    LFS3 --> LFS4["Open containing folder\nin Explorer"]

    FFS["7. Search files\nin feed packages"]
    FFS --> FFS1["Search feed for packages\nPick one or more (numbers & ranges)"]
    FFS1 --> FFS2["Enter file search term\nPartial or exact match"]
    FFS2 --> FFS3["Download selected packages\nto temp folder\ntcpkg download --exclude-dependencies"]
    FFS3 --> FFS4["Search inside .nupkg files"]
    FFS4 --> FFS5["Display matches\nClean up temp folder"]
    FFS5 --> FFS6["Open containing folder\nin Explorer"]

    classDef menu   fill:#1e3a5f,stroke:#4a9eda,color:#fff
    classDef action fill:#1a3a2a,stroke:#4aaf6a,color:#fff
    class LFS,FFS menu
    class LFS1,LFS2,LFS3,LFS4,FFS1,FFS2,FFS3,FFS4,FFS5,FFS6 action
```

</details>

---

## Key features

| Feature | Description |
|---|---|
| **Read-only mode** | Default at startup — every tcpkg command is shown but not executed. Toggle with option 8. |
| **Package browser** | Browse feeds, see install status per target, pick version from a table showing version and feed |
| **Batch operations** | Install / upgrade / uninstall the same package across multiple remote targets. Targets selected with numbers and ranges (`1,3,5..8` or `1,3,5-8`). Always sequential — tcpkg's system-wide lock prevents parallel execution from one machine. |
| **Missing feed handling** | When a required feed is not on a remote target, choose per batch: push from local (Internet Access toggled to False and restored), add feed remotely (unauthenticated feeds), or skip the target. Authenticated remote feed add falls back to push-from-local automatically. |
| **Remote target management** | Add, edit, verify targets via SSH. CSV export/import with optional password column, connectivity pre-check, and automatic property update on import. |
| **Feed management** | Add Beckhoff feeds, custom feeds, enable/disable, set priority cascade |
| **File search** | Search inside `.nupkg` archives in the local package cache or download from a feed to search. Supports partial and exact matching. |
| **Task automation** | Define multi-step tcpkg workflows with `{{token}}` placeholders for runtime values |
| **Remote install status** | Installed-package index fetched from the selected target — shows correct up-to-date / upgradable / not-installed status per machine |

---

## Known limitations

| Limitation | Detail |
|---|---|
| **No parallel batch execution** | tcpkg holds a system-wide lock for the full duration of every command. Running two tcpkg processes simultaneously on the same machine results in `TcPkg is already running`. All batch operations are sequential. |
| **No authenticated remote feed add via ISE** | `tcpkg source add -r --password-stdin` is not supported by tcpkg for authenticated feeds. Adding an authenticated feed to a remote machine requires logging into that machine and running the command directly in PowerShell. Unauthenticated feeds can be added remotely without issue. |
| **Interactive stdin not available in ISE** | The PowerShell ISE does not support interactive stdin for child processes. Commands that require interactive prompts (e.g. `tcpkg remote add -p`) are handled by collecting input via `Read-Host` and piping it to the process. |