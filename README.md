# OpenCloud Desktop for macOS with on-demand files (unofficial)

This is an **unofficial, community-maintained** build of the [OpenCloud desktop client](https://github.com/opencloud-eu/desktop)
for macOS. It is not affiliated with or supported by OpenCloud GmbH.

It builds on the macOS FileProvider work in [restot/opencloud-desktop](https://github.com/restot/opencloud-desktop)
and keeps tracking the official client, so every upstream improvement keeps arriving.

## What is different from the official client

The official macOS client downloads whole sync folders; on-demand files ("virtual files") exist only on Windows.
This build brings them to macOS through Apple's FileProvider framework, the same system iCloud Drive, OneDrive
and Nextcloud use in Finder:

- **On-demand files in Finder**: each space appears in the Finder sidebar ("OpenCloud - Personal", "OpenCloud - Shares",
  one entry per project space). Files download when opened; "Remove Download", "Download Now" and
  "Keep Downloaded" work as with iCloud Drive.
- **Space selection**: choose which spaces appear in Finder in the account settings, like adding spaces on Windows.
- **Pause and resume** synchronization from the menu bar or the account settings.
- **Large files**: resumable uploads (TUS, 8 MB chunks, continue after a restart or network loss) and partial
  downloads, so large videos and PDFs open and seek without downloading the whole file.
- **Finder integration**: thumbnails, Finder and Spotlight search on the server, the server's trash, a context menu
  (open in browser, share, file versions, copy private link), shared and "shared by" indicators, a lock badge for
  files locked on the server, and warnings before deleting shared items or moving items out of OpenCloud.
- **Ignore list and hidden files**: the client's ignore list and the "sync hidden files" option apply to on-demand
  files too.
- **Low background load**: remote changes are detected like the sync engine does it (folder ETags, only changed
  folders are listed again), so an idle client stays close to zero CPU.
- German translations for the additions.

Traditional folder sync is still available: enable **Use traditional folder sync** in Settings.

Not available for on-demand files yet: a bandwidth limit.

## Requirements and installation

There are no prebuilt downloads. You build and sign the app yourself:

- macOS 26 or later, Apple silicon
- Xcode, signed in with an Apple ID; a free Apple ID provides the required "Apple Development" certificate
  (Xcode > Settings > Accounts > Manage Certificates)
- PowerShell (`brew install powershell`) and the KDE Craft build environment used by the official client;
  `tools/update-local.sh` drives Craft through the official CI script. Once:
  `git clone --depth=1 https://github.com/KDE/craftmaster.git ~/craft/CraftMaster/CraftMaster`
  (Craft root `~/craft/CraftMaster/macos-clang-arm64`, or set `OPENCLOUD_CRAFT_ROOT`)

Then run:

```sh
tools/update-local.sh --no-merge   # build the current checkout, run the tests, sign and install
```

The previous version is kept in `~/Applications/OpenCloud-backup/`.

## How updates work

This fork follows the official `main` branch by merging it (no rebasing), and keeps its changes mostly in separate
files (`shell_integration/MacOSX/`, `src/gui/macOS/`), so merges rarely conflict.

```sh
tools/update-local.sh              # merge the latest official client, run the tests, build, sign and install
```

The script stops without installing anything if the merge conflicts or a test fails.

## Contributing

This repository is public. Enable the guard hooks once per clone; they block commits and pushes that contain
credentials, keys, `.env` files, local AI assistant files or a non-anonymous commit e-mail address:

```sh
git config core.hooksPath tools/git-hooks
```

Personal patterns to block in addition (names, hosts, IDs) go into `.git/info/private-patterns`, one extended
regular expression per line. That file is never committed.

## Planned

- Sync the Desktop and Documents folders into OpenCloud (macOS "known folders"), like iCloud Drive offers
- Instant updates through server notifications instead of periodic checks
- Bandwidth limit for on-demand files
- Offer generally useful fixes to the official client

## License

GPL-2.0-or-later, like the official client (see [COPYING](COPYING)).

---

*The original README of the official client follows.*

[![OpenCloud Desktop CI](https://github.com/opencloud-eu/desktop/actions/workflows/main.yml/badge.svg)](https://github.com/opencloud-eu/desktop/actions/workflows/main.yml)
# `OpenCloud Desktop`

## Introduction

`OpenCloud Desktop` is a tool to synchronize files from `OpenCloud`
with your computer.

## Download

### Binary packages

- Please have a look at our releases https://github.com/opencloud-eu/desktop/releases

### Source code

The `OpenCloud Desktop` is developed in Git. Since Git makes it easy to
fork and improve the source code and to adapt it to your need, many copies
can be found on the Internet, in particular on GitHub. However, the
authoritative repository maintained by the developers is located at
https://github.com/opencloud-eu/desktop/.

## macOS sync modes

When the bundled FileProvider extension supports your macOS version, OpenCloud
uses on-demand files in Finder by default. Traditional folder sync stays inactive.

To use local sync folders, select **Use traditional folder sync** in Settings,
then click **Restart to apply sync mode**. This disconnects on-demand files before
starting traditional sync. Existing local files and saved folder settings are kept.
If no folders are configured, use **Add Space** on the account page after restarting.

Clear the option and restart to return to on-demand files. Installations without a
compatible FileProvider extension use traditional folder sync automatically.

## Reporting issues and contributing

If you find any bugs or have any suggestion for improvement, please
file an issue at https://github.com/opencloud-eu/desktop/issues. Do not
contact the authors directly by mail, as this increases the chance
of your report being lost.

If you created a patch, please submit a [Pull
Request](https://github.com/opencloud-eu/desktop/pulls).

## Maintainers and Contributors

`OpenCloud Desktop` is developed by the `OpenCloud` community and [receives
patches from a variety of authors](https://github.com/opencloud-eu/desktop/graphs/contributors).


## License

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
    or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
    for more details.
