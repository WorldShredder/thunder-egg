# Thunder-Egg
A profile management utility for Thunderbird. Backup _(lay)_ and restore _(hatch)_ profiles interactively or using [commandline options](#commandline-options).

> [!NOTE]
> - Thunder-Egg currently does _**not**_ backup local mail; only account data, OpenPGP keys and Thunderbird client configurations are backed up.
> - [Tails OS](https://tails.net) appears to configure a single profile named `profile.default` and the Thunderbird profile manager is inaccessible from commandline when calling the custom TB wrapper script. There is currently no known workaround to importing multiple profiles without overwriting the primary.

## Quickstart
Both backup and restore modes can be launched interactively via `egg lay` and `egg hatch`, respectively.

#### Backup Profile
```bash
egg lay -p UserMail
```

#### Restore Profile
Define restore target and launch **Thunderbird** with restored profile:
```bash
egg hatch -xs ~/UserMail@1754954219.tar.xz
```

## Commandline Options
### Usage
```bash
egg [ACTION] [OPTION...]
```

### Global Options
| Option | Value | Description
| --- | --- | ---
| -v, --verbose | | Enable verbose logging
| -l, --logfile | | Enable logging to file `~/.tb-egg.log`
| -u, --uniterm | | Disable terminal multiplexing
| -V, --version | | Print Thunder-Egg version
| -h, --help | | Print global or action-specific help

### Lay Options
| Option | Value | Description
| --- | --- | ---
| -s, --source | PATH | Thunderbird directory, defaults to `~/.thunderbird`
| -d, --dest | PATH | Output directory to lay egg in, defaults to `pwd`
| -p, --profile | str | Thunderbird profile name to backup
| -a, --alias-file | str | Alias rules file name, defaults to `alias_rules.json`
| -i, --iso | | Use human-readable timestamp instead of Unix epoch

### Hatch Options
| Option | Value | Description
| --- | --- | ---
| -s, --source | PATH | Thunderbird egg to restore
| -d, --dest | PATH | Thunderbird directory, defaults to `~/.thunderbird`
| -e, --exec | | Execute Thunderbird with restored profile after hatching
