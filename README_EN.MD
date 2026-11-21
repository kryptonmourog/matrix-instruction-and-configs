# Matrix. Instructions and Configs
The repository this is based on:
[https://github.com/spantaleev/matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy)

## Short Guide
**Command to run the installation script (copy and run ON THE SERVER):**
```bash
curl -O https://raw.githubusercontent.com/kryptonmourog/matrix-instruction-and-configs/refs/tags/v1.3.0/scripts/matrix_up.sh && chmod +x matrix_up.sh && sudo ./matrix_up.sh
```

In a terminal the script shows a [gum](https://github.com/charmbracelet/gum) interface: one question at a time with suggested defaults (subdomains are derived from the main domain), **Esc goes back to the previous question**, and a review screen at the end lets you fix any value. Installation runs step by step with a spinner, the detailed output goes to `/var/log/matrix_up.log`, and on error the script shows the last lines of the log. gum is downloaded once (pinned version and checksum) to `/usr/local/lib/matrix_up/` and reused on later runs; it is not added to `PATH`. Without a terminal, if gum is unavailable, or with `--plain`, the script uses plain text mode; there you go back by answering `<`. When answers do not come from the keyboard (a file or another program), there is no review screen; the parameter table is just printed.

After the first run the script installs itself, and from then on it is available as the **`sudo matrix-up`** command (or `matrix_up`). On a server with Matrix installed the command opens a control panel: service status, update, installing and removing the admin panels and the Telegram bridge, changing parameters with reinstall, installation log. Without Matrix installed it starts the installation.

**Admin panels.** Both can be installed at the same time; the installer asks about each:
- **Ketesa** (formerly synapse-admin) is the full-featured one: users, rooms, media, sessions, MAS. It lives on the Matrix domain at `https://<Matrix domain>/synapse-admin/`, no extra domain needed.
- **Element Admin** is simpler and needs its own subdomain.

Either one can be installed or removed later from the `sudo matrix-up` panel: the script changes one line in `vars.yml` (with a backup) and applies the playbook.

**Telegram bridge** ([telegram-bridge-advanced](https://github.com/kryptonmourog/telegram-bridge-advanced), my fork of mautrix-telegram: folders as spaces, comments, polls and more). The installer asks whether to install it and where:
- **On this server**, with the playbook's built-in role and the fork's image. Telegram must be reachable from the server; with Xray the bridge reaches Telegram through it (SOCKS5).
- **On a separate server**, a VPS abroad, when Telegram isn't reachable from the Matrix server. The bridge is installed by [telegram-bridge-advanced-ansible](https://github.com/kryptonmourog/telegram-bridge-advanced-ansible) (placed in the playbook directory as `telegram-advanced`); the bridge connects to the Matrix server itself through wsproxy, no new ports are needed. The script logs in to the VPS over SSH as root with its own key `/root/.ssh/matrix_up_telegram`: it shows the public key, which you add by hand or by typing the VPS root password. Optionally, direct media (a separate subdomain pointing to the Matrix server).

The following questions depend on the choice: `api_id` and `api_hash` from [my.telegram.org](https://my.telegram.org/apps), encryption of private chats, and for a separate server its address, SSH port and direct media. The bridge settings go to `vars.yml` as a separate block (`# >>> matrix-up: мост Telegram`). After the installation send `login qr` to `@telegrambot:<domain>`.

In the `sudo matrix-up` panel the bridge can be installed on a running server (including one installed by earlier versions of the script), removed (the built-in mautrix-telegram, original or the fork, and a bridge on a separate server; Matrix rooms stay, the bridge database can be kept), the original mautrix-telegram can be switched to the fork keeping its database and login, and a bridge installed on a separate server by hand (wsproxy on the Matrix server) can be taken over by the script. `--update` updates the bridge on a separate server too.

When an encrypted bridge returns to a server where the bot still has cross-signing keys from another database, a local installation automatically replaces the unavailable old key. For a bridge on a separate server, the role cannot detect this before the first start. If such a bridge exits with `Failed to verify with recovery key`, replace the `recovery_key` value in its database with `overwrite` and restart the bridge.

Answers and generated secrets are stored in `/etc/matrix_up/matrix.env`, so a reinstall only asks for the admin login and password and keeps the database password and keys. The `.env` file that earlier versions kept next to the script is moved there automatically. If the server already has an installation (including one made by earlier versions of the script), its domains and secrets are imported automatically too. The script prompts are in Russian.

**Updating an existing server** (including one installed by earlier versions of the script):
```bash
sudo matrix-up --update
```
If there is no `matrix-up` command yet (the server was installed by a version before v1.2.0):
```bash
curl -O https://raw.githubusercontent.com/kryptonmourog/matrix-instruction-and-configs/refs/tags/v1.3.0/scripts/matrix_up.sh && chmod +x matrix_up.sh && sudo ./matrix_up.sh --update
```
The same command without `--update` opens the panel, which is how to install the Telegram bridge on a server installed by earlier versions of the script.

First, `--update` checks whether a newer release of the script with the same major version (v1.x) is out; if so, it downloads it, verifies it and continues with the new version. It never switches to the next major version (v2.0.0) on its own, it only warns. To stay on the current version: `sudo matrix-up --update --no-self-update`.

`--update` asks nothing and does not regenerate `vars.yml`, so your manual edits stay. It moves the playbook to the version tested in this release (a newer one is not rolled back), updates the roles and runs the installation. Only `matrix_playbook_migration_validated_version` is changed in `vars.yml`; the previous file is kept next to it as `vars.yml.bak-DATE`.

Versions and changes: [Releases](https://github.com/kryptonmourog/matrix-instruction-and-configs/releases).

Video instruction (an old version of the script, from before v1.0.0 in the current version numbering):
[https://www.youtube.com/watch?v=GGaM5asQGxE](https://www.youtube.com/watch?v=GGaM5asQGxE)


## Semi-manual installation guide using ansible-playbook [Russian language]
My instruction:
[https://docs.google.com/document/d/1Dox26X0Rt3AuAhWyyuIXTLwvM6RRhxVPvqRuELNR2ws](https://docs.google.com/document/d/1Dox26X0Rt3AuAhWyyuIXTLwvM6RRhxVPvqRuELNR2ws)

Video instruction:
[https://www.youtube.com/watch?v=l7BLIRAxqzs](https://www.youtube.com/watch?v=l7BLIRAxqzs)

## Where to find everything
Configs:
- In this repository, in the `configs` folder

Scripts:
- In this repository, in the `scripts` folder

## License
GNU GPL v3.0, see [LICENSE](LICENSE). Part of the Xray JS scripts is adapted from [3X-UI](https://github.com/MHSanaei/3x-ui) (GPL-3.0).
