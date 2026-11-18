# Matrix. Instructions and Configs
The repository this is based on:
[https://github.com/spantaleev/matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy)

## Short Guide
**Command to run the installation script (copy and run ON THE SERVER):**
```bash
curl -O https://raw.githubusercontent.com/kryptonmourog/matrix-instruction-and-configs/refs/tags/v1.1.3/scripts/matrix_up.sh && chmod +x matrix_up.sh && sudo ./matrix_up.sh
```

The script saves your answers and the generated secrets to a `.env` file next to itself. Keep it: when you run the script again from the same folder, it only asks for the admin login and password, and keeps the database password and keys. If the server already has an installation (including one made by earlier versions of the script), its domains and secrets are imported into `.env` automatically. The script prompts are in Russian.

**Updating an existing server** (including one installed by earlier versions of the script):
```bash
curl -O https://raw.githubusercontent.com/kryptonmourog/matrix-instruction-and-configs/refs/tags/v1.1.3/scripts/matrix_up.sh && chmod +x matrix_up.sh && sudo ./matrix_up.sh --update
```
First, `--update` checks whether a newer release of the script with the same major version (v1.x) is out; if so, it downloads it, verifies it and continues with the new version. It never switches to the next major version (v2.0.0) on its own, it only warns. To stay on the current version: `sudo ./matrix_up.sh --update --no-self-update`.

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
