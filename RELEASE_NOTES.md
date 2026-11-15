# BoardHydra Desk 1.1.1

Fixes a local storage privacy issue reported against 8e3978a. A different local
user could replace a private data directory through a searchable, nonsticky
shared ancestor after initialization; subsequent saves could expose new cards.

Storage initialization now validates the ownership, permissions and directory
structure of every ancestor of the data, configuration and cache folders. It
rejects unsafe shared ancestors and symlink paths before enabling storage.
Existing JSON files are checked for ownership, regular-file type and hard links,
and made private. Permission and migration failures keep storage disabled.

Upgrade with:

```bash
omarchy plugin update boardhydra.desk
omarchy restart shell
```

Normal private home directories require no changes. Custom storage paths using
symlinks or shared writable ancestors now require real, safely owned directories.
The plugin logs an initialization warning rather than enabling unsafe storage.

Validation: storage regression tests, live Quickshell workspace persistence and
failed-initialization tests, shell syntax checks and Omarchy plugin validation.
