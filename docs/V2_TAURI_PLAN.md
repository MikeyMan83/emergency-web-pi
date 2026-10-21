# V2 Tauri Migration Plan

## Decision

V1 remains the supported Windows PowerShell appliance builder. Stabilize its
script contracts, release flow, and hardware acceptance before beginning the
Tauri migration. V2 replaces only the WinForms presentation layer; it does not
rewrite the appliance build logic in Rust.

## Status (2026-10-21)

The Tauri 2 rewrite was **not adopted** for the 0.4.0 release. The Windows
frontend now ships as a WPF creator (built into Windows 10/11, so end users
still need no extra runtime), preserving the frozen writer contract below.
This plan is retained for future consideration; the interface boundary it
describes (typed operations, opaque disk tokens, narrow elevation) remains
the reference model if a Tauri or other frontend migration is revisited.

## V1 Contract To Freeze

The V2 backend invokes the native Windows prebuilt writer with bounded arguments
(the storage redesign landed in V1 first; see `docs/APPLIANCE.md`):

```text
scripts/create-sd-prebuilt.ps1
  -DiskNumber <validated physical disk>
  -ConfirmDiskNumber <same physical disk>
  -Force
  -Profile <generated profile>
  -ContentDir <app workspace cache>
  -WorkspaceDir <app workspace>
  -ApSsid <generated> -ApPassword <generated>
  -ContentMode FirstBoot|Prebuilt
```

`scripts/create-sd-dynamic.ps1` remains the WSL-backed developer path and is not part of the frozen end-user contract.

The content catalog uses ZIM filenames as stable library IDs. Before V2 starts,
each catalog entry must include its approved `sourceUrl`, display metadata, and
size estimate.

## V2 Architecture

```text
Tauri UI, unelevated
  -> typed Rust command boundary
    -> named-pipe session with one-time capability token
      -> elevated Windows helper
        -> revalidates removable disk and catalog IDs
          -> invokes fixed PowerShell builder
            -> typed progress, log, and result events
```

The web UI never sends shell commands, filesystem paths, URLs, or raw disk
numbers to an elevated process.

## IPC Contract

The UI sends a bounded request:

```json
{
  "diskId": "opaque-removable-disk-token",
  "contentMode": "FirstBoot",
  "libraryIds": ["mdwiki_en_all_maxi.zim", "wikem_en_all_maxi.zim"]
}
```

Rust validates every library ID against the bundled catalog and maps it to the
approved source URL. The elevated helper re-enumerates the target removable disk
immediately before writing; it does not trust a stale disk number from the UI.

Pipe messages use typed JSON frames:

```text
handshake -> log | progress -> result
```

The handshake carries a random 256-bit capability token generated with `OsRng`.
The named pipe ACL is limited to the current user SID. A timeout, failed
authentication, helper exit, or UAC cancellation must emit one terminal failure
result and release the single-build lock.

## Implementation Phases

1. Freeze V1: pass CI, package validation, and physical Pi acceptance for both
   `FirstBoot` and `Prebuilt` modes.
2. Add `sourceUrl` to the content catalog and validate all profile IDs and sizes.
3. Create a Tauri V2 branch with a read-only catalog and disk-selection UI.
4. Add Rust disk enumeration and opaque disk tokens without write capability.
5. Add the named-pipe elevated helper, capability handshake, and single-build
   lock.
6. Integrate the existing PowerShell dynamic builder and stream stdout/stderr as
   typed events.
7. Replace the V1 wizard with the Tauri UI after equivalent build, safety, log,
   and recovery behavior is tested.

## Non-Goals

- Do not make the existing Windows PowerShell scripts cross-platform.
- Do not expose generic shell execution through Tauri IPC.
- Do not use a Tauri migration to redesign appliance content runtime. (The storage redesign, a CI-built base image plus a Windows-created exFAT `ZIMDATA` partition, was done in V1 first.)
- Do not begin macOS disk-write support until a separately reviewed macOS backend
  and privilege model exist.