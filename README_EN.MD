# Matrix. Instructions and Configs
The repository this is based on:
[https://github.com/spantaleev/matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy)

## Short Guide
**Command to run the installation script (copy and run ON THE SERVER):**
```bash
curl -O https://raw.githubusercontent.com/kryptonmourog/matrix-instruction-and-configs/refs/tags/v1.2.0/scripts/matrix_up.sh && chmod +x matrix_up.sh && sudo ./matrix_up.sh
```

In a terminal the script shows a [gum](https://github.com/charmbracelet/gum) interface: one question at a time with suggested defaults (subdomains are derived from the main domain), **Esc goes back to the previous question**, and a review screen at the end lets you fix any value. Installation runs step by step with a spinner, the detailed output goes to `/var/log/matrix_up.log`, and on error the script shows the last lines of the log. gum is downloaded once (pinned version and checksum) to `/usr/local/lib/matrix_up/` and reused on later runs; it is not added to `PATH`. Without a terminal, if gum is unavailable, or with `--plain`, the script uses plain text mode; there you go back by answering `<`. When answers do not come from the keyboard (a file or another program), there is no review screen; the parameter table is just printed.

After the first run the script installs itself, and from then on it is available as the **`sudo matrix-up`** command (or `matrix_up`). On a server with Matrix installed the command opens a control panel: service status, update, installing and removing the admin panels, changing parameters with reinstall, installation log. Without Matrix installed it starts the installation.

**Admin panels.** Both can be installed at the same time; the installer asks about each:
- **Ketesa** (formerly synapse-admin) is the full-featured one: users, rooms, media, sessions, MAS. It lives on the Matrix domain at `https://<Matrix domain>/synapse-admin/`, no extra domain needed.
- **Element Admin** is simpler and needs its own subdomain.

Either one can be installed or removed later from the `sudo matrix-up` panel: the script changes one line in `vars.yml` (with a backup) and applies the playbook.

Answers and generated secrets are stored in `/etc/matrix_up/matrix.env`, so a reinstall only asks for the admin login and password and keeps the database password and keys. The `.env` file that earlier versions kept next to the script is moved there automatically. If the server already has an installation (including one made by earlier versions of the script), its domains and secrets are imported automatically too. The script prompts are in Russian.

**Updating an existing server** (including one installed by earlier versions of the script):
```bash
sudo matrix-up --update
```
If there is no `matrix-up` command yet (the server was installed by a version before v1.2.0):
```bash
curl -O https://raw.githubusercontent.com/kryptonmourog/matrix-instruction-and-configs/refs/tags/v1.2.0/scripts/matrix_up.sh && chmod +x matrix_up.sh && sudo ./matrix_up.sh --update
```
First, `--update` checks whether a newer release of the script with the same major version (v1.x) is out; if so, it downloads it, verifies it and continues with the new version. It never switches to the next major version (v2.0.0) on its own, it only warns. To stay on the current version: `sudo matrix-up --update --no-self-update`.

`--update` asks nothing and does not regenerate `vars.yml`, so your manual edits stay. It moves the playbook to the version tested in this release (a newer one is not rolled back), updates the roles and runs the installation. Only `matrix_playbook_migration_validated_version` is changed in `vars.yml`; the previous file is kept next to it as `vars.yml.bak-DATE`.

Versions and changes: [Releases](https://github.com/kryptonmourog/matrix-instruction-and-configs/releases).

Video instruction:
[https://www.youtube.com/watch?v=GGaM5asQGxE](https://www.youtube.com/watch?v=GGaM5asQGxE)


## Full Guide [Russian Language]
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
