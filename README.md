<a id="readme-top"></a>

<div align="center">
  <h1>pacaur</h1>

  <p>A Bash command-line helper for finding, reviewing, building, and managing Arch User Repository packages.</p>

[![Contributors][contributors-shield]][contributors-url]
[![Forks][forks-shield]][forks-url]
[![Stars][stars-shield]][stars-url]
[![Issues][issues-shield]][issues-url]
[![License][license-shield]][license-url]

  <p>
    <a href="#usage">Documentation</a>
    &middot;
    <a href="#getting-started">Getting Started</a>
    &middot;
    <a href="https://github.com/donaldturinglee/pacaur/issues/new?labels=bug">Report a bug</a>
    &middot;
    <a href="https://github.com/donaldturinglee/pacaur/issues/new?labels=enhancement">Suggest a feature</a>
  </p>
</div>

<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#built-with">Built With</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
        <li><a href="#uninstallation">Uninstallation</a></li>
      </ul>
    </li>
    <li>
      <a href="#usage">Usage</a>
      <ul>
        <li><a href="#search-and-package-information">Search and Package Information</a></li>
        <li><a href="#check-for-updates">Check for Updates</a></li>
        <li><a href="#download-a-snapshot">Download a Snapshot</a></li>
        <li><a href="#build-a-local-package">Build a Local Package</a></li>
        <li><a href="#install-local-package-files">Install Local Package Files</a></li>
        <li><a href="#remove-installed-packages">Remove Installed Packages</a></li>
        <li><a href="#install-an-aur-package">Install an AUR Package</a></li>
        <li><a href="#upgrade-installed-aur-packages">Upgrade Installed AUR Packages</a></li>
        <li><a href="#exit-status-and-interruptions">Exit Status and Interruptions</a></li>
      </ul>
    </li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li>
      <a href="#contributing">Contributing</a>
      <ul>
        <li><a href="#checks-and-tests">Checks and Tests</a></li>
      </ul>
    </li>
    <li><a href="#contributors">Contributors</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgments">Acknowledgments</a></li>
    <li><a href="#license">License</a></li>
  </ol>
</details>

## About The Project

pacaur brings AUR searches, package information, snapshot downloads, builds, local package transactions, and upgrades into one Bash command. It uses makepkg to build packages and pacman to manage installed packages, with explicit review and native transaction confirmation.

Key features:

- Search the AUR by name and description, and look up an exact package name.
- Check installed foreign packages for newer AUR versions.
- Download snapshots without overwriting existing files, and review their contents before building.
- Build local PKGBUILDs, install local package files, and remove exact installed packages.
- Download, review, build, and install one AUR target with `-S`.
- Upgrade installed AUR packages by `PackageBase`, building each base once and installing its selected split packages together.
- Optionally install missing repository dependencies with `--syncdeps`.
- Retain build workspaces, artifacts, and logs after success, failure, or cancellation.

Recursive AUR dependency resolution is not implemented. Dependencies available only in the AUR must be prepared separately. Development packages such as `-git` packages are compared using the version published in AUR metadata; upstream commits are not checked.

### Built With

- [Bash](https://www.gnu.org/software/bash/) for the command-line workflow.
- [curl](https://curl.se/) and [jq](https://jqlang.org/) for AUR RPC requests and JSON validation.
- [makepkg](https://man.archlinux.org/man/makepkg.8.en) for building packages.
- [pacman](https://man.archlinux.org/man/pacman.8.en), [pacman-conf](https://man.archlinux.org/man/pacman-conf.8.en), and [vercmp](https://man.archlinux.org/man/vercmp.8.en) for transactions, configuration, and version comparisons.
- GNU tar, gzip, GNU coreutils, GNU Make, sed, and util-linux for archive handling, installation, and process control.

[Back to top](#readme-top)

## Getting Started

Run the examples below in Bash. Building and managing packages require an Arch Linux environment. Git Bash on Windows can be used to check the command entry point and help output.

### Prerequisites

| Operation | Requirements |
| --- | --- |
| Help and command entry point | Bash |
| Search and package information | curl, jq 1.6 or later, and network access |
| Update checks | pacman; curl, jq, and vercmp when foreign packages are present |
| Snapshot downloads | Search tools, GNU tar, gzip, and GNU coreutils; a writable destination that supports hard links |
| Local builds | makepkg, util-linux `setsid`, and the PKGBUILD's build dependencies |
| Local package installation and removal | pacman; sudo when running as a regular user |
| Full AUR installation | Download, build, and installation tools, plus mkdir and sed |
| AUR upgrades | Update-check and full-installation tools, plus pacman-conf to read ignore rules |
| Installing the pacaur script | GNU Make and the coreutils `install` and `rm` commands |

Run `-m`, `-S`, and `-u` as a regular user. Installation steps use sudo when needed. Update checks can run as a regular user or root without sudo. Each command checks its own requirements; an update run with no eligible upgrades does not require build tools or elevation.

On Arch Linux, prepare the common tools before cloning:

```bash
sudo pacman -S --needed git base-devel curl jq tar gzip coreutils util-linux
```

Individual PKGBUILDs may require additional build dependencies. `--syncdeps` can install missing dependencies from configured repositories during `-S` or `-u`.

### Installation

1. Clone the repository and enter its directory.

   ```bash
   git clone https://github.com/donaldturinglee/pacaur.git
   cd pacaur
   ```

2. Check the entry point directly from the checkout.

   ```bash
   bash ./pacaur -h
   ```

3. Install the script. The default destination is `/usr/local/bin/pacaur`.

   ```bash
   sudo make install
   pacaur -h
   ```

   To install under your user directory instead:

   ```bash
   make install PREFIX="$HOME/.local"
   "$HOME/.local/bin/pacaur" -h
   ```

You can also keep running `bash ./pacaur` from the checkout. No project configuration file is required. To retain full-workflow build directories outside the system temporary directory, set `TMPDIR` to an existing directory you own before invoking pacaur.

`BINDIR` defaults to `$(PREFIX)/bin`. `DESTDIR` adds a staging prefix for packaging or installation checks:

```bash
make install DESTDIR=/tmp/pacaur-stage
make uninstall DESTDIR=/tmp/pacaur-stage
```

### Uninstallation

Use the same directory options used during installation:

```bash
sudo make uninstall
```

For a user installation:

```bash
make uninstall PREFIX="$HOME/.local"
```

The uninstall target removes only the installed `pacaur` script.

[Back to top](#readme-top)

## Usage

Start by searching for a package and checking its details:

```bash
pacaur -s "visual studio"
pacaur -i yay
```

Search results are sorted by package name. Package details include the name, version, description, maintainer, and AUR page URL.

| Command | Purpose |
| --- | --- |
| `pacaur` or `pacaur -h` | Show help |
| `pacaur -s KEYWORDS` | Search package names and descriptions |
| `pacaur -i PACKAGE` | Show information for one exact AUR package |
| `pacaur --checkupdates` | List newer AUR versions of installed foreign packages |
| `pacaur -d PACKAGE` | Download a build snapshot into the current directory |
| `pacaur -m DIRECTORY` | Build a reviewed local PKGBUILD |
| `pacaur -U FILE...` | Install local package files together |
| `pacaur -R PACKAGE...` | Remove exact installed packages together |
| `pacaur -S PACKAGE [--syncdeps]` | Download, review, build, and install one AUR package |
| `pacaur -u [--syncdeps]` | Upgrade installed AUR packages by package base |

### Search and Package Information

`-s` accepts one search string with at least two Unicode characters. The string must contain a non-whitespace character and must not start with `-`. Quote strings containing spaces. Each result uses `aur/<name> <version>`, followed by its description on the next line. Missing descriptions appear as `(none)`. An empty result prints `No matching packages found.` and returns `0`.

`-i` accepts one nonempty, non-option exact package name. Missing descriptions or maintainer names appear as `(none)`.

Search and information requests use the [AUR RPC v5 API](https://github.com/archlinux/aurweb/blob/master/doc/rpc.txt), with a 5-second connection timeout and a 15-second total timeout per request.

### Check for Updates

```bash
pacaur --checkupdates
```

pacaur uses `pacman -Qm` to read installed packages absent from the current sync databases. These may be AUR packages or other local packages, so each candidate is looked up by exact name. The command uses existing databases without refreshing them. With no candidates, it prints `No foreign packages installed.` without making a network request.

Sorted candidates are queried in batches of at most 100 names, with an additional limit on encoded request length. Responses must contain valid names, versions, and package bases. Duplicate names, unrequested names, or malformed data stop the check. Results are buffered until every batch and comparison succeeds.

Versions are compared with `vercmp`, including `epoch`, `pkgver`, and `pkgrel`. Only newer AUR versions are listed, in package-name order. Example output:

```text
example 1.0-1 -> 1.1-1
```

Missing AUR entries produce `Not found in AUR: <name>` on standard error and do not fail the check. Matching packages with no updates produce `No newer AUR versions found for matched packages.` If none of the candidates match AUR entries, the message is `No installed foreign packages were found in AUR.`

This command reads metadata without executing PKGBUILDs, building, or installing packages. It accepts no additional arguments and shows version differences even for packages that `-u` would skip under ignore rules.

### Download a Snapshot

```bash
pacaur -d yay
```

`-d` downloads the snapshot identified by AUR's `PackageBase` and `URLPath`, saves it as `<PackageBase>.tar.gz` in the current directory, and prints the full path. Split packages use their shared package-base name. Downloads have a 5-second connection timeout and a 60-second total timeout.

The archive is written to a temporary file, checked for gzip integrity and a readable tar entry containing a regular `PKGBUILD`, and then published without overwriting an existing file, directory, or symbolic link. Failed or interrupted downloads remove their temporary files. The snapshot is not extracted or executed.

### Build a Local Package

```bash
pacaur -m /path/to/reviewed-build
pacaur -m "/path/to/build directory"
```

The directory must contain a readable, regular `PKGBUILD` that you have reviewed. pacaur runs `makepkg --log` as a regular user, streams its output, and preserves dependency and source-integrity checks. This command builds package files without automatically installing dependencies or the resulting packages.

Artifacts and logs follow makepkg's `PKGDEST`, `PKGEXT`, and `LOGDEST` settings, including split-package output. Failures report makepkg's exit status. The build directory and existing logs remain available after failure or interruption. See [makepkg.conf](https://man.archlinux.org/man/makepkg.conf.5.en) for output settings.

### Install Local Package Files

```bash
pacaur -U ./example-1.0-1-any.pkg.tar.zst
pacaur -U "/path/to/package output/example-1.0-1-any.pkg.tar.gz" \
    "/path/to/package output/example-doc-1.0-1-any.pkg.tar.gz"
```

Each argument must identify a readable, regular file. Absolute paths, relative paths, and paths containing spaces are supported. Prefix a filename starting with `-` with `./`. File extensions are not restricted. Every file is inspected with `pacman -Qp` before requesting elevation or beginning installation.

All files enter one `pacman -U -- <files...>` transaction, through `sudo -- pacman` for a regular user or directly for root. Native confirmation, dependency, signature, and conflict checks remain enabled. Required repository dependencies follow pacman's normal behavior. Authentication or installation failures retain the original output and report the exit status. Package files and build logs are retained.

### Remove Installed Packages

```bash
pacaur -R yay
pacaur -R example example-doc
```

`-R` accepts exact installed package names, including AUR and repository packages. Names may contain ASCII letters, digits, and `@._+-`, but must not start with `.` or `-`. Empty arguments, paths, whitespace, version constraints, and extra options are rejected.

Before elevation, pacaur queries every target with `pacman -Qq` and verifies that the returned names match exactly. Missing packages, query failures, and virtual-provider aliases stop the operation. Package groups are not expanded.

All targets enter one `pacman -R -- <names...>` transaction, using sudo when needed. Native confirmation and dependency protection remain enabled. Removal does not recursively remove dependencies or cascade to dependents. Modified backup files follow pacman's normal `.pacsave` behavior. Authentication, confirmation, and removal stay in the foreground, and failures preserve the original diagnostics.

### Install an AUR Package

```bash
pacaur -S yay
pacaur -S yay --syncdeps
```

`-S` accepts one exact AUR package name and runs the full workflow as a regular user:

1. Create a private workspace under `${TMPDIR:-/tmp}` and print `Workspace (retained): ...`.
2. Download and validate the snapshot, then extract it into `source/<PackageBase>` inside the workspace.
3. Display every snapshot file as escaped text for review, including the PKGBUILD, helper scripts, and patches.
4. Ask for `y` or `yes` before running makepkg. Empty input, another answer, or end of input cancels the build with status `1`.
5. Build the package, record `makepkg --packagelist` output in `packages.txt`, and inspect artifact names with `pacman -Qpq`.
6. Install the unique artifact matching the requested package name through the local installation workflow.

Extraction accepts only regular files and directories inside the package base. Symbolic links, hard links, special files, duplicate paths, absolute paths, and paths containing `.`, `..`, or empty components are rejected. Path components may contain ASCII letters, digits, spaces, and `._+@,=:-`.

No PKGBUILD code runs before review approval. `makepkg --packagelist` can also execute top-level PKGBUILD code, so it runs only after approval. Extra split packages and debug packages are not automatically installed. Custom makepkg output directories and package extensions are supported.

The optional `--syncdeps` flag is accepted once with `-S` or `-u`; with `-S`, it may appear before or after the package name. After review approval, it runs `makepkg --log --syncdeps` in the foreground. Missing repository dependencies are handled through makepkg and pacman, retaining version requirements, provider selection, authentication, and transaction confirmation. Without this flag, missing build dependencies stop the build.

Any failure stops subsequent steps. Successfully installed repository dependencies remain installed. Workspaces, artifacts, and logs are retained after success, failure, or cancellation; temporary download files are still cleaned up. System temporary-directory policies may eventually remove retained workspaces, so choose a suitable `TMPDIR` for long-term storage.

### Upgrade Installed AUR Packages

```bash
pacaur -u
pacaur -u --syncdeps
```

`-u` shares the candidate queries and version comparisons used by `--checkupdates`. It groups installed packages with newer AUR versions by `PackageBase`, allowing split packages to share one build and one installation transaction. Candidates missing from the AUR are reported and skipped.

Before presenting the plan, pacaur reads `IgnorePkg` and `IgnoreGroup` through `pacman-conf`, including configuration loaded through `Include`. Rules use ordinary shell patterns against package names and installed groups. If any outdated member is ignored, the entire package-base group is skipped, with the affected members and reason shown. Members already at the current version are excluded from the update group.

The plan is sorted by package base and lists each target's installed and available versions. After `y` or `yes` confirmation, each group is downloaded, reviewed, and built once. `--syncdeps` applies to each group's build. No available upgrades, or no groups remaining after ignore rules, returns `0`.

Each group passes the following checks:

- Before building, every member's exact installed name, version, and installation reason are queried. Versions must still match the plan. AUR metadata is rechecked to confirm that all members still exist in the same package base, and the snapshot lookup verifies that base again.
- After building, every planned member must have one matching artifact with a newer version than the installed package. Missing, duplicate, mismatched, or non-newer artifacts stop the group. Extra siblings and debug packages are excluded. Built versions may be newer than the original AUR metadata; pacman shows the final versions before installation.
- Before installation, all members' installed versions and reasons are checked again to detect changes during the build.
- All selected files are installed in one `pacman -U` transaction, preserving each member's explicit or dependency installation reason. Every resulting version and reason must be verified before the group is marked complete.

Each package base is a separate transaction. Cross-base dependencies remain subject to makepkg and pacman's checks. Cancellation or failure stops later groups and reports completed, stopped, and unprocessed groups as `base [members...]`. Completed groups remain installed; a stopped group's actual package states may need inspection. Running `-u` again checks current versions and creates a new plan.

### Exit Status and Interruptions

| Status | Meaning |
| --- | --- |
| `0` | The operation completed; includes empty searches, no update candidates, no matching AUR entries, and no eligible upgrade groups. Local installation and removal succeed when pacman returns `0`. |
| `1` | An environment, query, download, validation, build, authentication, transaction, or verification failure; also upgrade or review cancellation and transaction cancellation reported as a failure by pacman. |
| `2` | Invalid arguments, such as missing or extra parameters, a search shorter than two characters, or an invalid removal target. |
| `129`, `130`, `143` | Preserved HUP, INT, or TERM interruption statuses in the download, build, transaction, and confirmed upgrade workflows. |

Query results go to standard output and diagnostics to standard error. Builds and transactions stream the underlying tools' output and preserve standard input for authentication and confirmation. Local installation and removal do not add a separate success message; transaction cancellation follows pacman's returned status.

Ordinary builds run in a separate process group, so an interruption also stops makepkg's build subprocesses while retaining logs. Builds using `--syncdeps` remain in the foreground terminal for native authentication and signal handling. Installation and removal also remain in the foreground; pacaur preserves their interruption statuses and does not delete package-manager lock files. Removal queries preserve these interruption statuses as well.

Once upgrade-plan confirmation begins, interrupted upgrades print the progress summary by package base and preserve the applicable interruption status.

[Back to top](#readme-top)

## Roadmap

- [x] Search and inspect AUR packages.
- [x] Download, review, build, install, and remove packages.
- [x] Check for updates and upgrade split packages by package base.
- [x] Support optional repository dependency installation.
- [ ] Add recursive AUR dependency planning and installation for `-S`.
- [ ] Extend dependency-aware build ordering to `-u`.

Discuss proposed work and report problems in the [issue tracker](https://github.com/donaldturinglee/pacaur/issues).

[Back to top](#readme-top)

## Contributing

Use issues to discuss bugs and proposals. To submit a code change:

1. Fork the repository and create a branch for your change.
2. Update the implementation, documentation, and relevant tests.
3. Run the checks that cover the changed behavior.
4. Commit your changes and push the branch to your fork.
5. Open a pull request describing the resulting behavior and how you verified it.

Use US English (`en-US`) for documentation, comments, and command messages. Keep text files encoded as UTF-8 without a BOM, with LF line endings. Unicode test data may be used to verify character handling independently of the interface language.

### Checks and Tests

Basic checks from the repository root:

```bash
bash -n pacaur
bash pacaur -h
make -n install
make -n uninstall
```

`make -n` prints commands without installing or removing files.

Run the offline test suites in an Arch Linux environment with the relevant tools installed:

```bash
bash tests/info.sh
bash tests/search.sh
bash tests/updates.sh
bash tests/upgrade.sh
bash tests/download.sh
bash tests/build.sh
bash tests/install.sh
bash tests/remove.sh
bash tests/sync.sh
```

The suites use simulated AUR responses, local archives, and mock makepkg, pacman, and sudo commands. They do not install or remove system packages. Update tests use real `vercmp` for version comparisons. Search tests use local curl calls to verify request encoding without contacting external services.

Removal, upgrade, and full-workflow tests use util-linux `script` to exercise authentication prompts, transaction confirmation, and terminal interruptions. Running download, build, installation, removal, upgrade, or full-workflow suites as root also requires `runuser` and the `nobody` user to exercise regular-user behavior.

Coverage includes argument and response validation, batched update queries, ignore rules, package-base changes, split-package selection and joint installation, version and installation-reason verification, archive paths, permissions, optional repository dependencies, cancellations, failures, and interruptions.

[Back to top](#readme-top)

## Contributors

Contributions are welcome through issues and pull requests. See the [contributors page](https://github.com/donaldturinglee/pacaur/graphs/contributors) for contribution history.

[Back to top](#readme-top)

## Contact

<a href="https://github.com/donaldturinglee">
  <img src="https://github.com/donaldturinglee.png?size=64" alt="donaldturinglee on GitHub" width="64" height="64" />
</a>

Contact [@donaldturinglee](https://github.com/donaldturinglee) on GitHub. For project questions, bugs, or feature requests, use [pacaur issues](https://github.com/donaldturinglee/pacaur/issues).

[Back to top](#readme-top)

## Acknowledgments

- [Arch Linux](https://archlinux.org/) and the [Arch User Repository](https://aur.archlinux.org/) for the package ecosystem and build infrastructure.
- [eurislee/pacaur](https://github.com/eurislee/pacaur) for the original project reference.
- [awesome-readme's BASIC template](https://github.com/donaldturinglee/awesome-readme/blob/main/templates/BASIC.md) for this README's structure.

[Back to top](#readme-top)

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for the terms.

[Back to top](#readme-top)

[contributors-shield]: https://img.shields.io/github/contributors/donaldturinglee/pacaur.svg?style=for-the-badge
[contributors-url]: https://github.com/donaldturinglee/pacaur/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/donaldturinglee/pacaur.svg?style=for-the-badge
[forks-url]: https://github.com/donaldturinglee/pacaur/network/members
[stars-shield]: https://img.shields.io/github/stars/donaldturinglee/pacaur.svg?style=for-the-badge
[stars-url]: https://github.com/donaldturinglee/pacaur/stargazers
[issues-shield]: https://img.shields.io/github/issues/donaldturinglee/pacaur.svg?style=for-the-badge
[issues-url]: https://github.com/donaldturinglee/pacaur/issues
[license-shield]: https://img.shields.io/badge/license-MIT-green.svg?style=for-the-badge
[license-url]: LICENSE
