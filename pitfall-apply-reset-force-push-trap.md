# Pitfall: apply reset force-push trap

## The fatal sequence

```mermaid
graph TD
    A[Source: 27 commits on old master] --> B[apply reset all]
    B --> C[Targets created: cherry-picks onto current master]
    C --> D[Targets pushed to remote]
    D --> E[PR #21719 opened on target 1]
    E --> F[Add JSDoc commit to source]
    F --> G{How to update target 1?}

    G -->|"apply 1 (incremental)"| H[FAILS: cosmetic divergence<br/>can't match SHAs]
    H --> I[Forced into apply reset 1]

    G -->|"apply reset 1 (recreate)"| I

    I --> J[Target 1 deleted + recreated<br/>ALL new SHAs]
    J --> K[push 1]
    K --> L["FORCE PUSH<br/>(old SHAs gone from remote)"]
    L --> M["GitHub shows: force-pushed from b3f170d to 3626cb6"]

    style L fill:#ff4444,color:white
    style H fill:#ffaa44,color:white
    style M fill:#ff4444,color:white
```

## Why it was unrecoverable

```mermaid
graph LR
    subgraph "Before push"
        R1[Remote: b3f170d<br/>14 commits]
        L1[Local: 3626cb6<br/>15 commits, all new SHAs]
    end

    subgraph "After push --force"
        R2[Remote: 3626cb6<br/>old history gone]
        L2[Local: 3626cb6]
    end

    subgraph "Reflog?"
        RF[Local reflog: only has<br/>new branch creation.<br/>Old SHAs not in reflog<br/>because apply reset<br/>DELETED the branch<br/>before recreating it.]
    end

    R1 -->|"force push overwrites"| R2
    L1 --> L2
    RF -->|"can't recover"| R1

    style R1 fill:#44aa44,color:white
    style R2 fill:#ff4444,color:white
    style RF fill:#ff8844,color:white
```

## The chain of causation

```mermaid
graph TD
    ROOT["Source 458 commits behind master"]
    ROOT --> A["apply reset all creates targets<br/>with auto-resolved cherry-picks"]
    A --> B["Status shows (cosmetic)<br/>SHAs don't match source"]
    B --> C["Targets pushed, PR opened"]
    C --> D["New commit added to source"]
    D --> E["apply 1 fails<br/>(can't match cosmetic SHAs)"]
    E --> F["Only option: apply reset 1"]
    F --> G["New SHAs, push requires --force"]
    G --> H["Force push on open PR"]

    FIX["FIX: sync BEFORE first apply"] -.->|"prevents"| ROOT
    FIX2["FIX: apply (incremental)<br/>after sync, never reset"] -.->|"prevents"| F

    style ROOT fill:#ff4444,color:white
    style H fill:#ff4444,color:white
    style FIX fill:#44aa44,color:white
    style FIX2 fill:#44aa44,color:white
```

## What should have happened

```mermaid
graph TD
    A[Source behind master] --> B["git dispatch sync<br/>(merge master into source + targets)"]
    B --> C["git dispatch apply<br/>(incremental cherry-pick of new commits only)"]
    C --> D[Targets pushed - fast forward]
    D --> E[PR opened]
    E --> F[New commit added to source]
    F --> G["git dispatch apply 1<br/>(incremental - just the 1 new commit)"]
    G --> H["git dispatch push 1<br/>(fast forward, no --force)"]
    H --> I["GitHub shows: normal push, PR updated cleanly"]

    style B fill:#44aa44,color:white
    style G fill:#44aa44,color:white
    style I fill:#44aa44,color:white
```

## Why the old target was unrecoverable

1. `apply reset 1` ran `git branch -D cyril/dispatch/bulk-transaction-registration/1` (delete)
2. Then recreated it from `origin/master` with fresh cherry-picks (all new SHAs)
3. The branch deletion cleared the local reflog for that branch
4. `git push` sent the new SHAs to remote, overwriting the old history
5. The old commit `b3f170d` exists nowhere: not in local reflog, not on remote

The only theoretical recovery would be GitHub's internal reflog (support request) or if someone had fetched the old branch before the force push.

## Rules to prevent this

1. **Always `sync` before first `apply`** when source is behind master
2. **Never `apply reset` on pushed targets** unless you accept force-push
3. **Use `apply` (incremental) after sync** to add new commits
4. **Reserve `apply reset` for truly broken targets** that have never been pushed, or where force-push is acceptable
